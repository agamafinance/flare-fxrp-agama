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
import os, json, http.client, socket, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from eth_account import Account
from eth_abi import encode as abi_encode
from eth_utils import keccak
import requests

MAX_QUOTES = 32          # bound the work per request (signature recoveries + solvency reads)
MAX_BODY = 64 * 1024     # cap the request body before reading/parsing (anti-DoS)
RATE_MAX, RATE_WINDOW = 10, 10.0   # at most 10 /settle requests per 10s PER CALLER (not global)
_rl_lock, _rl = threading.Lock(), {}

def rate_ok(caller):
    now = time.monotonic()
    with _rl_lock:
        if len(_rl) > 4096:  # bound memory: evict callers with no recent requests
            for k in [k for k, v in _rl.items() if not v or now - v[-1] > RATE_WINDOW]:
                del _rl[k]
        q = _rl.setdefault(caller, [])
        while q and now - q[0] > RATE_WINDOW:
            q.pop(0)
        if len(q) >= RATE_MAX:
            return False
        q.append(now)
        return True

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
    # struct Rfq { address seller; uint256 ytAmount; uint256 minPrice; uint256 settleBy; bool open; }
    out = bytes.fromhex(_call(rfq, "0x" + SEL_RFQS + abi_encode(["uint256"], [rfq_id]).hex())[2:])
    return ("0x" + out[12:32].hex(), int.from_bytes(out[32:64], "big"),
            int.from_bytes(out[64:96], "big"), int.from_bytes(out[128:160], "big") != 0)

def rfq_trusts_enclave(rfq):
    return _call(rfq, "0x" + SEL_SIGNER)[-40:].lower() == ADDRESS[2:]

def read_fxrp(rfq):
    return "0x" + _call(rfq, "0x" + SEL_FXRP)[-40:]

def mm_can_pay(fxrp, rfq, mm, price):
    bal = int(_call(fxrp, "0x" + SEL_BAL + abi_encode(["address"], [mm]).hex()), 16)
    allw = int(_call(fxrp, "0x" + SEL_ALLOW + abi_encode(["address", "address"], [mm, rfq]).hex()), 16)
    return bal >= price and allw >= price

MIN_XRP_USD_1E18 = 5 * 10**16     # $0.05: XRP/USD sanity floor
MAX_XRP_USD_1E18 = 50 * 10**18    # $50:   XRP/USD sanity ceiling
MAX_FEED_AGE = 600                # 10 min: reject a stale oracle

def latest_block_ts():
    r = requests.post(RPC, json={"jsonrpc": "2.0", "id": 1, "method": "eth_getBlockByNumber",
                                 "params": ["latest", False]}, timeout=15).json()
    return int(r["result"]["timestamp"], 16)

def xrp_usd_1e18():
    out = bytes.fromhex(_call(_resolve("FtsoV2"),
        "0x93e9f806" + abi_encode(["bytes21"], [bytes.fromhex(XRP_USD_FEED[2:])]).hex())[2:])
    value = int.from_bytes(out[:32], "big")
    dec = int.from_bytes(out[32:64], "big", signed=True)  # FtsoV2 decimals is a signed int8
    px = value * 10**18 * 10**(-dec) if dec < 0 else value * 10**18 // (10 ** dec)
    ts = int.from_bytes(out[64:96], "big")
    assert value > 0 and MIN_XRP_USD_1E18 <= px <= MAX_XRP_USD_1E18, "xrp/usd feed out of range"
    assert latest_block_ts() - ts <= MAX_FEED_AGE, "stale xrp/usd feed"  # freshness guard
    return px

def secure_random():
    out = bytes.fromhex(_call(_resolve("RandomNumberV2"), "0xdbdff2c1")[2:])  # (randomNumber, isSecure, ts)
    assert int.from_bytes(out[32:64], "big") == 1, "Flare RNG not secure this round"
    return int.from_bytes(out[:32], "big")

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

