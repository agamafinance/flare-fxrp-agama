#!/usr/bin/env python3
"""
Self-contained live confidential-settlement demo for the front-end.

One dedicated demo key plays the seller and the relayer; two ephemeral market makers are created
per run. It opens a real RFQ on Coston2, sends sealed quotes to the LIVE enclave (GCP Confidential
Space / Intel TDX), the enclave signs only the winner in the TEE, and the contract settles on chain.
A forged quote is also sent to prove the auth guardrail. Prints one JSON blob to stdout.
"""
import os, sys, json, time, subprocess, base64, requests
from eth_account import Account
from eth_abi import encode as abi_encode
from eth_utils import keccak

RPC = os.environ.get("RPC", "https://coston2-api.flare.network/ext/C/rpc")
EXPLORER = "https://coston2-explorer.flare.network"
CHAIN = 114
ENCLAVE_URL = os.environ["ENCLAVE_URL"]
RFQ = os.environ["RFQ_ADDR"]
FXRP = os.environ["FXRP_ADDR"]
YT = os.environ["YT_ADDR"]
SPLITTER = os.environ["SPLITTER_ADDR"]
PK = os.environ["DEMO_PRIVATE_KEY"]
ONE = 1_000_000
YT_AMT = 100 * ONE
RESERVE = 2 * ONE
FUND = 50 * ONE
MAX = 2**256 - 1

def sh(*a):
    r = subprocess.run(list(a), capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(" ".join(a) + "\n" + r.stderr)
    return r.stdout.strip()

def call(to, sig, *args):
    return sh("cast", "call", to, sig, *[str(a) for a in args], "--rpc-url", RPC)

def send(pk, to, sig, *args, value=None):
    a = ["cast", "send", to]
    if sig:
        a += [sig, *[str(x) for x in args]]
    if value:
        a += ["--value", value]
    a += ["--private-key", pk, "--rpc-url", RPC, "--json"]
    return json.loads(sh(*a))["transactionHash"]

def bal(tok, who):
    return int(call(tok, "balanceOf(address)(uint256)", who).split()[0])

def qdigest(rid, mm, price, dl):
    return keccak(abi_encode(
        ["string", "uint256", "address", "uint256", "address", "uint256", "uint256", "uint256"],
        ["AnchorQuote", CHAIN, RFQ, rid, mm, YT_AMT, price, dl]))

def sq(acct, mm, price, dl, rid):
    sm = Account._sign_hash(qdigest(rid, mm, price, dl), acct.key)
    sig = sm.signature.hex()
    return {"mm": mm, "price": price, "deadline": dl, "sig": sig if sig.startswith("0x") else "0x" + sig}

def post(rid, quotes):
    return requests.post(ENCLAVE_URL + "/settle",
                         json={"rfq": RFQ, "chainId": CHAIN, "rfqId": rid, "quotes": quotes}, timeout=25)

SELLER = sh("cast", "wallet", "address", "--private-key", PK)
out = {"seller": SELLER, "enclaveUrl": ENCLAVE_URL}

# 1. enclave identity + live TDX attestation
pub = requests.get(ENCLAVE_URL + "/pubkey", timeout=8).json()["address"]
tok = requests.get(ENCLAVE_URL + "/attestation", timeout=8).text.strip().strip('"')
try:
    tok = json.loads(tok).get("token", tok)
except Exception:
    pass
pl = json.loads(base64.urlsafe_b64decode(tok.split(".")[1] + "==="))
out["enclave"] = {
    "address": pub,
    "issuer": pl.get("iss"),
    "hwmodel": pl.get("hwmodel"),
    "dbgstat": pl.get("dbgstat"),
    "imageDigest": pl.get("submods", {}).get("container", {}).get("image_digest"),
}
out["onchainTrusted"] = call(RFQ, "enclaveSigner()(address)").lower() == pub.lower()

# 2. fund two ephemeral market makers (gas + demo FXRP + allowance)
mm1, mm2, attacker = Account.create(), Account.create(), Account.create()
for mm in (mm1, mm2):
    send(PK, mm.address, "", value="120000000000000000")  # 0.12 C2FLR for the approve gas
    send(PK, FXRP, "mint(address,uint256)", mm.address, FUND)
    send(mm.key.hex(), FXRP, "approve(address,uint256)", RFQ, MAX)

# 3. seller obtains YT (mint 100 FXRP, split into 100 PT + 100 YT) and opens the RFQ
send(PK, FXRP, "mint(address,uint256)", SELLER, YT_AMT)
send(PK, FXRP, "approve(address,uint256)", SPLITTER, MAX)
send(PK, SPLITTER, "split(uint256)", YT_AMT)
send(PK, YT, "approve(address,uint256)", RFQ, MAX)
open_tx = send(PK, RFQ, "openRfq(uint256,uint256)", YT_AMT, RESERVE)
rid = int(call(RFQ, "nextId()(uint256)").split()[0]) - 1
dl = int(time.time()) + 3600
out.update({"rfqId": rid, "openTx": open_tx, "ytAmount": 100, "reserve": 2})

# 4. guardrail: a quote forged for another MM is rejected off-chain by the enclave
rF = post(rid, [sq(attacker, mm1.address, 5 * ONE, dl, rid)])
out["forgedRejected"] = rF.status_code == 400

# 5. two authentic SEALED bids: mm1 = 4 FXRP, mm2 = 6 FXRP -> enclave picks the best in the TEE
rC = post(rid, [sq(mm1, mm1.address, 4 * ONE, dl, rid), sq(mm2, mm2.address, 6 * ONE, dl, rid)])
s = rC.json()
winner = s["winner"]
won1 = winner.lower() == mm1.address.lower()
out["bids"] = [
    {"mm": mm1.address, "price": 4, "won": won1},
    {"mm": mm2.address, "price": 6, "won": not won1},
]
out["winner"] = winner
out["price"] = int(s["price"] / ONE)
out["signature"] = {"v": s["v"], "r": s["r"]}

# 6. relay the enclave-signed settlement; the contract verifies and settles atomically
before = bal(FXRP, SELLER)
settle_tx = send(PK, RFQ, "settle((uint256,address,address,uint256,uint256,uint256),uint8,bytes32,bytes32)",
                 f'({rid},{SELLER},{winner},{s["ytAmount"]},{s["price"]},{s["deadline"]})', s["v"], s["r"], s["s"])
out["settleTx"] = settle_tx
out["sellerPremium"] = int((bal(FXRP, SELLER) - before) / ONE)
out["explorer"] = EXPLORER

print(json.dumps(out))
