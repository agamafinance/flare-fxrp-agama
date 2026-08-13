"use client";

import { useEffect, useState } from "react";
import { useAccount, useReadContract } from "wagmi";
import { ADDR, erc20Abi, vaultAbi } from "@/lib/contracts";
import { useSelectedVault } from "./vaultStore";
import { fmt } from "./format";
import { useAction } from "./useAction";

function countdown(maturity: number, now: number): string {
  const left = maturity - now;
  if (left <= 0) return "matured · full value now";
  const d = Math.floor(left / 86400);
  const h = Math.floor((left % 86400) / 3600);
  const m = Math.floor((left % 3600) / 60);
  const s = left % 60;
  if (d > 0) return `${d}d ${h}h ${m}m`;
  if (h > 0) return `${h}h ${m}m ${String(s).padStart(2, "0")}s`;
  return `${m}m ${String(s).padStart(2, "0")}s`;
}

export function PositionCard() {
  const { address, isConnected } = useAccount();
  const { vault: cfg } = useSelectedVault();
  const ready = isConnected;
  const { run, status, busy, writeContractAsync } = useAction();
  const [now, setNow] = useState(0);
  useEffect(() => { setNow(Math.floor(Date.now() / 1000)); const t = setInterval(() => setNow(Math.floor(Date.now() / 1000)), 1000); return () => clearInterval(t); }, []);

  const q = { query: { enabled: ready, refetchInterval: 10000 } } as const;
  const { data: balF } = useReadContract({ address: ADDR.fxrp, abi: erc20Abi, functionName: "balanceOf", args: address ? [address] : undefined, ...q });
  const { data: shares } = useReadContract({ address: cfg.vault, abi: vaultAbi, functionName: "balanceOf", args: address ? [address] : undefined, ...q });
  const { data: maturity } = useReadContract({ address: cfg.vault, abi: vaultAbi, functionName: "maturity", query: { enabled: ready } });
  const { data: earlyVal } = useReadContract({ address: cfg.vault, abi: vaultAbi, functionName: "previewWithdrawEarly", args: shares && shares > 0n ? [shares] : undefined, query: { enabled: ready && !!shares && shares > 0n, refetchInterval: 15000 } });

  const maturitySec = maturity ? Number(maturity) : 0;
  const matured = maturitySec > 0 && now >= maturitySec;
  const hasShares = !!shares && shares > 0n;

  async function withdrawNow() {
    if (!address || !shares) return;
    await run([() => writeContractAsync({ address: cfg.vault, abi: vaultAbi, functionName: "withdrawEarly", args: [shares, 0n] })],
      "Selling your position on the AMM at market…", "Withdrawn ✓ — FXRP back in your wallet");
  }
  async function withdrawMaturity() {
    if (!address || !shares) return;
    await run([() => writeContractAsync({ address: cfg.vault, abi: vaultAbi, functionName: "redeem", args: [shares, address, address] })],
      "Redeeming 1:1 for your deposit plus the fixed gain…", "Withdrawn ✓ — full value back in FXRP");
  }

  return (
    <section className="block" id="position" style={{ paddingBottom: 12 }}>
      <div className="wrap">
        <div className="panel">
          <div className="panel-title">
            <h3>Your savings</h3>
            <span className="chip" style={{ marginLeft: "auto" }}>{ready ? cfg.label : "connect to view"}</span>
          </div>
          <div className="pos">
            <span className="k">In your wallet</span>
            <span className="v tnum">{ready ? fmt(balF) : "—"} FXRP</span>
          </div>
          <div className="divider" />
          <div className="pos">
            <span className="k">Locked at a fixed rate</span>
            <span className="v tnum">{ready ? fmt(shares) : "—"} FXRP <span className="muted" style={{ fontSize: 11, fontWeight: 500 }}>at maturity</span></span>
          </div>
          <div className="divider" />
          <div className="pos">
            <div>
              <span className="k">Withdraw now · market</span>
              <div className="muted" style={{ fontSize: 12, marginTop: 3 }}>exit anytime, current value</div>
            </div>
            <div style={{ textAlign: "right" }}>
              <div className="v tnum" style={{ marginBottom: 6 }}>≈ {ready && hasShares ? fmt(earlyVal) : "—"} FXRP</div>
              <button className="btn-wallet" disabled={!ready || !hasShares || busy} onClick={withdrawNow}>Withdraw now</button>
            </div>
          </div>
          <div className="divider" />
          <div className="pos">
            <div>
              <span className="k">Withdraw at maturity · 1:1</span>
              <div className="muted" style={{ fontSize: 12, marginTop: 3 }}>{maturitySec && now ? countdown(maturitySec, now) : ""}</div>
            </div>
            <button className="btn-wallet accent" disabled={!ready || !matured || !hasShares || busy} onClick={withdrawMaturity}>
              {matured ? "Withdraw 1:1" : "Locked till maturity"}
            </button>
          </div>
          {status.msg && <div className={`status ${status.kind}`}>{status.msg}</div>}
        </div>
      </div>
    </section>
  );
}
