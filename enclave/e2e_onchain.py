#!/usr/bin/env python3
"""
Full on-chain e2e of the confidential RFQ against the LIVE enclave in GCP Confidential Space (TDX).
Proves the two auth guardrails end to end on Coston2:

  A. a quote forged for another MM (attacker signs but claims mm = someone else) is rejected;
  B. an authentic quote below the seller's reserve is rejected;
  C. the best authentic quote at/above the reserve wins, the enclave signs it in the TEE, and the
     contract verifies that signature and settles.

Usage: PRIVATE_KEY=0x.. ENCLAVE_URL=http://<ip>:8080 RFQ=0x.. python3 enclave/e2e_onchain.py
"""
import os, sys, json, time, subprocess, requests
from eth_account import Account
from eth_abi import encode as abi_encode
from eth_utils import keccak

RPC = os.environ.get("RPC", "https://coston2-api.flare.network/ext/C/rpc")
CHAIN = 114
ENCLAVE_URL = os.environ.get("ENCLAVE_URL", "http://104.155.152.64:8080")
RFQ = os.environ.get("RFQ", "0xE29D17D25bb2e0b92442A7B4DD9843d46c7dA187")
FXRP = os.environ.get("FXRP", "0xA6fC08A750dC00e6f613e2aabaB5a54949D8B356")
YT = os.environ.get("YT", "0x04A05b47fd57E5230a428111B9c3B45c16493752")
PK = os.environ["PRIVATE_KEY"]
SELLER = subprocess.run(["cast", "wallet", "address", "--private-key", PK], capture_output=True, text=True).stdout.strip()
ONE = 1_000_000
YT_AMT = 100 * ONE
RESERVE = 2 * ONE

def sh(*a):
    r = subprocess.run(list(a), capture_output=True, text=True)
    if r.returncode != 0:
        raise RuntimeError(" ".join(a) + "\n" + r.stderr)
    return r.stdout.strip()

def call(to, sig, *args):
    return sh("cast", "call", to, sig, *[str(a) for a in args], "--rpc-url", RPC)

def send(pk, to, sig, *args, value=None):
    a = ["cast", "send", to]
    if sig: a += [sig, *[str(x) for x in args]]
    if value: a += ["--value", value]
    a += ["--private-key", pk, "--rpc-url", RPC]
    return sh(*a)

def bal(tok, who): return int(call(tok, "balanceOf(address)(uint256)", who).split()[0])

def quote_digest(rfq_id, mm, price, deadline):
    return keccak(abi_encode(
        ["string", "uint256", "address", "uint256", "address", "uint256", "uint256", "uint256"],
        ["AnchorQuote", CHAIN, RFQ, rfq_id, mm, YT_AMT, price, deadline]))

def signed_quote(signer_acct, claimed_mm, price, deadline, rfq_id):
    sm = Account._sign_hash(quote_digest(rfq_id, claimed_mm, price, deadline), signer_acct.key)
    sig = sm.signature.hex()
    return {"mm": claimed_mm, "price": price, "deadline": deadline, "sig": sig if sig.startswith("0x") else "0x" + sig}

def post_settle(rfq_id, quotes):
    return requests.post(ENCLAVE_URL + "/settle", json={"rfq": RFQ, "chainId": CHAIN, "rfqId": rfq_id, "quotes": quotes}, timeout=20)

# sanity: the live enclave the RFQ trusts is the one we are about to call
assert call(RFQ, "enclaveSigner()(address)").lower() == requests.get(ENCLAVE_URL + "/pubkey").json()["address"].lower()
print("enclave", requests.get(ENCLAVE_URL + "/pubkey").json()["address"], "trusted by RFQ", RFQ)

mm1, mm2, attacker = Account.create(), Account.create(), Account.create()
for mm in (mm1, mm2):
    send(PK, mm.address, "", value="1ether")           # gas for the approve
    send(PK, FXRP, "mint(address,uint256)", mm.address, 100 * ONE)
    send(mm.key.hex(), FXRP, "approve(address,uint256)", RFQ, 2**256 - 1)

send(PK, YT, "approve(address,uint256)", RFQ, 2**256 - 1)
send(PK, RFQ, "openRfq(uint256,uint256)", YT_AMT, RESERVE)
rfq_id = int(call(RFQ, "nextId()(uint256)").split()[0]) - 1
deadline = int(time.time()) + 3600
print(f"opened RFQ #{rfq_id}: {YT_AMT/ONE} YT, reserve {RESERVE/ONE} FXRP\n")

# A. forged quote: attacker signs but claims to be mm1 -> enclave must reject (recovers attacker != mm1)
forged = signed_quote(attacker, mm1.address, 5 * ONE, deadline, rfq_id)
rA = post_settle(rfq_id, [forged])
print("A. forged-for-another-MM   ->", rA.status_code, rA.json())
assert rA.status_code == 400, "forged quote should be rejected"

# B. authentic but below reserve: mm2 signs price 1 < reserve 2 -> enclave must reject
low = signed_quote(mm2, mm2.address, 1 * ONE, deadline, rfq_id)
rB = post_settle(rfq_id, [low])
print("B. authentic below reserve ->", rB.status_code, rB.json())
assert rB.status_code == 400, "below-reserve quote should be rejected"

# D. quote flooding: >32 quotes is rejected outright (bounds the enclave's work per request)
flood = [signed_quote(mm1, mm1.address, (3 + i) * ONE, deadline, rfq_id) for i in range(33)]
rD = post_settle(rfq_id, flood)
print("D. quote flooding (33)     ->", rD.status_code, rD.json())
assert rD.status_code == 400 and "too many" in rD.json().get("error", "")

# C. two authentic quotes at/above reserve: mm1=4, mm2=6 -> enclave picks mm2, signs, we settle
q1 = signed_quote(mm1, mm1.address, 4 * ONE, deadline, rfq_id)
q2 = signed_quote(mm2, mm2.address, 6 * ONE, deadline, rfq_id)
rC = post_settle(rfq_id, [q1, q2])
s = rC.json()
print("C. best authentic quote    ->", rC.status_code, {k: s[k] for k in ("winner", "price")})
assert rC.status_code == 200 and s["winner"].lower() == mm2.address.lower() and s["price"] == 6 * ONE

seller_before = bal(FXRP, SELLER)
send(PK, RFQ, "settle((uint256,address,address,uint256,uint256,uint256),uint8,bytes32,bytes32)",
     f'({rfq_id},{SELLER},{s["winner"]},{s["ytAmount"]},{s["price"]},{s["deadline"]})', s["v"], s["r"], s["s"])
print(f"\nSETTLED on-chain: seller +{(bal(FXRP,SELLER)-seller_before)/ONE} FXRP, winner mm2 holds {bal(YT,mm2.address)/ONE} YT")
assert bal(FXRP, SELLER) - seller_before == 6 * ONE and bal(YT, mm2.address) == YT_AMT

# replay of the settled RFQ must fail
replay = subprocess.run(["cast", "send", RFQ,
    "settle((uint256,address,address,uint256,uint256,uint256),uint8,bytes32,bytes32)",
    f'({rfq_id},{SELLER},{s["winner"]},{s["ytAmount"]},{s["price"]},{s["deadline"]})', str(s["v"]), s["r"], s["s"],
    "--private-key", PK, "--rpc-url", RPC], capture_output=True, text=True)
print("replay rejected:", replay.returncode != 0)
assert replay.returncode != 0
print("\nALL E2E CHECKS PASSED")
