'use client';

import { useEffect, useMemo, useState } from 'react';
import FlareChart from '@/components/flare/FlareChart';
import { TokenIcon } from '@/components/icons/TokenIcon';
import { ADDR, toBaseUnits, fromBaseUnits, explorerTx } from '@/lib/flare/config';
import { ANCHOR_ABI, VAULT_ABI } from '@/lib/flare/abis';
import { pub, send, ensureAllowance, useFlareData } from '@/lib/flare/useFlare';
import { useFlareWallet } from '@/lib/flare/WalletProvider';

const DAY = 86400;

export default function FlareEarnPage() {
  const { address, connect } = useFlareWallet();
  const { market, account, refresh } = useFlareData(address as `0x${string}` | undefined);
  const [now, setNow] = useState(0);
  const [maturity, setMaturity] = useState(0);
  const [tab, setTab] = useState<'deposit' | 'withdraw'>('deposit');
  const [amount, setAmount] = useState('500');
  const [est, setEst] = useState('0.00');
  const [status, setStatus] = useState('');
  const [busy, setBusy] = useState(false);
  const [txs, setTxs] = useState<{ label: string; hash: string }[]>([]);

  useEffect(() => { setNow(Math.floor(Date.now() / 1000)); const t = setInterval(() => setNow(Math.floor(Date.now() / 1000)), 1000); return () => clearInterval(t); }, []);
  // read the vault maturity once (chart works before connecting)
  useEffect(() => { pub.readContract({ address: ADDR.vault, abi: VAULT_ABI, functionName: 'maturity' }).then((m) => setMaturity(Number(m as bigint))).catch(() => {}); }, []);

  const amt = useMemo(() => (Number(amount) > 0 ? toBaseUnits(amount) : 0n), [amount]);
  const matured = maturity > 0 && now >= maturity;
  const fromBal = tab === 'deposit' ? account?.fxrp : account?.shares;
  const fromSym = tab === 'deposit' ? 'FXRP' : 'arFXRP';
  const toSym = tab === 'deposit' ? 'arFXRP' : 'FXRP';

  // estimated output
  useEffect(() => {
    let alive = true;
    if (amt <= 0n) { setEst('0.00'); return; }
    if (tab === 'withdraw' && matured) { setEst(fromBaseUnits(amt)); return; }
    const p = tab === 'deposit'
      ? pub.readContract({ address: ADDR.anchor, abi: ANCHOR_ABI, functionName: 'previewLock', args: [amt] }).then((q) => (q as [bigint, bigint])[0])
      : pub.readContract({ address: ADDR.vault, abi: VAULT_ABI, functionName: 'previewWithdrawEarly', args: [amt] }).then((v) => v as bigint);
    p.then((o) => { if (alive) setEst(fromBaseUnits(o)); }).catch(() => { if (alive) setEst('—'); });
    return () => { alive = false; };
  }, [tab, amt, matured]);

  const canSend = !!address && amt > 0n && fromBal !== undefined && Number(amount) <= fromBal;

  async function doSend() {
    if (!address) return connect();
    const isDep = tab === 'deposit';
    const label = isDep ? 'Deposit' : matured ? 'Withdraw' : 'Withdraw now';
    try {
      setBusy(true); setStatus(`${label}…`);
      let hash: string;
      if (isDep) {
        await ensureAllowance(address as `0x${string}`, ADDR.fxrp, ADDR.vault, amt);
        hash = await send(address as `0x${string}`, ADDR.vault, VAULT_ABI, 'deposit', [amt, address]);
      } else if (matured) {
        hash = await send(address as `0x${string}`, ADDR.vault, VAULT_ABI, 'redeem', [amt, address, address]);
      } else {
        hash = await send(address as `0x${string}`, ADDR.vault, VAULT_ABI, 'withdrawEarly', [amt, 0n]);
      }
      setStatus(`${label} confirmed`);
      setTxs((t) => [{ label, hash }, ...t].slice(0, 8));
      refresh();
    } catch (e: any) {
      setStatus('Error: ' + (e?.shortMessage || e?.message || String(e)));
    } finally {
      setBusy(false);
    }
  }

  const btnLabel = !address ? 'Connect Wallet'
    : !(amt > 0n) ? (tab === 'deposit' ? 'Deposit' : 'Withdraw')
    : fromBal !== undefined && Number(amount) > fromBal ? `Insufficient ${fromSym}`
    : tab === 'deposit' ? 'Deposit & lock rate'
    : matured ? 'Withdraw 1:1' : 'Withdraw now';

  return (
    <>
      {/* Header */}
      <section className="px-6 md:px-24 pt-10 md:pt-14 pb-8">
        <div className="max-w-[1400px] mx-auto relative">
          <div aria-hidden className="pointer-events-none absolute right-0 -top-2 z-20 hidden lg:block">
            <img src="/logos/xrp-coins.svg" alt="" className="h-[300px] w-auto" />
          </div>

          <h1 className="mt-3 text-[34px] md:text-[44px] leading-[1.05] text-fg font-semibold">
            A fixed rate on your XRP
            <br />
            settled on Flare
          </h1>
          <p className="mt-4 max-w-[640px] text-[15px] text-fg-muted">
            Deposit FXRP to lock a fixed rate the day you deposit, and withdraw anytime at market or 1:1
            at maturity. No liquidations, no rate that drifts. Priced by Flare&apos;s FTSO oracle, with a
            confidential market for the variable yield settled in a Flare TEE.
          </p>

          <div className="mt-7 flex flex-wrap gap-8">
            <Stat label="Fixed rate" value={market ? `${market.apr.toFixed(2)}%` : '—'} />
            <Stat label="XRP / USD (FTSO)" value={market?.xrpUsd ? `$${market.xrpUsd.toFixed(4)}` : '—'} />
            <Stat label="Your arFXRP" value={address ? (account ? account.shares.toLocaleString('en-US', { maximumFractionDigits: 2 }) : '—') : '—'} sub={address && account && account.shares > 0 ? 'value at maturity, 1:1' : undefined} />
          </div>
        </div>
      </section>

      {/* Chart + swap + how it works */}
      <section className="vault-panel relative z-10 rounded-t-[20px] px-6 md:px-24 pt-10 md:pt-14 pb-24">
        <div className="max-w-[1400px] mx-auto space-y-5">
          <div className="grid gap-5 lg:grid-cols-[1.3fr_1fr] items-start">
            {/* Fixed-rate growth chart */}
            <FlareChart apr={market?.apr ?? 5.9} now={now || Math.floor(Date.now() / 1000)} maturity={maturity || (now || Math.floor(Date.now() / 1000)) + 90 * DAY} />

            {/* Deposit / Withdraw card */}
            <div className="rounded-2xl bg-[#fdfaf1] p-6 shadow-[0_1px_3px_rgba(20,50,35,0.06),0_10px_30px_rgba(20,50,35,0.09)]">
              <div className="flex items-center gap-1 rounded-full bg-[#254839]/[0.06] p-1 w-fit">
                {(['deposit', 'withdraw'] as const).map((t) => (
                  <button key={t} onClick={() => { setTab(t); setAmount(t === 'deposit' ? '500' : (account?.shares ? String(account.shares) : '')); }}
                    className={t === tab ? 'rounded-full bg-[#254839] px-4 py-1.5 text-[13px] font-medium text-[#fdf8ed] capitalize' : 'rounded-full px-4 py-1.5 text-[13px] text-fg-muted hover:text-fg capitalize'}>
                    {t}
                  </button>
                ))}
              </div>

              {/* FROM */}
              <div className="mt-4 rounded-2xl border border-[#254839]/12 bg-white/60 p-4">
                <div className="flex items-center justify-between text-[12px] text-fg-muted">
                  <span>From</span>
                  <button onClick={() => fromBal !== undefined && setAmount(String(fromBal))} className="hover:text-fg">
                    Balance {fromBal !== undefined ? fromBal.toLocaleString('en-US', { maximumFractionDigits: 2 }) : '—'} · Max
                  </button>
                </div>
                <div className="mt-1.5 flex items-center justify-between">
                  <input inputMode="decimal" placeholder="0.00" value={amount} onChange={(e) => setAmount(e.target.value.replace(/[^0-9.]/g, ''))}
                    className="w-full bg-transparent text-[28px] font-semibold text-fg tabular-nums outline-none placeholder:text-fg-muted/40" />
                  <span className="shrink-0 inline-flex items-center gap-2 rounded-full bg-[#254839]/[0.06] py-1.5 pl-1.5 pr-3.5 text-[14px] font-medium text-fg"><TokenIcon symbol={fromSym} size={22} />{fromSym}</span>
                </div>
              </div>

              {/* arrow */}
              <div className="my-1.5 flex justify-center">
                <span className="flex h-8 w-8 items-center justify-center rounded-full bg-[#254839] text-[#fdf8ed]">↓</span>
              </div>

              {/* TO */}
              <div className="rounded-2xl border border-[#254839]/12 bg-white/60 p-4">
                <div className="flex items-center justify-between text-[12px] text-fg-muted">
                  <span>To (estimated)</span>
                  <span>{tab === 'deposit' ? 'at maturity · 1:1' : matured ? 'full 1:1 value' : 'current market value'}</span>
                </div>
                <div className="mt-1.5 flex items-center justify-between">
                  <span className="text-[28px] font-semibold text-fg tabular-nums">{est}</span>
                  <span className="shrink-0 inline-flex items-center gap-2 rounded-full bg-[#254839]/[0.06] py-1.5 pl-1.5 pr-3.5 text-[14px] font-medium text-fg"><TokenIcon symbol={toSym} size={22} />{toSym}</span>
                </div>
              </div>

              <button onClick={doSend} disabled={busy || (!!address && !canSend)}
                className="mt-4 w-full rounded-full bg-[#254839] px-5 py-3.5 text-[15px] font-medium text-[#fdf8ed] transition-colors hover:bg-[#1F3D31] disabled:opacity-45">
                {busy ? 'Confirming…' : btnLabel}
              </button>
              {status && <div className="mt-3 text-center text-[13px] text-fg-muted">{status}</div>}
              <p className="mt-3 text-center text-[12px] text-fg-muted">
                {tab === 'deposit' ? 'Lock a fixed rate; you receive arFXRP (1 share = 1 FXRP at maturity).' : 'Exit anytime at market, or 1:1 at maturity for the full value.'}
              </p>

              {txs.length > 0 && (
                <div className="mt-4 border-t border-[#254839]/10 pt-3">
                  <div className="text-[11px] uppercase tracking-wider text-fg-muted">Transactions (Coston2)</div>
                  {txs.map((t) => (
                    <div key={t.hash} className="mt-1.5 flex items-center justify-between text-[13px]">
                      <span className="text-fg-muted">{t.label}</span>
                      <a href={explorerTx(t.hash)} target="_blank" rel="noreferrer" className="text-fg underline decoration-[#254839]/30 underline-offset-2 hover:decoration-[#254839]">
                        {t.hash.slice(0, 8)}…{t.hash.slice(-4)} ↗
                      </a>
                    </div>
                  ))}
                </div>
              )}
            </div>
          </div>

          {/* How the fixed rate works */}
          <div>
            <h2 className="text-[13px] uppercase tracking-wider text-fg-muted pt-4 pb-1">How the fixed rate works</h2>
            <p className="text-[13px] text-fg-muted max-w-[680px] mb-4">
              Under the hood your deposit buys a principal token at a discount and redeems it 1:1 at
              maturity. The discount is your fixed rate, funded by a confidential market for the variable
              yield, settled in a Flare Confidential Compute enclave. The pool hides all of it.
            </p>
            <div className="grid gap-4 md:grid-cols-3">
              <Feature title="Deposit FXRP" tag="1:1 at maturity" desc="One transaction into the fixed-rate pool. You receive arFXRP shares, one share redeems for one FXRP at maturity." />
              <Feature title="Rate locked at entry" tag="no liquidations" desc="Your return is set the day you deposit and no later deposit can re-price it. Par-denominated, so it cannot drift." />
              <Feature title="Withdraw anytime" tag="liquid" desc="Exit at the current market value whenever you want, or hold to maturity for the full 1:1 value." />
            </div>
          </div>
        </div>
      </section>
    </>
  );
}

function Stat({ label, value, sub }: { label: string; value: string; sub?: string }) {
  return (
    <div>
      <div className="text-[12px] uppercase tracking-wider text-fg-muted">{label}</div>
      <div className="text-[26px] text-fg font-semibold tabular-nums">{value}</div>
      {sub && <div className="text-[12px] text-fg-muted">{sub}</div>}
    </div>
  );
}

function Feature({ title, tag, desc }: { title: string; tag: string; desc: string }) {
  return (
    <div className="flex flex-col rounded-2xl bg-[#fdfaf1] p-5 shadow-[0_1px_3px_rgba(20,50,35,0.06),0_10px_30px_rgba(20,50,35,0.09)]">
      <div className="flex items-center justify-between">
        <span className="text-[15px] text-fg font-medium">{title}</span>
        <span className="rounded-full bg-[#254839]/[0.08] px-2.5 py-1 text-[11px] text-fg-muted">{tag}</span>
      </div>
      <p className="mt-3 text-[13px] text-fg-muted">{desc}</p>
    </div>
  );
}
