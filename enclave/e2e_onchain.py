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
EXPLORER = "https://coston2-explorer.flare.network"
CHAIN = 114
ENCLAVE_URL = os.environ.get("ENCLAVE_URL", "http://104.155.152.64:8080")
RFQ = os.environ.get("RFQ", "0xE316db654d01295bE42bD25E23Af8Ce31D6284B1")
FXRP = os.environ.get("FXRP", "0x03fDE303879d8B366ef384b9Be2F6276A27FCD62")
YT = os.environ.get("YT", "0xA84437A6CAEeeAB1eB208e6E686a761A0B7cDa1d")
PK = os.environ["PRIVATE_KEY"]
SELLER = subprocess.run(["cast", "wallet", "address", "--private-key", PK], capture_output=True, text=True).stdout.strip()
ONE = 1_000_000
YT_AMT = int(os.environ.get("YT_AMT", "100")) * ONE
RESERVE = 2 * ONE
FUND_AMT = int(os.environ.get("FUND_AMT", "100")) * ONE   # FXRP given to each market maker
MINTABLE = os.environ.get("MINTABLE", "1") == "1"          # demo FXRP mints; real FXRP is transferred

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
    a += ["--private-key", pk, "--rpc-url", RPC, "--json"]
    try: return json.loads(sh(*a))["transactionHash"]
    except Exception: return "?"

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
    if MINTABLE: send(PK, FXRP, "mint(address,uint256)", mm.address, FUND_AMT)
    else: send(PK, FXRP, "transfer(address,uint256)", mm.address, FUND_AMT)  # real FXRP: fund from deployer
    send(mm.key.hex(), FXRP, "approve(address,uint256)", RFQ, 2**256 - 1)

print("STEP 1 - seller opens a confidential RFQ on-chain (escrows YT, sets a reserve)")
send(PK, YT, "approve(address,uint256)", RFQ, 2**256 - 1)
open_tx = send(PK, RFQ, "openRfq(uint256,uint256)", YT_AMT, RESERVE)
rfq_id = int(call(RFQ, "nextId()(uint256)").split()[0]) - 1
deadline = int(time.time()) + 3600
print(f"  RFQ #{rfq_id}: {int(YT_AMT/ONE)} YT escrowed, reserve {int(RESERVE/ONE)} FXRP")
print(f"  tx {EXPLORER}/tx/{open_tx}\n")

print("STEP 2 - market makers send SEALED quotes to the enclave; bad ones are rejected off-chain")
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

print("\nSTEP 3 - enclave runs best-execution in the TEE and signs ONLY the winner")
# two authentic quotes at/above reserve: mm1=4, mm2=6 -> enclave picks mm2, signs
q1 = signed_quote(mm1, mm1.address, 4 * ONE, deadline, rfq_id)
q2 = signed_quote(mm2, mm2.address, 6 * ONE, deadline, rfq_id)
rC = post_settle(rfq_id, [q1, q2])
s = rC.json()
print(f"  mm1 quoted 4 FXRP, mm2 quoted 6 FXRP (both private) -> enclave picked {s['winner'][:10]} @ {int(s['price']/ONE)} FXRP")
print(f"  enclave signature v={s['v']} r={s['r'][:14]}... (the losing 4-FXRP quote never touched the chain)")
assert rC.status_code == 200 and s["winner"].lower() == mm2.address.lower() and s["price"] == 6 * ONE

print("\nSTEP 4 - anyone relays the enclave-signed settlement; the contract verifies and settles atomically")
seller_before = bal(FXRP, SELLER)
settle_tx = send(PK, RFQ, "settle((uint256,address,address,uint256,uint256,uint256),uint8,bytes32,bytes32)",
     f'({rfq_id},{SELLER},{s["winner"]},{s["ytAmount"]},{s["price"]},{s["deadline"]})', s["v"], s["r"], s["s"])
print(f"  seller +{int((bal(FXRP,SELLER)-seller_before)/ONE)} FXRP premium, winner MM received {int(bal(YT,mm2.address)/ONE)} YT")
print(f"  tx {EXPLORER}/tx/{settle_tx}")
assert bal(FXRP, SELLER) - seller_before == 6 * ONE and bal(YT, mm2.address) == YT_AMT

# STEP 5: replay of the settled RFQ must fail (RFQ is now closed)
print("\nSTEP 5 - replaying the same settlement reverts (RFQ already closed)")
replay = subprocess.run(["cast", "send", RFQ,
    "settle((uint256,address,address,uint256,uint256,uint256),uint8,bytes32,bytes32)",
    f'({rfq_id},{SELLER},{s["winner"]},{s["ytAmount"]},{s["price"]},{s["deadline"]})', str(s["v"]), s["r"], s["s"],
    "--private-key", PK, "--rpc-url", RPC], capture_output=True, text=True)
print("  replay reverted:", replay.returncode != 0)
assert replay.returncode != 0
print("\nALL E2E CHECKS PASSED")
