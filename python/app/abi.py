"""★ ABI encoding for the payloads that cross the contract boundary.

The SETTLE instruction carries `abi.encode(SettleMessage)` — a struct, so a
single tuple argument. The settlement result is decoded on chain with
`abi.decode(_resultData, (address, uint256, address, address, uint256, uint256,
uint256))`, so it is encoded here as seven separate arguments. Getting either
shape wrong is silent until the settlement reverts, which is why both live here
next to the contract's own signatures.
"""

from __future__ import annotations

from eth_abi import decode as abi_decode
from eth_abi import encode as abi_encode

# struct SettleMessage { uint256 rfqId; address contractAddr; }
SETTLE_MESSAGE_TYPES = ["(uint256,address)"]

# abi.encode(address contractAddr, uint256 rfqId, address seller, address winner,
#            uint256 ytAmount, uint256 price, uint256 deadline)
SETTLEMENT_TYPES = ["address", "uint256", "address", "address", "uint256", "uint256", "uint256"]


def decode_settle_message(data: bytes) -> tuple[int, str]:
    """Decode a SETTLE instruction into (rfqId, contractAddr)."""
    try:
        (decoded,) = abi_decode(SETTLE_MESSAGE_TYPES, data)
    except Exception as e:  # eth_abi raises a variety of decoding errors
        raise ValueError(f"ABI decode failed: {e}") from e
    rfq_id, contract_addr = decoded
    return int(rfq_id), str(contract_addr).lower()


def encode_settlement(
    *,
    contract_addr: str,
    rfq_id: int,
    seller: str,
    winner: str,
    yt_amount: int,
    price: int,
    deadline: int,
) -> bytes:
    """Encode the winning settlement exactly as `settle` decodes it."""
    return abi_encode(
        SETTLEMENT_TYPES,
        [contract_addr, rfq_id, seller, winner, yt_amount, price, deadline],
    )
