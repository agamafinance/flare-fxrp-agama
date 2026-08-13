"use client";

import { useState } from "react";
import { useAccount, useReadContract } from "wagmi";
import { readContract } from "@wagmi/core";
import { parseUnits } from "viem";
import { config } from "@/lib/wagmi";
import { ADDR, DECIMALS, erc20Abi, rfqAbi, splitterAbi, MAX_UINT } from "@/lib/contracts";
import { fmt } from "./format";
import { useAction } from "./useAction";

export function AdvancedRfq() {
  const { address, isConnected } = useAccount();
  const ready = isConnected; // reads target Coston2 via the proxy; run() forces the chain before any tx
  const { run, status, setStatus, busy, writeContractAsync } = useAction();
  const [ytAmt, setYtAmt] = useState("100");
  const [reserve, setReserve] = useState("2");
  const [myRfqId, setMyRfqId] = useState(0n);

  const { data: balY } = useReadContract({
    address: ADDR.yt, abi: erc20Abi, functionName: "balanceOf", args: address ? [address] : undefined,
    query: { enabled: ready, refetchInterval: 10000 },
  });
  const { data: rfq } = useReadContract({
    address: ADDR.rfq, abi: rfqAbi, functionName: "rfqs", args: [myRfqId],
    query: { enabled: ready && myRfqId > 0n, refetchInterval: 8000 },
  });
  const rfqOpen = rfq?.[4];

  async function split() {
    if (!address) return;
    const amt = parseUnits("100", DECIMALS);
    const allowance = (await readContract(config, { address: ADDR.fxrp, abi: erc20Abi, functionName: "allowance", args: [address, ADDR.splitter] })) as bigint;
    const steps: Array<() => Promise<`0x${string}`>> = [];
    if (allowance < amt) steps.push(() => writeContractAsync({ address: ADDR.fxrp, abi: erc20Abi, functionName: "approve", args: [ADDR.splitter, MAX_UINT] }));
    steps.push(() => writeContractAsync({ address: ADDR.splitter, abi: splitterAbi, functionName: "split", args: [amt] }));
    await run(steps, "Splitting 100 FXRP into PT + YT…", "Split done ✓ — you now hold 100 PT + 100 YT");
  }

  async function openRfq() {
    if (!address) return;
    const amt = parseUnits(ytAmt || "0", DECIMALS);
    const price = parseUnits(reserve || "0", DECIMALS);
    if (!(amt > 0n)) return setStatus({ msg: "Enter a YT amount", kind: "err" });
    if (!(price > 0n)) return setStatus({ msg: "Set a reserve price above 0", kind: "err" });
    const allowance = (await readContract(config, { address: ADDR.yt, abi: erc20Abi, functionName: "allowance", args: [address, ADDR.rfq] })) as bigint;
    const steps: Array<() => Promise<`0x${string}`>> = [];
    if (allowance < amt) steps.push(() => writeContractAsync({ address: ADDR.yt, abi: erc20Abi, functionName: "approve", args: [ADDR.rfq, MAX_UINT] }));
    steps.push(() => writeContractAsync({ address: ADDR.rfq, abi: rfqAbi, functionName: "openRfq", args: [amt, price] }));
    await run(steps, "Escrowing YT and opening the confidential RFQ…", "RFQ open ✓ — market makers are quoting privately to the enclave");
    const nid = (await readContract(config, { address: ADDR.rfq, abi: rfqAbi, functionName: "nextId" })) as bigint;
    setMyRfqId(nid - 1n);
  }

  async function cancel() {
    if (myRfqId === 0n) return;
    await run(
      [() => writeContractAsync({ address: ADDR.rfq, abi: rfqAbi, functionName: "cancel", args: [myRfqId] })],
      "Cancelling RFQ, reclaiming your YT…",
      "RFQ cancelled ✓ — YT reclaimed",
    );
    setMyRfqId(0n);
  }

  return (
    <section className="block" style={{ paddingTop: 0 }}>
      <div className="wrap">
        <details className="adv">
          <summary>The other side · confidential market for the yield (TEE)</summary>
          <p className="sub" style={{ marginTop: 16 }}>
            Every deposit splits into a principal claim (what funds your fixed rate) and a
            variable-yield claim (YT). Savers never touch YT. If you hold YT, you can sell it here for a
            guaranteed premium: market makers bid privately inside a Flare Confidential Compute enclave
            (Intel TDX), the enclave signs only the best offer, and only that settles on chain, so
            losing bids never leak and your order can&apos;t be picked off. This YT demand is what funds
            the savers&apos; fixed rate.
          </p>

          <div className="pos" style={{ marginTop: 18 }}>
            <span className="k">Your YT</span>
            <span className="v tnum">{ready ? fmt(balY) : "—"} YT</span>
          </div>

          <button className="btn-ghost" disabled={!ready || busy} onClick={split} style={{ marginTop: 14 }}>
            No YT? Split 100 FXRP → 100 PT + 100 YT
          </button>

          <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 14, marginTop: 16 }}>
            <div>
              <label>YT to sell</label>
              <div className="inrow">
                <input type="number" min={0} step={10} value={ytAmt} onChange={(e) => setYtAmt(e.target.value)} />
                <div className="unit">YT</div>
              </div>
            </div>
            <div>
              <label>Reserve (min price)</label>
              <div className="inrow">
                <input type="number" min={0} step={0.5} value={reserve} onChange={(e) => setReserve(e.target.value)} />
                <div className="unit">FXRP</div>
              </div>
            </div>
          </div>

          <button className="btn-primary" disabled={!ready || busy} onClick={openRfq} style={{ marginTop: 16 }}>
            Open confidential RFQ
          </button>
          {myRfqId > 0n && rfqOpen && (
            <button className="btn-ghost" disabled={busy} onClick={cancel}>
              Cancel RFQ (reclaim YT)
            </button>
          )}
          <div className={`status ${status.kind}`}>
            {myRfqId > 0n && rfqOpen === false
              ? `RFQ #${myRfqId} settled by the enclave · your YT went to the best private quote.`
              : myRfqId > 0n && rfqOpen
                ? `RFQ #${myRfqId} open · market makers are quoting privately to the enclave.`
                : status.msg}
          </div>
        </details>
      </div>
    </section>
  );
}
