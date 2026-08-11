#!/usr/bin/env python3
"""
Agama confidential YT matcher: the workload that RUNS LIVE inside GCP Confidential Space (Intel TDX).

On startup it generates a signing key INSIDE the enclave (nobody, not even the operator, sees the
private key) and requests a Confidential Space attestation token binding that key (as `eat_nonce`)
to the container image. That token is verified once on chain (ConfidentialSpaceRegistry) to register
the key. Then it serves:

  GET  /pubkey       -> the enclave signing address (also the attestation eat_nonce)
  GET  /attestation  -> the Confidential Space OIDC attestation token (RS256 JWT)
  POST /settle       -> {rfq, chainId, rfqId, quotes:[{mm, price, deadline, sig}]}
                        Authenticates every quote (the MM must have signed it, see quoteDigest), reads
                        the RFQ terms (seller, ytAmount, reserve) from chain, runs best execution
                        (reserve-bounded, ties broken by Flare Secure RNG) and returns the enclave
                        signature {seller, winner, ytAmount, price, deadline, v, r, s}. Losing quotes
                        never leave the enclave; only the signed winning settlement is returned.

The endpoint is safe to expose: a caller cannot forge a quote for an MM (signature check), cannot
alter the RFQ terms (read from chain, not the request), and cannot win below the seller's reserve
(enforced here and again on-chain in settle).
"""
import os, json, http.client, socket
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from eth_account import Account
from eth_abi import encode as abi_encode
from eth_utils import keccak
import requests

RPC = os.environ.get("COSTON2_RPC", "https://coston2-api.flare.network/ext/C/rpc")
REGISTRY = "0xaD67FE66660Fb8dFE9d6b1b4240d8650e30F6019"
XRP_USD_FEED = "0x015852502f55534400000000000000000000000000"
SEL_RFQS = keccak(b"rfqs(uint256)")[:4].hex()
SEL_SIGNER = keccak(b"enclaveSigner()")[:4].hex()
SEL_FXRP = keccak(b"fxrp()")[:4].hex()
SEL_BAL = keccak(b"balanceOf(address)")[:4].hex()
SEL_ALLOW = keccak(b"allowance(address,address)")[:4].hex()

ENCLAVE = Account.create()          # key generated in the enclave; never leaves the TEE
ADDRESS = ENCLAVE.address.lower()

def attestation_token(nonce, audience="agama-anchor"):
    sock_path = "/run/container_launcher/teeserver.sock"
    if not os.path.exists(sock_path):
        return "(no CS launcher; run in GCP Confidential Space) eat_nonce=" + nonce
    conn = http.client.HTTPConnection("localhost")
    conn.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); conn.sock.connect(sock_path)
    conn.request("POST", "/v1/token",
                 body=json.dumps({"audience": audience, "nonces": [nonce], "token_type": "OIDC"}),
                 headers={"Content-Type": "application/json"})
    return conn.getresponse().read().decode()

def _call(to, data):
    return requests.post(RPC, json={"jsonrpc": "2.0", "id": 1, "method": "eth_call",
                                    "params": [{"to": to, "data": data}, "latest"]}, timeout=15).json()["result"]

def _resolve(name):
    return "0x" + _call(REGISTRY, "0x82760fca" + abi_encode(["string"], [name]).hex())[-40:]

def read_rfq(rfq, rfq_id):
    out = bytes.fromhex(_call(rfq, "0x" + SEL_RFQS + abi_encode(["uint256"], [rfq_id]).hex())[2:])
    return ("0x" + out[12:32].hex(), int.from_bytes(out[32:64], "big"),
            int.from_bytes(out[64:96], "big"), int.from_bytes(out[96:128], "big") != 0)

def rfq_trusts_enclave(rfq):
    return _call(rfq, "0x" + SEL_SIGNER)[-40:].lower() == ADDRESS[2:]

def read_fxrp(rfq):
    return "0x" + _call(rfq, "0x" + SEL_FXRP)[-40:]

def mm_can_pay(fxrp, rfq, mm, price):
    bal = int(_call(fxrp, "0x" + SEL_BAL + abi_encode(["address"], [mm]).hex()), 16)
    allw = int(_call(fxrp, "0x" + SEL_ALLOW + abi_encode(["address", "address"], [mm, rfq]).hex()), 16)
    return bal >= price and allw >= price

