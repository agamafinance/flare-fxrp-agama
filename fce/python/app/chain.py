"""★ Chain reads performed from inside the enclave.

The extension never takes the RFQ terms from the caller: it reads them from the
contract itself, so whoever relays a settlement cannot alter what is being sold,
to whom, or above which reserve. FTSO and Secure RNG are read the same way, so
the oracle and the tie-break are as trustworthy as the chain, not as the relayer.

Only the standard library is used for transport — one dependency less in the
image is one less thing to pin for the code hash.
"""

from __future__ import annotations

import json
from urllib.request import Request, urlopen

from eth_abi import decode as abi_decode
from eth_abi import encode as abi_encode
from eth_utils import keccak

from .config import (
    CHAIN_URL,
    CONTRACT_REGISTRY,
    MAX_FEED_AGE,
    MAX_XRP_USD_1E18,
    MIN_XRP_USD_1E18,
    XRP_USD_FEED,
)

_TIMEOUT = 15


class ChainError(RuntimeError):
    """A chain read failed or returned something outside its sane range."""


def _rpc(method: str, params: list) -> str | dict:
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params})
    req = Request(
        CHAIN_URL,
        data=body.encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urlopen(req, timeout=_TIMEOUT) as resp:
            payload = json.loads(resp.read().decode("utf-8"))
    except Exception as e:  # urllib raises a zoo of transport errors
        raise ChainError(f"{method} failed: {e}") from e
    if "error" in payload:
        raise ChainError(f"{method} returned an error: {payload['error']}")
    if "result" not in payload:
        raise ChainError(f"{method} returned no result")
    return payload["result"]


def call(to: str, data: str) -> bytes:
    """eth_call against the latest block, returning raw return data."""
    out = _rpc("eth_call", [{"to": to, "data": data}, "latest"])
    if not isinstance(out, str):
        raise ChainError("eth_call returned a non-hex result")
    return bytes.fromhex(out[2:] if out.startswith("0x") else out)


def selector(signature: str) -> str:
    return keccak(signature.encode()).hex()[:8]


_chain_id: int | None = None


def chain_id() -> int:
    """The chain the enclave actually reads, cached for the process lifetime."""
    global _chain_id
    if _chain_id is None:
        out = _rpc("eth_chainId", [])
        _chain_id = int(out, 16)
    return _chain_id


def latest_block_timestamp() -> int:
    block = _rpc("eth_getBlockByNumber", ["latest", False])
    if not isinstance(block, dict):
        raise ChainError("eth_getBlockByNumber returned no block")
    return int(block["timestamp"], 16)


def resolve(name: str) -> str:
    """Resolve a Flare protocol contract through the ContractRegistry."""
    data = "0x" + selector("getContractAddressByName(string)") + abi_encode(["string"], [name]).hex()
    out = call(CONTRACT_REGISTRY, data)
    if len(out) < 32:
        raise ChainError(f"ContractRegistry returned nothing for {name}")
    return "0x" + out[12:32].hex()


# --- The RFQ contract --------------------------------------------------------


def read_rfq(rfq: str, rfq_id: int) -> tuple[str, int, int, int, bool]:
    """Read `rfqs(uint256)`: (seller, ytAmount, minPrice, settleBy, open)."""
    data = "0x" + selector("rfqs(uint256)") + abi_encode(["uint256"], [rfq_id]).hex()
    out = call(rfq, data)
    if len(out) < 160:
        raise ChainError("rfqs() returned a short struct — wrong contract?")
    return (
        "0x" + out[12:32].hex(),
        int.from_bytes(out[32:64], "big"),
        int.from_bytes(out[64:96], "big"),
        int.from_bytes(out[96:128], "big"),
        int.from_bytes(out[128:160], "big") != 0,
    )


def read_fxrp(rfq: str) -> str:
    """The premium asset the RFQ pays the seller in."""
    out = call(rfq, "0x" + selector("FXRP()"))
    if len(out) < 32:
        raise ChainError("FXRP() returned nothing")
    return "0x" + out[12:32].hex()


def mm_can_pay(fxrp: str, rfq: str, mm: str, price: int) -> bool:
    """A winning quote must be payable at settlement: balance and allowance both cover it."""
    bal_data = "0x" + selector("balanceOf(address)") + abi_encode(["address"], [mm]).hex()
    allow_data = "0x" + selector("allowance(address,address)") + abi_encode(["address", "address"], [mm, rfq]).hex()
    balance = int.from_bytes(call(fxrp, bal_data)[:32], "big")
    allowance = int.from_bytes(call(fxrp, allow_data)[:32], "big")
    return balance >= price and allowance >= price


# --- Enshrined protocols -----------------------------------------------------


def xrp_usd_1e18() -> int:
    """Live XRP/USD from FTSOv2, scaled to 1e18, range- and freshness-checked."""
    data = "0x" + selector("getFeedById(bytes21)") + abi_encode(["bytes21"], [bytes.fromhex(XRP_USD_FEED)]).hex()
    out = call(resolve("FtsoV2"), data)
    if len(out) < 96:
        raise ChainError("FtsoV2 returned a short feed")
    value = int.from_bytes(out[:32], "big")
    decimals = int.from_bytes(out[32:64], "big", signed=True)  # FtsoV2 decimals is a signed int8
    timestamp = int.from_bytes(out[64:96], "big")

    price = value * 10**18 * 10 ** (-decimals) if decimals < 0 else value * 10**18 // (10**decimals)
    if value <= 0 or not (MIN_XRP_USD_1E18 <= price <= MAX_XRP_USD_1E18):
        raise ChainError("xrp/usd feed out of range")
    if latest_block_timestamp() - timestamp > MAX_FEED_AGE:
        raise ChainError("stale xrp/usd feed")
    return price


def secure_random() -> int:
    """Flare Secure RNG for the tie-break; rejects a round the protocol marks insecure."""
    out = call(resolve("RandomNumberV2"), "0x" + selector("getRandomNumber()"))
    if len(out) < 64:
        raise ChainError("RandomNumberV2 returned a short result")
    if int.from_bytes(out[32:64], "big") != 1:
        raise ChainError("Flare RNG not secure this round")
    return int.from_bytes(out[:32], "big")


__all__ = [
    "ChainError",
    "abi_decode",
    "abi_encode",
    "chain_id",
    "latest_block_timestamp",
    "mm_can_pay",
    "read_fxrp",
    "read_rfq",
    "resolve",
    "secure_random",
    "xrp_usd_1e18",
]
