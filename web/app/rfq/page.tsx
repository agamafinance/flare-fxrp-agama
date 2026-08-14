'use client';

import { useState } from 'react';
import Link from 'next/link';
import clsx from 'clsx';
import { ArrowRight, Lock, ShieldCheck, Sparkles, ExternalLink, Check } from 'lucide-react';
import { TokenIcon } from '@/components/icons/TokenIcon';
import { explorerTx } from '@/lib/flare/config';

type Bid = { mm: string; price: number; won: boolean };
type Result = {
  seller: string;
  enclave: { address: string; issuer?: string; hwmodel?: string; dbgstat?: string; imageDigest?: string };
  onchainTrusted: boolean;
  rfqId: number;
  openTx: string;
  reserve: number;
  forgedRejected: boolean;
  bids: Bid[];
  winner: string;
  price: number;
  settleTx: string;
};

const CARD = 'rounded-2xl bg-[#fdfaf1] p-6 shadow-[0_1px_3px_rgba(20,50,35,0.06),0_10px_30px_rgba(20,50,35,0.09)]';
const short = (a?: string) => (a ? `${a.slice(0, 6)}…${a.slice(-4)}` : '—');

export default function FlareRfqPage() {
  const [phase, setPhase] = useState<'idle' | 'running' | 'done' | 'error'>('idle');
  const [res, setRes] = useState<Result | null>(null);
  const [err, setErr] = useState('');

  const run = async () => {
    setPhase('running');
    setErr('');
    try {
      const r = await fetch('/api/tee-demo', { method: 'POST' });
      const j = await r.json();
      if (!r.ok) {
        setErr(j.error || 'settlement failed');
        setPhase('error');
        return;
      }
      setRes(j as Result);
      setPhase('done');
    } catch (e) {
      setErr((e as Error)?.message || 'network error');
      setPhase('error');
    }
  };

  const running = phase === 'running';
  const done = phase === 'done' && !!res;
  const bids: Bid[] = res?.bids ?? [
    { mm: '', price: 0, won: true },
    { mm: '', price: 0, won: false },
  ];

  return (
    <>
      {/* Hero */}
      <section className="px-6 md:px-24 pt-10 md:pt-14 pb-8">
        <div className="max-w-[1400px] mx-auto">
          <span className="inline-flex items-center gap-1.5 rounded-full bg-[#254839]/[0.08] px-3 py-1 text-[12px] font-medium text-[#254839]">
            <Lock className="h-3.5 w-3.5" /> Confidential market · live on Coston2
          </span>
          <h1 className="mt-4 text-[34px] md:text-[44px] leading-[1.05] text-fg font-semibold">Request a quote</h1>
          <p className="mt-4 max-w-[680px] text-[15px] text-fg-muted">
            Your fixed rate is funded by selling the variable yield (YT) in a sealed-bid auction. Market
            makers bid privately inside a Flare Confidential Compute enclave (Intel TDX); it signs only the
            winner, and the contract verifies that signature on chain before settling. Losing and forged
            bids never touch the chain.
          </p>
          <div className="mt-7 flex flex-wrap gap-8">
            <Stat label="Auction size" value="100 YT" />
            <Stat label="Reserve" value="2.00 FXRP" />
            <Stat label="Settlement" value="Flare TEE" />
          </div>
        </div>
      </section>

      {/* Panel */}
      <section className="vault-panel relative z-10 rounded-t-[20px] px-6 md:px-24 pt-10 md:pt-14 pb-24">
        <div className="max-w-[1400px] mx-auto space-y-8">
          <div className="grid gap-5 lg:grid-cols-[1fr_1.3fr] items-start">
            {/* Request card */}
            <div className={CARD}>
              <h2 className="text-[13px] uppercase tracking-wider text-fg-muted">Your request</h2>

              <div className="mt-4 flex items-center justify-between rounded-2xl border border-[#254839]/12 bg-white/60 px-4 py-3 text-[14px]">
                <span className="text-fg-muted">Selling</span>
                <span className="inline-flex items-center gap-2 font-medium text-fg">
                  <TokenIcon symbol="arFXRP" size={20} /> 100 YT (variable yield)
                </span>
              </div>
              <div className="mt-3 flex items-center justify-between rounded-2xl border border-[#254839]/12 bg-white/60 px-4 py-3 text-[14px]">
                <span className="text-fg-muted">Reserve (min premium)</span>
                <span className="font-medium text-fg">2.00 FXRP</span>
              </div>
              <div className="mt-3 flex items-center justify-between rounded-2xl border border-[#254839]/12 bg-white/60 px-4 py-3 text-[14px]">
                <span className="text-fg-muted">Enclave</span>
                <span className="font-medium text-fg">GCP Confidential Space</span>
              </div>

              <button
                onClick={run}
                disabled={running}
                className="mt-4 w-full rounded-full bg-[#254839] px-5 py-3.5 text-[15px] font-medium text-[#fdf8ed] transition-colors hover:bg-[#1F3D31] disabled:opacity-45"
              >
                {running ? 'Running confidential auction…' : done ? 'Run again' : 'Request quotes'}
              </button>
              {phase === 'error' && <p className="mt-3 text-center text-[12px] text-red-600 break-words">{err}</p>}
              <p className="mt-3 text-center text-[12px] text-fg-muted">
                Opens a real RFQ and settles the winner on chain (two Coston2 txs, about 15s).
              </p>
            </div>

            {/* Result */}
            <div className={CARD}>
              <div className="flex items-center justify-between">
                <h2 className="text-[13px] uppercase tracking-wider text-fg-muted">Sealed bids</h2>
                <span className="text-[12px] text-fg-muted">
                  {done ? `settled · RFQ #${res!.rfqId}` : running ? 'sealing…' : '—'}
                </span>
              </div>

              <div className="mt-4 space-y-2.5">
                {bids.map((b, i) => {
                  const win = done && b.won;
                  return (
                    <div
                      key={i}
                      className={clsx(
                        'flex items-center gap-3 rounded-2xl px-4 py-3.5 transition-colors',
                        win ? 'bg-[#254839]' : 'bg-white/60 border border-[#254839]/10'
                      )}
                    >
                      <span
                        className={clsx(
                          'flex h-8 w-8 items-center justify-center rounded-full text-[12px] font-semibold',
                          win ? 'bg-[#fdf8ed]/15 text-[#fdf8ed]' : 'bg-[#254839]/[0.08] text-[#254839]'
                        )}
                      >
                        {`0${i + 1}`}
                      </span>
                      <div className="min-w-0">
                        <div className={clsx('text-[14px] font-medium', win ? 'text-[#fdf8ed]' : 'text-fg')}>
                          {done ? `Market maker ${short(b.mm)}` : `Market maker MM-0${i + 1}`}
                        </div>
                        <div className={clsx('text-[12px]', win ? 'text-[#fdf8ed]/70' : 'text-fg-muted')}>
                          {done ? (b.won ? 'Clears · settled in TEE' : 'Sealed bid') : running ? 'Encrypted' : 'Waiting'}
                        </div>
                      </div>
                      <div className="ml-auto text-right tabular-nums">
                        {done ? (
                          <div className={clsx('text-[17px] font-semibold', win ? 'text-[#fdf8ed]' : 'text-fg')}>
                            {b.price.toFixed(2)} <span className="text-[12px] font-normal opacity-70">FXRP</span>
                          </div>
                        ) : (
                          <Lock className="h-4 w-4 text-fg-muted/50" />
                        )}
                      </div>
                    </div>
                  );
                })}
              </div>

              {done && res ? (
                <div className="mt-4 space-y-3">
                  {res.forgedRejected && (
                    <div className="flex items-center gap-2 text-[13px] text-fg-muted">
                      <Check className="h-4 w-4 text-[#254839]" /> A quote forged for another maker was rejected off-chain.
                    </div>
                  )}
                  <div className="rounded-2xl border border-[#254839]/12 bg-white/60 px-4 py-3">
                    <div className="flex items-center gap-2 text-[13px] text-fg">
                      <ShieldCheck className="h-4 w-4 text-[#254839]" /> Enclave attestation
                      {res.onchainTrusted && (
                        <span className="ml-1 rounded-full bg-[#254839]/[0.08] px-2 py-0.5 text-[11px] text-[#254839]">trusted on-chain</span>
                      )}
                    </div>
                    <dl className="mt-2 grid grid-cols-[auto_1fr] gap-x-3 gap-y-1 text-[12px]">
                      <dt className="text-fg-muted">Key</dt>
                      <dd className="font-mono text-fg break-all">{short(res.enclave.address)}</dd>
                      <dt className="text-fg-muted">Platform</dt>
                      <dd className="text-fg">
                        {res.enclave.hwmodel || 'Intel TDX'} · {res.enclave.dbgstat || 'disabled-since-boot'}
                      </dd>
                      <dt className="text-fg-muted">Image</dt>
                      <dd className="font-mono text-fg break-all">{(res.enclave.imageDigest || '').slice(0, 24) || '—'}…</dd>
                    </dl>
                    <div className="mt-2 flex flex-wrap gap-3 text-[12px]">
                      <a href={explorerTx(res.openTx)} target="_blank" rel="noreferrer" className="inline-flex items-center gap-1 text-[#254839] underline-offset-2 hover:underline">
                        open RFQ <ExternalLink className="h-3 w-3" />
                      </a>
                      <a href={explorerTx(res.settleTx)} target="_blank" rel="noreferrer" className="inline-flex items-center gap-1 text-[#254839] underline-offset-2 hover:underline">
                        settle tx <ExternalLink className="h-3 w-3" />
                      </a>
                    </div>
                    <Link href="/" className="group mt-3 inline-flex items-center gap-1.5 text-[13px] font-medium text-[#254839]">
                      Lock your fixed rate on Earn
                      <ArrowRight className="h-4 w-4 transition-transform group-hover:translate-x-0.5" />
                    </Link>
                  </div>
                </div>
              ) : (
                <p className="mt-4 text-center text-[13px] text-fg-muted">
                  {running
                    ? 'Two sealed bids to the enclave, winner signed in the TEE, settled on chain.'
                    : 'Submit a request to open the auction.'}
                </p>
              )}
            </div>
          </div>

          {/* How it works */}
          <div>
            <h2 className="text-[13px] uppercase tracking-wider text-fg-muted pb-3">How the auction works</h2>
            <div className="grid gap-4 md:grid-cols-3">
              <Feature icon={<Lock className="h-4 w-4" />} title="Sealed bids" desc="Market makers submit encrypted bids for your YT. No bidder sees another's price, and a quote forged for another maker is rejected." />
              <Feature icon={<ShieldCheck className="h-4 w-4" />} title="Settled in a TEE" desc="A Flare Confidential Space enclave (Intel TDX, non-debuggable) opens the bids, clears the auction and signs only the winner. Its key is attested on chain." />
              <Feature icon={<Sparkles className="h-4 w-4" />} title="Best premium to you" desc="The highest bid clears and settles atomically on Coston2. The premium funds your fixed rate; the spread stays with you." />
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
