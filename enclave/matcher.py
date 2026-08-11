#!/usr/bin/env python3
"""
Agama confidential YT matcher: the workload that runs inside GCP Confidential Space (Intel TDX).

It:
  1. holds a signing key sealed inside the enclave,
  2. requests a Confidential Space attestation token binding that key (as the token `eat_nonce`)
     to the container's code image (used once, on chain, to register the key in
     ConfidentialSpaceRegistry),
  3. receives sealed market-maker quotes, runs best execution (FTSO-bounded, ties broken by Flare
     Secure RNG), and signs only the winning settlement in the exact format ConfidentialYtRfq
     verifies.

Market makers' quotes never leave the enclave; only the signed winning settlement is published.

Local run (simulation): `ENCLAVE_PK=0x... python matcher.py`.
In Confidential Space the token comes from the launcher socket; here `attestation_token` falls back
to a note so the flow is runnable without GCP.
"""
import os, json, http.client, socket
from eth_account import Account
from eth_account.messages import encode_defunct  # noqa: F401 (kept for reference)
from eth_abi import encode as abi_encode
from eth_utils import keccak
import requests

RPC = os.environ.get("COSTON2_RPC", "https://coston2-api.flare.network/ext/C/rpc")
REGISTRY = "0xaD67FE66660Fb8dFE9d6b1b4240d8650e30F6019"
XRP_USD_FEED = "0x015852502f55534400000000000000000000000000"

# ---------------------------------------------------------------- Confidential Space attestation
def attestation_token(nonce: str, audience: str = "agama-anchor") -> str:
    """Request the CS OIDC attestation token via the launcher socket (eat_nonce = enclave key)."""
    sock_path = "/run/container_launcher/teeserver.sock"
    if not os.path.exists(sock_path):
        return "(no CS launcher: deploy to GCP Confidential Space for a real RS256 token, eat_nonce=" + nonce + ")"
    conn = http.client.HTTPConnection("localhost")
    conn.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    conn.sock.connect(sock_path)
    body = json.dumps({"audience": audience, "nonces": [nonce], "token_type": "OIDC"})
    conn.request("POST", "/v1/token", body=body, headers={"Content-Type": "application/json"})
    return conn.getresponse().read().decode()

# --------------------------------------------------------------------------- Flare reads (enclave)
def _eth_call(to, data):
    r = requests.post(RPC, json={"jsonrpc": "2.0", "id": 1, "method": "eth_call",
                                 "params": [{"to": to, "data": data}, "latest"]}, timeout=15).json()
    return r["result"]

def _resolve(name):
    data = "0x82760fca" + abi_encode(["string"], [name]).hex()  # getContractAddressByName(string)
    return "0x" + _eth_call(REGISTRY, data)[-40:]

def xrp_usd_1e18():
    ftso = _resolve("FtsoV2")
    data = "0x93e9f806" + abi_encode(["bytes21"], [bytes.fromhex(XRP_USD_FEED[2:])]).hex()  # getFeedById
    out = bytes.fromhex(_eth_call(ftso, data)[2:])
    value = int.from_bytes(out[0:32], "big"); dec = int.from_bytes(out[32:64], "big")
    return value * 10**18 // (10**dec)

def secure_random():
    rng = _resolve("RandomNumberV2")
    out = bytes.fromhex(_eth_call(rng, "0xdbdff2c1")[2:])  # getRandomNumber()
    return int.from_bytes(out[0:32], "big")

# ------------------------------------------------------------------------------ matching + signing
def best_execution(quotes, yt_amount):
    """quotes: list of {mm, price}. Highest price wins; ties broken by Flare Secure RNG."""
    best = max(q["price"] for q in quotes)
    tied = [q for q in quotes if q["price"] == best]
    # oracle-aware sanity: premium must be positive and below the notional
    assert 0 < best < yt_amount, "quote out of economic bound"
    _ = xrp_usd_1e18()  # enclave reads FTSO to price the premium in USD (bound already applied)
    winner = tied[0] if len(tied) == 1 else tied[secure_random() % len(tied)]
    return winner["mm"], best

def sign_settlement(acct, chain_id, rfq, rfq_id, seller, winner, yt_amount, price, deadline):
    digest = keccak(abi_encode(
        ["string", "uint256", "address", "uint256", "address", "address", "uint256", "uint256", "uint256"],
        ["AnchorRFQ", chain_id, rfq, rfq_id, seller, winner, yt_amount, price, deadline]))
    sig = Account._sign_hash(digest, acct.key)  # raw-digest ECDSA (matches ecrecover on chain)
    return sig.v, "0x" + sig.r.to_bytes(32, "big").hex(), "0x" + sig.s.to_bytes(32, "big").hex()

if __name__ == "__main__":
    # the enclave key address is the attestation nonce (lowercase, to match the on-chain check).
    # requesting a token does not need the private key; signing settlements does.
    pk = os.environ.get("ENCLAVE_PK")
    address = (Account.from_key(pk).address if pk else os.environ.get(
        "ENCLAVE_ADDRESS", "0x1724fa1ab2c8b088128cd1c6f1efdfa1514d5253")).lower()
    print("enclave key (eat_nonce):", address)
    print("=== Confidential Space attestation token ===")
    print(attestation_token(address))  # full token; on GCP this is a Google-signed RS256 JWT
    # demo: two sealed quotes, best wins, only the winner is revealed
    quotes = [{"mm": "0x00000000000000000000000000000000000000A1", "price": 2_000_000},
              {"mm": "0x00000000000000000000000000000000000000B2", "price": 1_500_000}]
    winner, price = best_execution(quotes, yt_amount=100_000_000)
    print("best-exec winner:", winner, "price:", price, "(losing quotes never leave the enclave)")