# A per-settlement USD risk band. MAX is the binding, oracle-derived ceiling: with XRP ~$0.5 a $10 cap
# is ~20 FXRP, tighter than a typical notional, so the FTSO price actually changes accept/reject.
MIN_PREMIUM_USD_1E6 = 500_000       # $0.50 floor: reject economic dust
MAX_PREMIUM_USD_1E6 = 10_000_000    # $10 cap

def premium_usd_1e6(price, xrp_usd):
    # price is FXRP (6dp, ~1:1 with XRP); xrp_usd is USD/XRP scaled 1e18 -> USD value in 6dp
    return price * xrp_usd // 10**18

def choose_winner(quotes, yt_amount, min_price, fxrp, rfq):
    xrp_usd = xrp_usd_1e18()  # FTSO XRP/USD: the premium is bounded in real USD terms, not just tokens
    # per-settlement USD cap, but never below the seller's reserve (a high reserve must not be bricked)
    cap = max(MAX_PREMIUM_USD_1E6, 2 * premium_usd_1e6(min_price, xrp_usd))
    def eligible(p):
        u = premium_usd_1e6(p, xrp_usd)
        return min_price <= p < yt_amount and MIN_PREMIUM_USD_1E6 <= u <= cap
    valid = [q for q in quotes if eligible(int(q["price"]))]
    assert valid, "no eligible quote (authentic, at/above reserve, within the FTSO USD band)"
    rnd = secure_random()  # fair tie-break among equal top prices (Flare Secure RNG)
    order = sorted(valid, key=lambda q: (-int(q["price"]), (rnd ^ int(q["mm"], 16))))
    for q in order:  # best price first; first solvent quote wins, so solvency reads are bounded
        if mm_can_pay(fxrp, rfq, q["mm"], int(q["price"])):
            return q["mm"], int(q["price"]), int(q["deadline"]), premium_usd_1e6(int(q["price"]), xrp_usd)
    raise AssertionError("no solvent quote within band at or above the reserve")

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
        if not rate_ok(self.client_address[0]): return self._s(429, {"error": "rate limited"})  # per-caller
        try:
            length = int(self.headers.get("Content-Length", 0))
            if length > MAX_BODY: return self._s(413, {"error": "request too large"})  # in try: a bad
            d = json.loads(self.rfile.read(length))                                    # length/body -> 400, not a crash
            quotes = d["quotes"]
            assert len(quotes) <= MAX_QUOTES, "too many quotes"               # bound the work per request
            rfq, chain_id, rfq_id = d["rfq"], int(d["chainId"]), int(d["rfqId"])
            assert rfq_trusts_enclave(rfq), "rfq does not trust this enclave"  # cheapest gate first: one read
            seller, yt_amount, min_price, is_open = read_rfq(rfq, rfq_id)      # authoritative terms
            assert is_open, "rfq not open"
            fxrp = read_fxrp(rfq)
            auth = [q for q in quotes if quote_is_authentic(chain_id, rfq, rfq_id, yt_amount, q)]
            winner, price, deadline, premiumUsd = choose_winner(auth, yt_amount, min_price, fxrp, rfq)
            v, r, s = sign_settlement(chain_id, rfq, rfq_id, seller, winner, yt_amount, price, deadline)
            self._s(200, {"seller": seller, "winner": winner, "ytAmount": yt_amount,
                          "price": price, "premiumUsd6dp": premiumUsd, "deadline": deadline,
                          "v": v, "r": r, "s": s})
        except Exception as e:
            self._s(400, {"error": str(e)})

if __name__ == "__main__":
    TOKEN = attestation_token(ADDRESS)
    print("enclave key (eat_nonce):", ADDRESS)
    print("=== Confidential Space attestation token ===")
    print(TOKEN)
    print("serving on :8080 (/pubkey /attestation /settle)")
    ThreadingHTTPServer(("0.0.0.0", 8080), H).serve_forever()
