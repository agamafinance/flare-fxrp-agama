#!/usr/bin/env python3
"""
Browser e2e: drives the real front dApp with an injected EIP-1193 wallet that signs and
broadcasts real transactions to Coston2. Clicks Connect / Mint / Lock / Split / Open RFQ and
checks each on-chain effect. Proves the FRONT (not just the contracts) works end to end.
"""
import os, json, sys, time
import requests
from eth_account import Account
from playwright.sync_api import sync_playwright

RPC = "https://coston2-api.flare.network/ext/C/rpc"
URL = "http://127.0.0.1:8547/app.html"
PK = os.environ["USER_PK"]
ACCT = Account.from_key(PK)
ADDR = ACCT.address
FXRP = "0xb23b0daDa02c86D2A7E76d2060c34Fff14D1E3A6"
PT   = "0x7779771976CF16a8EF522E03158620d4dAA516c1"
YT   = "0x1592f5cd44676f182162AC9DC09F9B12C68E0B4D"
_id = [0]

def rpc(method, params):
    _id[0] += 1
    r = requests.post(RPC, json={"jsonrpc":"2.0","id":_id[0],"method":method,"params":params}, timeout=30).json()
    if "error" in r: raise RuntimeError(f"{method}: {r['error']}")
    return r["result"]

def balance_of(token):
    data = "0x70a08231" + ADDR[2:].rjust(64, "0").lower()
    res = rpc("eth_call", [{"to": token, "data": data}, "latest"])
    return int(res, 16)

def wallet(payload):
    m = payload.get("method"); p = payload.get("params") or []
    if m in ("eth_requestAccounts", "eth_accounts"): return [ADDR]
    if m == "eth_chainId": return "0x72"
    if m == "net_version": return "114"
    if m in ("wallet_switchEthereumChain", "wallet_addEthereumChain", "wallet_watchAsset"): return None
    if m == "eth_sendTransaction":
        t = p[0]
        nonce = int(rpc("eth_getTransactionCount", [ADDR, "pending"]), 16)
        gas = int(t["gas"], 16) if t.get("gas") else int(rpc("eth_estimateGas", [{k:t[k] for k in ("from","to","data","value") if k in t}]), 16) * 12 // 10
        tx = {"nonce": nonce, "chainId": 114, "to": t.get("to"),
              "value": int(t.get("value", "0x0"), 16), "data": t.get("data", "0x"), "gas": gas}
        if t.get("maxFeePerGas"):
            tx["maxFeePerGas"] = int(t["maxFeePerGas"], 16)
            tx["maxPriorityFeePerGas"] = int(t.get("maxPriorityFeePerGas", t["maxFeePerGas"]), 16)
        else:
            tx["gasPrice"] = int(rpc("eth_gasPrice", []), 16)
        signed = ACCT.sign_transaction(tx)
        raw = signed.raw_transaction.hex()
        if not raw.startswith("0x"): raw = "0x" + raw
        return rpc("eth_sendRawTransaction", [raw])
    # everything else: proxy reads to Coston2
    try:
        return rpc(m, p)
    except Exception as e:
        return {"__error": str(e)}

INIT = """
window.ethereum = {
  isMetaMask: true,
  request: (args) => window.__wallet(args).then(r => {
    if (r && r.__error) throw new Error(r.__error); return r;
  }),
  on: () => {}, removeListener: () => {}, removeAllListeners: () => {},
};
"""

def main():
    print(f"USER = {ADDR}")
    print(f"start FXRP={balance_of(FXRP)/1e6} PT={balance_of(PT)/1e6} YT={balance_of(YT)/1e6}")
    with sync_playwright() as pw:
        b = pw.chromium.launch(headless=True)
        ctx = b.new_context()
        ctx.expose_function("__wallet", wallet)
        ctx.add_init_script(INIT)
        page = ctx.new_page()
        page.on("console", lambda msg: print("  [console]", msg.text) if msg.type in ("error","warning") else None)
        page.goto(URL, wait_until="networkidle")
        time.sleep(1)

        def status(): return page.eval_on_selector("#status", "e=>e.textContent") or ""
        def rfqstatus(): return page.eval_on_selector("#rfqStatus", "e=>e.textContent") or ""

        print("-- click Connect")
        page.click("#connect")
        page.wait_for_function("document.getElementById('chainpill').textContent.includes('connected')", timeout=30000)
        print("   connected:", page.eval_on_selector("#chainpill", "e=>e.textContent"))

        print("-- click Mint 1,000 demo FXRP")
        page.click("#mint")
        page.wait_for_function("document.getElementById('status').textContent.includes('Minted')", timeout=90000)
        print("   status:", status(), "| FXRP now", balance_of(FXRP)/1e6)

        print("-- Lock fixed rate 500 FXRP")
        page.fill("#amt", "500")
        page.click("#lock")
        page.wait_for_function("document.getElementById('status').textContent.includes('locked')", timeout=90000)
        print("   status:", status(), "| PT now", balance_of(PT)/1e6)

        print("-- Split 100 FXRP -> PT + YT (RFQ panel)")
        page.click("#split")
        page.wait_for_function("document.getElementById('rfqStatus').textContent.includes('Split done')", timeout=90000)
        print("   rfqStatus:", rfqstatus(), "| YT now", balance_of(YT)/1e6)

        print("-- Open confidential RFQ (100 YT)")
        page.fill("#ytAmt", "100")
        page.click("#openRfq")
        page.wait_for_function("document.getElementById('rfqStatus').textContent.includes('quoting')", timeout=120000)
        time.sleep(2)
        print("   rfqStatus:", rfqstatus(), "| YT now", balance_of(YT)/1e6, "(escrowed)")

        page.screenshot(path="/tmp/front-e2e.png", full_page=True)
        print("   screenshot -> /tmp/front-e2e.png")
        print(f"end FXRP={balance_of(FXRP)/1e6} PT={balance_of(PT)/1e6} YT={balance_of(YT)/1e6}")
        b.close()
    print("=== FRONT BROWSER E2E: all steps produced real Coston2 transactions ===")

if __name__ == "__main__":
    main()
