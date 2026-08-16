"""Shared fixtures for the extension tests: a stubbed chain and signed quotes.

Every test runs against an open, solvent RFQ on a live oracle. Each test then
perturbs exactly one thing, so a failure names the guard that broke.
"""

import json

from eth_abi import decode as abi_decode
from eth_abi import encode as abi_encode
from eth_keys import KeyAPI

from app import chain, quotes
from base.encoding import bytes_to_hex, hex_to_bytes

KEYS = KeyAPI()

RFQ = "0x000000000000000000000000000000000000cafe"
FXRP = "0x00000000000000000000000000000000000fa5e0"
CHAIN_ID = 114
YT_AMOUNT = 100_000_000       # 100 YT at 6dp
MIN_PRICE = 2_000_000         # 2 FXRP reserve
NOW = 1_800_000_000
DEADLINE = NOW + 3600
XRP_USD = 500_000_000_000_000_000  # $0.50 at 1e18

MM1 = KEYS.PrivateKey(bytes([0x11] * 32))
MM2 = KEYS.PrivateKey(bytes([0x22] * 32))
SELLER = KEYS.PrivateKey(bytes([0x33] * 32))


def addr(pk):
    return pk.public_key.to_address().lower()


def stub_chain(monkeypatch):
    """Point every chain read at a fixed, healthy state."""
    monkeypatch.setattr(chain, "chain_id", lambda: CHAIN_ID)
    monkeypatch.setattr(chain, "latest_block_timestamp", lambda: NOW)
    monkeypatch.setattr(
        chain, "read_rfq", lambda _rfq, _id: (addr(SELLER), YT_AMOUNT, MIN_PRICE, NOW + 900, True)
    )
    monkeypatch.setattr(chain, "read_fxrp", lambda _rfq: FXRP)
    monkeypatch.setattr(chain, "xrp_usd_1e18", lambda: XRP_USD)
    monkeypatch.setattr(chain, "secure_random", lambda: 12345)
    monkeypatch.setattr(chain, "mm_can_pay", lambda *_a: True)


def signed_quote(pk, price, *, rfq_id=1, deadline=DEADLINE, mm=None, chain_id=CHAIN_ID):
    """A quote payload as a market maker submits it."""
    claimed = mm or addr(pk)
    digest = quotes.quote_digest(CHAIN_ID, RFQ, rfq_id, claimed, YT_AMOUNT, price, deadline)
    sig = KEYS.ecdsa_sign(digest, pk)
    return {
        "rfq": RFQ,
        "chainId": chain_id,
        "rfqId": rfq_id,
        "mm": claimed,
        "price": price,
        "deadline": deadline,
        "sig": "0x" + sig.to_bytes().hex(),
    }


def quote_msg(payload):
    return bytes_to_hex(json.dumps(payload).encode())


def settle_msg(rfq_id=1, contract=RFQ):
    return bytes_to_hex(abi_encode(["(uint256,address)"], [(rfq_id, contract)]))


def decode_settlement(data_hex):
    return abi_decode(
        ["address", "uint256", "address", "address", "uint256", "uint256", "uint256"],
        hex_to_bytes(data_hex),
    )
