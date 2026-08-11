#!/usr/bin/env python3
"""
Native-XRP on-ramp: full Flare Data Connector (FDC) round-trip.

  1. create + fund an XRPL testnet wallet (faucet)
  2. pay XRP on the XRPL to Agama's treasury address
  3. FDC prepareRequest at the verifier (public testnet API key)
  4. requestAttestation on FdcHub (Flare tx)
  5. wait for the voting round, fetch the Merkle proof from the DA layer
  6. save the attestation as test/vectors/fdc_payment_proof.json

Then `forge test --match-path test/FdcRealProof.t.sol` verifies the real proof on chain and
`script/VerifyFdc.s.sol` credits it through XrpOnRamp.

Requires: xrpl-py, requests, and foundry `cast` on PATH. PRIVATE_KEY (Coston2, gas) in env.
"""
import os, json, time, subprocess
import requests
from xrpl.clients import JsonRpcClient
from xrpl.wallet import Wallet
from xrpl.models.transactions import Payment, Memo
from xrpl.transaction import submit_and_wait

RPC = "https://coston2-api.flare.network/ext/C/rpc"
XRPL = "https://s.altnet.rippletest.net:51234"
VERIFIER = "https://fdc-verifiers-testnet.flare.network/verifier/xrp/Payment/prepareRequest"
DA = "https://ctn2-data-availability.flare.network/api/v1/fdc/proof-by-request-round-raw"
API_KEY = "00000000-0000-0000-0000-000000000000"  # public Coston2 testnet verifier key
FDCHUB = "0x48aC463d7975828989331F4De43341627b9c5f1D"
FEECFG = "0x191a1282Ac700edE65c5B0AaF313BAcC3eA7fC7e"
FSM = "0xA90Db6D10F856799b10ef2A77EBCbF460aC71e52"
ATT_PAYMENT = "0x5061796d656e7400000000000000000000000000000000000000000000000000"
SRC_TESTXRP = "0x7465737458525000000000000000000000000000000000000000000000000000"

def cast(*args):
    return subprocess.check_output(["cast", *args], text=True).strip()

def main():
    pk = os.environ["PRIVATE_KEY"]
    # 1. XRPL wallet
    acct = requests.post("https://faucet.altnet.rippletest.net/accounts", timeout=30).json()
    payer = Wallet.from_seed(acct["seed"]); treasury = Wallet.create()
    print("payer", payer.address, "-> treasury", treasury.address)
    client = JsonRpcClient(XRPL)
    # 2. XRPL payment (memo carries the Flare recipient)
    tx = Payment(account=payer.address, destination=treasury.address, amount="11000000",
                 memos=[Memo(memo_data="f6d3C9Ed2115A5197F96f6189F6D63B51022Fe16")])
    h = submit_and_wait(tx, client, payer).result["hash"]
    print("XRPL tx", h)
    # 3. prepareRequest
    body = {"attestationType": ATT_PAYMENT, "sourceId": SRC_TESTXRP,
            "requestBody": {"transactionId": "0x" + h, "inUtxo": "0", "utxo": "0"}}
    pr = requests.post(VERIFIER, headers={"X-API-KEY": API_KEY}, json=body, timeout=30).json()
    assert pr["status"] == "VALID", pr
    abi = pr["abiEncodedRequest"]
    # 4. requestAttestation on FdcHub
    fee = cast("call", FEECFG, "getRequestFee(bytes)(uint256)", abi, "--rpc-url", RPC).split()[0]
    txh = json.loads(cast("send", FDCHUB, "requestAttestation(bytes)", abi, "--value", fee,
                          "--private-key", pk, "--rpc-url", RPC, "--json"))["transactionHash"]
    blk = cast("tx", txh, "blockNumber", "--rpc-url", RPC)
    ts = int(cast("block", blk, "-f", "timestamp", "--rpc-url", RPC).split()[0])
    t0 = int(cast("call", FSM, "firstVotingRoundStartTs()(uint64)", "--rpc-url", RPC).split()[0])
    dur = int(cast("call", FSM, "votingEpochDurationSeconds()(uint64)", "--rpc-url", RPC).split()[0])
    rnd = (ts - t0) // dur
    print("voting round", rnd, "- waiting for finalization")
    # 5. fetch the proof from the DA layer
    for _ in range(30):
        time.sleep(20)
        r = requests.post(DA, json={"votingRoundId": rnd, "requestBytes": abi}, timeout=20).json()
        if r.get("response_hex") and r.get("proof"):
            break
    # 6. save the vector
    out = {"response_hex": r["response_hex"], "proof": r["proof"], "xrpl_tx": h,
           "payer": payer.address, "treasury": treasury.address, "votingRoundId": rnd}
    json.dump(out, open("test/vectors/fdc_payment_proof.json", "w"), indent=2)
    print("saved test/vectors/fdc_payment_proof.json")

if __name__ == "__main__":
    main()
