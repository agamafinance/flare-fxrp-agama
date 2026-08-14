'use client';

import { useMemo, useState } from 'react';
import Link from 'next/link';
import clsx from 'clsx';
import { ArrowRight, Lock, ShieldCheck, Sparkles } from 'lucide-react';
import { TokenIcon } from '@/components/icons/TokenIcon';
import { useFlareData } from '@/lib/flare/useFlare';
import { useFlareWallet } from '@/lib/flare/WalletProvider';

const TENOR_DAYS = 90;
const fmt = (n: number, d = 2) => n.toLocaleString('en-US', { maximumFractionDigits: d, minimumFractionDigits: d });

// deterministic pseudo-attestation so the demo feels live without a live enclave call
function attest(seed: string) {
  let h = 0x811c9dc5;
  let out = '';
  for (let i = 0; i < seed.length; i++) { h ^= seed.charCodeAt(i); h = Math.imul(h, 0x01000193); }
  for (let i = 0; i < 8; i++) { h = Math.imul(h ^ (h >>> 15), 0x2c1b3c6d); out += (h >>> 0).toString(16).padStart(8, '0'); }
  return out.slice(0, 40);
}

export default function FlareRfqPage() {
  const { address } = useFlareWallet();
  const { market } = useFlareData(address as `0x${string}` | undefined);
  const [notional, setNotional] = useState('500');
  const [phase, setPhase] = useState<'idle' | 'sealing' | 'revealed'>('idle');

  const apr = market?.apr ?? 5.9;
  const n = Number(notional) > 0 ? Number(notional) : 0;
  const factor = Math.pow(1 + apr / 100, TENOR_DAYS / 365);
  const atMaturity = n * factor;

  // three sealed bids for the variable yield; the highest fixed rate offered clears
  const quotes = useMemo(
    () => [
      { id: 'MM-01', rate: apr, best: true },
      { id: 'MM-02', rate: apr - 0.34, best: false },
      { id: 'MM-03', rate: apr - 0.61, best: false },
    ],
    [apr]
  );

  const request = () => {
    setPhase('sealing');
    setTimeout(() => setPhase('revealed'), 900);
  };

  const att = attest(`${notional}:${apr.toFixed(2)}`);

  return (
    <>
      {/* Hero */}
      <section className="px-6 md:px-24 pt-10 md:pt-14 pb-8">
        <div className="max-w-[1400px] mx-auto">
          <span className="inline-flex items-center gap-1.5 rounded-full bg-[#254839]/[0.08] px-3 py-1 text-[12px] font-medium text-[#254839]">
            <Lock className="h-3.5 w-3.5" /> Confidential market
          </span>
          <h1 className="mt-4 text-[34px] md:text-[44px] leading-[1.05] text-fg font-semibold">Request a quote</h1>
          <p className="mt-4 max-w-[660px] text-[15px] text-fg-muted">
            Your fixed rate is set by a sealed-bid auction. Yield buyers bid for the variable yield on your
            FXRP inside a Flare TEE, and nobody sees the others&apos; bids. The best bid clears and becomes the
            rate you lock on Earn.
          </p>
          <div className="mt-7 flex flex-wrap gap-8">
            <Stat label="Clearing rate" value={`${apr.toFixed(2)}%`} />
            <Stat label="Tenor" value={`${TENOR_DAYS} days`} />
            <Stat label="Settlement" value="Flare TEE" />
          </div>
        </div>
      </section>

      {/* Panel */}
      <section className="vault-panel relative z-10 rounded-t-[20px] px-6 md:px-24 pt-10 md:pt-14 pb-24">
        <div className="max-w-[1400px] mx-auto space-y-8">
          <div className="grid gap-5 lg:grid-cols-[1fr_1.3fr] items-start">
            {/* Request card */}
            <div className="rounded-2xl bg-[#fdfaf1] p-6 shadow-[0_1px_3px_rgba(20,50,35,0.06),0_10px_30px_rgba(20,50,35,0.09)]">
              <h2 className="text-[13px] uppercase tracking-wider text-fg-muted">Your request</h2>

              <div className="mt-4 rounded-2xl border border-[#254839]/12 bg-white/60 p-4">
                <div className="flex items-center justify-between text-[12px] text-fg-muted"><span>Notional</span><span>FXRP</span></div>
                <div className="mt-1.5 flex items-center justify-between">
                  <input inputMode="decimal" placeholder="0.00" value={notional}
                    onChange={(e) => { setNotional(e.target.value.replace(/[^0-9.]/g, '')); setPhase('idle'); }}
                    className="w-full bg-transparent text-[28px] font-semibold text-fg tabular-nums outline-none placeholder:text-fg-muted/40" />
                  <span className="shrink-0 inline-flex items-center gap-2 rounded-full bg-[#254839]/[0.06] py-1.5 pl-1.5 pr-3.5 text-[14px] font-medium text-fg">
                    <TokenIcon symbol="FXRP" size={22} /> FXRP
                  </span>
                </div>
              </div>

              <div className="mt-3 flex items-center justify-between rounded-2xl border border-[#254839]/12 bg-white/60 px-4 py-3 text-[14px]">
                <span className="text-fg-muted">Tenor</span>
                <span className="font-medium text-fg">{TENOR_DAYS} days · fixed</span>
              </div>

              <div className="mt-3 flex items-center justify-between rounded-2xl border border-[#254839]/12 bg-white/60 px-4 py-3 text-[14px]">
                <span className="text-fg-muted">Value at maturity</span>
                <span className="font-medium text-fg tabular-nums">{n > 0 ? `${fmt(atMaturity)} FXRP` : '—'}</span>
              </div>

              <button onClick={request} disabled={!(n > 0) || phase === 'sealing'}
                className="mt-4 w-full rounded-full bg-[#254839] px-5 py-3.5 text-[15px] font-medium text-[#fdf8ed] transition-colors hover:bg-[#1F3D31] disabled:opacity-45">
                {phase === 'sealing' ? 'Sealing bids…' : 'Request quotes'}
              </button>
              <p className="mt-3 text-center text-[12px] text-fg-muted">Bids are encrypted to the enclave. Only the clearing rate is revealed.</p>
            </div>

            {/* Quotes */}
            <div className="rounded-2xl bg-[#fdfaf1] p-6 shadow-[0_1px_3px_rgba(20,50,35,0.06),0_10px_30px_rgba(20,50,35,0.09)]">
              <div className="flex items-center justify-between">
                <h2 className="text-[13px] uppercase tracking-wider text-fg-muted">Sealed bids</h2>
                <span className="text-[12px] text-fg-muted">{phase === 'revealed' ? '3 responded' : '—'}</span>
              </div>

              <div className="mt-4 space-y-2.5">
                {quotes.map((q) => {
                  const win = phase === 'revealed' && q.best;
                  return (
                    <div key={q.id}
                      className={clsx('flex items-center gap-3 rounded-2xl px-4 py-3.5 transition-colors',
                        win ? 'bg-[#254839]' : 'bg-white/60 border border-[#254839]/10')}>
                      <span className={clsx('flex h-8 w-8 items-center justify-center rounded-full text-[12px] font-semibold',
                        win ? 'bg-[#fdf8ed]/15 text-[#fdf8ed]' : 'bg-[#254839]/[0.08] text-[#254839]')}>
                        {q.id.slice(-2)}
                      </span>
                      <div className="min-w-0">
                        <div className={clsx('text-[14px] font-medium', win ? 'text-[#fdf8ed]' : 'text-fg')}>Yield buyer {q.id}</div>
                        <div className={clsx('text-[12px]', win ? 'text-[#fdf8ed]/70' : 'text-fg-muted')}>
                          {phase === 'revealed' ? (q.best ? 'Clears · settled in TEE' : 'Sealed bid') : 'Encrypted'}
                        </div>
                      </div>
                      <div className="ml-auto text-right tabular-nums">
                        {phase === 'revealed'
                          ? <div className={clsx('text-[17px] font-semibold', win ? 'text-[#fdf8ed]' : 'text-fg')}>{q.rate.toFixed(2)}%</div>
                          : <Lock className="h-4 w-4 text-fg-muted/50" />}
                      </div>
                    </div>
                  );
                })}
              </div>

              {phase === 'revealed' ? (
                <div className="mt-4 rounded-2xl border border-[#254839]/12 bg-white/60 px-4 py-3">
                  <div className="flex items-center gap-2 text-[13px] text-fg">
                    <ShieldCheck className="h-4 w-4 text-[#254839]" /> Enclave attestation
                  </div>
                  <div className="mt-1 break-all font-mono text-[11px] text-fg-muted">0x{att}</div>
                  <Link href="/" className="group mt-3 inline-flex items-center gap-1.5 text-[13px] font-medium text-[#254839]">
                    Lock {apr.toFixed(2)}% on Earn
                    <ArrowRight className="h-4 w-4 transition-transform group-hover:translate-x-0.5" />
                  </Link>
                </div>
              ) : (
                <p className="mt-4 text-center text-[13px] text-fg-muted">Submit a request to open the auction.</p>
              )}
            </div>
          </div>

          {/* How it works */}
          <div>
            <h2 className="text-[13px] uppercase tracking-wider text-fg-muted pb-3">How the auction works</h2>
            <div className="grid gap-4 md:grid-cols-3">
              <Feature icon={<Lock className="h-4 w-4" />} title="Sealed bids" desc="Yield buyers submit encrypted bids for your variable yield. No bidder sees another's price, so nobody can shade the rate." />
              <Feature icon={<ShieldCheck className="h-4 w-4" />} title="Settled in a TEE" desc="A Flare Confidential Compute enclave opens the bids, clears the auction and attests to the result on-chain." />
              <Feature icon={<Sparkles className="h-4 w-4" />} title="Best rate to you" desc="The highest bid clears and becomes the fixed rate you lock on Earn. The spread stays with you, not a market maker." />
            </div>
          </div>
        </div>
      </section>
    </>
  );
}

function Stat({ label, value }: { label: string; value: string }) {
  return (
    <div>
      <div className="text-[12px] uppercase tracking-wider text-fg-muted">{label}</div>
      <div className="text-[26px] text-fg font-semibold tabular-nums">{value}</div>
    </div>
  );
}

function Feature({ icon, title, desc }: { icon: React.ReactNode; title: string; desc: string }) {
  return (
    <div className="flex flex-col rounded-2xl bg-[#fdfaf1] p-5 shadow-[0_1px_3px_rgba(20,50,35,0.06),0_10px_30px_rgba(20,50,35,0.09)]">
      <span className="flex h-8 w-8 items-center justify-center rounded-full bg-[#254839]/[0.08] text-[#254839]">{icon}</span>
      <div className="mt-3 text-[15px] text-fg font-medium">{title}</div>
      <p className="mt-1.5 text-[13px] text-fg-muted">{desc}</p>
    </div>
  );
}
