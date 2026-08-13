"use client";

import { useEffect, useRef, useState } from "react";
import { useAccount, useReadContract } from "wagmi";
import { readContract } from "@wagmi/core";
import { parseUnits, formatUnits } from "viem";
import { config } from "@/lib/wagmi";
import { ADDR, VAULTS, DECIMALS, anchorAbi, erc20Abi, ftsoAbi, vaultAbi, MAX_UINT } from "@/lib/contracts";
import { useSelectedVault } from "./vaultStore";
import { fmt } from "./format";
import { useAction } from "./useAction";

function useCountUp(target: number | null, ms = 700) {
  const [v, setV] = useState(0);
  const last = useRef(0);
  useEffect(() => {
    if (target == null) return;
    const from = last.current;
    const start = performance.now();
    let raf = 0;
    const tick = (t: number) => {
      const p = Math.min(1, (t - start) / ms);
      const eased = 1 - Math.pow(1 - p, 3);
      setV(from + (target - from) * eased);
      if (p < 1) raf = requestAnimationFrame(tick);
      else last.current = target;
    };
    raf = requestAnimationFrame(tick);
    return () => cancelAnimationFrame(raf);
  }, [target, ms]);
  return v;
}

function until(sec: number, now: number): string {
  const s = sec - now;
  if (s <= 0) return "now";
  if (s > 86400) return `in ${Math.round(s / 86400)} days`;
  if (s > 3600) return `in ~${Math.round(s / 3600)}h`;
  return `in ~${Math.max(1, Math.round(s / 60))}m`;
}

function GrowthCurve() {
  return (
    <svg className="curve" viewBox="0 0 300 42" preserveAspectRatio="none" aria-hidden>
      <defs>
        <linearGradient id="gc" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" stopColor="var(--up)" stopOpacity="0.34" />
          <stop offset="1" stopColor="var(--up)" stopOpacity="0" />
        </linearGradient>
      </defs>
      <path d="M0 34 C 90 33, 150 26, 210 15 S 285 5, 300 4 L 300 42 L 0 42 Z" fill="url(#gc)" />
      <path d="M0 34 C 90 33, 150 26, 210 15 S 285 5, 300 4" fill="none" stroke="var(--up)" strokeWidth="1.6" />
      <circle cx="300" cy="4" r="3" fill="var(--up)" />
    </svg>
  );
}

export function DepositWidget() {
  const { address, isConnected } = useAccount();
  const { vault: cfg, idx, setIdx } = useSelectedVault();
  const ready = isConnected;
  const [amt, setAmt] = useState("500");
  const { run, status, busy, writeContractAsync } = useAction();
  const [now, setNow] = useState(0);
  useEffect(() => { setNow(Math.floor(Date.now() / 1000)); const t = setInterval(() => setNow(Math.floor(Date.now() / 1000)), 30000); return () => clearInterval(t); }, []);

  const amtNum = Number(amt);
  const amtWei = amtNum > 0 ? parseUnits(amt || "0", DECIMALS) : 0n;

  const { data: quote } = useReadContract({ address: cfg.anchor, abi: anchorAbi, functionName: "previewLock", args: [amtWei], query: { enabled: amtNum > 0 } });
  const { data: xrpUsd } = useReadContract({ address: ADDR.ftso, abi: ftsoAbi, functionName: "xrpUsd1e18", query: { refetchInterval: 15000 } });
  const { data: maturity } = useReadContract({ address: cfg.vault, abi: vaultAbi, functionName: "maturity" });

  const ptOut = quote?.[0];
  const aprE18 = quote?.[1];
  const aprNum = aprE18 !== undefined ? Number(formatUnits(aprE18, 18)) * 100 : null;
  const aprShown = useCountUp(cfg.short ? 0 : aprNum);
  const profit = ptOut !== undefined && amtWei > 0n ? ptOut - amtWei : undefined;
  const usd = xrpUsd ? Number(formatUnits(xrpUsd, 18)) : 0;
  const maturitySec = maturity ? Number(maturity) : 0;

  async function deposit() {
    if (!(amtWei > 0n) || !address) return;
    const allowance = (await readContract(config, { address: ADDR.fxrp, abi: erc20Abi, functionName: "allowance", args: [address, cfg.vault] })) as bigint;
    const steps: Array<() => Promise<`0x${string}`>> = [];
    if (allowance < amtWei) steps.push(() => writeContractAsync({ address: ADDR.fxrp, abi: erc20Abi, functionName: "approve", args: [cfg.vault, MAX_UINT] }));
    steps.push(() => writeContractAsync({ address: cfg.vault, abi: vaultAbi, functionName: "deposit", args: [amtWei, address] }));
    await run(steps, "Depositing and locking your rate…", "Deposited ✓ — your rate is locked");
  }

  async function mint() {
    if (!address) return;
    await run([() => writeContractAsync({ address: ADDR.fxrp, abi: erc20Abi, functionName: "mint", args: [address, parseUnits("1000", DECIMALS)] })], "Minting 1,000 demo FXRP…", "Minted 1,000 FXRP ✓");
  }

  return (
    <div className="widget fadeup">
      {VAULTS.length > 1 && (
        <div className="seg">
          {VAULTS.map((v, i) => (
            <button key={v.key} className={i === idx ? "on" : ""} onClick={() => setIdx(i)}>{v.label}</button>
          ))}
        </div>
      )}

      <div className="widget-head">
        <div>
          <div className="eyebrow">Live fixed rate</div>
          {cfg.short ? (
            <div className="rate">1:1<small>~2h proof vault</small></div>
          ) : (
            <div className="rate">{aprNum === null ? "–" : aprShown.toFixed(2)}<small>% / year</small></div>
          )}
        </div>
        <span className="chip" style={{ alignSelf: "flex-start" }}><span className="dot" />from the pool</span>
      </div>

      <div className="field">
        <label>You deposit</label>
        <div className="inrow">
          <input type="number" min={0} step={10} value={amt} onChange={(e) => setAmt(e.target.value)} placeholder="0" />
          <div className="unit">FXRP</div>
        </div>
      </div>

      <div className="outcome">
        <div className="lbl">
          <span>At maturity{maturitySec && now ? ` · ${until(maturitySec, now)}` : ""}</span>
          <span>withdraw anytime</span>
        </div>
        <div className="big">
          {fmt(ptOut)} <span style={{ fontSize: 15, color: "var(--faint)", fontFamily: "var(--font-sans)" }}>FXRP</span>
          <span className="gain">{cfg.short ? "≈ 1:1" : `${profit !== undefined && profit > 0n ? "+" : ""}${fmt(profit)} locked`}</span>
        </div>
        <GrowthCurve />
      </div>

      <button className="btn-primary" disabled={!ready || busy || !(amtWei > 0n)} onClick={deposit}>
        {!isConnected ? "Connect wallet to deposit" : busy ? "Working…" : "Deposit & lock rate"}
      </button>
      {ready && <button className="btn-ghost" disabled={busy} onClick={mint}>Mint 1,000 demo FXRP</button>}

      <div className="oracle">
        <span>XRP/USD · live FTSO oracle</span>
        <span className="tnum" style={{ color: "var(--soft)", fontWeight: 600 }}>{usd ? `$${usd.toFixed(4)}` : "—"}</span>
      </div>
      <div className={`status ${status.kind}`}>{status.msg}</div>
    </div>
  );
}