def xrp_usd_1e18():
    out = bytes.fromhex(_call(_resolve("FtsoV2"),
        "0x93e9f806" + abi_encode(["bytes21"], [bytes.fromhex(XRP_USD_FEED[2:])]).hex())[2:])
    return int.from_bytes(out[:32], "big") * 10**18 // (10 ** int.from_bytes(out[32:64], "big"))

def secure_random():
    return int.from_bytes(bytes.fromhex(_call(_resolve("RandomNumberV2"), "0xdbdff2c1")[2:])[:32], "big")

def quote_digest(chain_id, rfq, rfq_id, mm, yt_amount, price, deadline):
    return keccak(abi_encode(
        ["string", "uint256", "address", "uint256", "address", "uint256", "uint256", "uint256"],
        ["AnchorQuote", chain_id, rfq, rfq_id, mm, yt_amount, price, deadline]))

def quote_is_authentic(chain_id, rfq, rfq_id, yt_amount, q):
    d = quote_digest(chain_id, rfq, rfq_id, q["mm"], yt_amount, int(q["price"]), int(q["deadline"]))
    try:
        rec = Account._recover_hash(d, signature=bytes.fromhex(q["sig"][2:]))
    except Exception:
        return False
    return rec.lower() == q["mm"].lower()

def best_execution(quotes, yt_amount, min_price):
    valid = [q for q in quotes if min_price <= int(q["price"]) < yt_amount]  # reserve floor + sanity ceiling
    assert valid, "no eligible quote (must be authentic, solvent, and at or above the reserve)"
    _ = xrp_usd_1e18()  # oracle-aware: quotes are FXRP premiums the enclave can price against XRP/USD
    best = max(int(q["price"]) for q in valid)
    tied = [q for q in valid if int(q["price"]) == best]
    win = tied[0] if len(tied) == 1 else tied[secure_random() % len(tied)]
    return win["mm"], best, int(win["deadline"])

def sign_settlement(chain_id, rfq, rfq_id, seller, winner, yt_amount, price, deadline):
    digest = keccak(abi_encode(
        ["string", "uint256", "address", "uint256", "address", "address", "uint256", "uint256", "uint256"],
        ["AnchorRFQ", chain_id, rfq, rfq_id, seller, winner, yt_amount, price, deadline]))
    sm = Account._sign_hash(digest, ENCLAVE.key)  # raw-digest ECDSA (matches on-chain ecrecover)
    return sm.v, "0x" + format(sm.r, "064x"), "0x" + format(sm.s, "064x")

TOKEN = None

class H(BaseHTTPRequestHandler):
    def _s(self, code, body):
        b = json.dumps(body).encode(); self.send_response(code)
        self.send_header("Content-Type", "application/json"); self.end_headers(); self.wfile.write(b)
    def log_message(self, *a): pass
    def do_GET(self):
        if self.path == "/pubkey": self._s(200, {"address": ADDRESS})
        elif self.path == "/attestation": self._s(200, {"token": TOKEN})
        else: self._s(404, {"error": "not found"})
    def do_POST(self):
        if self.path != "/settle": return self._s(404, {"error": "not found"})
        d = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))))
        try:
            rfq, chain_id, rfq_id = d["rfq"], int(d["chainId"]), int(d["rfqId"])
            assert rfq_trusts_enclave(rfq), "rfq does not trust this enclave"
            seller, yt_amount, min_price, is_open = read_rfq(rfq, rfq_id)      # authoritative terms
            assert is_open, "rfq not open"
            fxrp = read_fxrp(rfq)
            auth = [q for q in d["quotes"] if quote_is_authentic(chain_id, rfq, rfq_id, yt_amount, q)]
            payable = [q for q in auth if mm_can_pay(fxrp, rfq, q["mm"], int(q["price"]))]  # winner can settle
            winner, price, deadline = best_execution(payable, yt_amount, min_price)
            v, r, s = sign_settlement(chain_id, rfq, rfq_id, seller, winner, yt_amount, price, deadline)
            self._s(200, {"seller": seller, "winner": winner, "ytAmount": yt_amount,
                          "price": price, "deadline": deadline, "v": v, "r": r, "s": s})
        except Exception as e:
            self._s(400, {"error": str(e)})

if __name__ == "__main__":
    TOKEN = attestation_token(ADDRESS)
    print("enclave key (eat_nonce):", ADDRESS)
    print("=== Confidential Space attestation token ===")
    print(TOKEN)
    print("serving on :8080 (/pubkey /attestation /settle)")
    ThreadingHTTPServer(("0.0.0.0", 8080), H).serve_forever()
