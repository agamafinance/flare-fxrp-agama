'use client';

import { useState } from 'react';
import clsx from 'clsx';
import { Lock, ShieldCheck, Sparkles, ExternalLink, Check, Loader2, X } from 'lucide-react';
import { TokenIcon } from '@/components/icons/TokenIcon';
import { ADDR, explorerTx } from '@/lib/flare/config';
import { ERC20_ABI, SPLITTER_ABI, RFQ_ABI } from '@/lib/flare/abis';
import { pub, send, ensureAllowance } from '@/lib/flare/useFlare';
import { useFlareWallet } from '@/lib/flare/WalletProvider';

type Bid = { mm: string; price: number; won: boolean };
type Result = {
  mode: 'demo' | 'user';
  seller: string;
  enclave: { address: string; issuer?: string; hwmodel?: string; dbgstat?: string; imageDigest?: string };
  onchainTrusted: boolean;
  rfqId: number;
  openTx: string | null;
  reserve: number;
  forgedRejected: boolean;
  bids: Bid[];
  winner: string;
  price: number;
  settleTx: string;
};
type StepStatus = 'pending' | 'active' | 'done' | 'error';
type Step = { key: string; label: string; hint?: string; status: StepStatus; tx?: string };

const CARD = 'rounded-2xl bg-[#fdfaf1] p-6 shadow-[0_1px_3px_rgba(20,50,35,0.06),0_10px_30px_rgba(20,50,35,0.09)]';
const AMT = 100_000000n; // 100 YT / 100 FXRP (6 decimals)
const short = (a?: string) => (a ? `${a.slice(0, 6)}…${a.slice(-4)}` : '—');

const FRESH: Step[] = [
  { key: 'split', label: 'Split 100 FXRP into principal + yield', hint: 'you sign', status: 'active' },
  { key: 'open', label: 'Open your sealed-bid RFQ (escrow the YT)', hint: 'you sign', status: 'pending' },
  { key: 'settle', label: 'Market makers bid · enclave signs · settled on chain', hint: '~15s, no signature', status: 'pending' },
];

export default function FlareRfqPage() {
  const { address, connect } = useFlareWallet();
  const [phase, setPhase] = useState<'idle' | 'running' | 'done' | 'error'>('idle');
  const [res, setRes] = useState<Result | null>(null);
  const [err, setErr] = useState('');
  const [steps, setSteps] = useState<Step[]>([]);

  const reset = () => { setPhase('idle'); setRes(null); setErr(''); setSteps([]); };

  // seller flow: the connected wallet splits FXRP -> YT, opens its own RFQ, then the backend runs the
  // market-maker bids + enclave settlement, and the winning premium lands in the user's wallet.
  const requestQuotes = async () => {
    if (!address) { await connect(); return; }
    const a = address as `0x${string}`;
    setPhase('running'); setErr(''); setRes(null);
    const s = FRESH.map((x) => ({ ...x }));
    setSteps(s);
    const upd = (i: number, patch: Partial<Step>) => setSteps((prev) => prev.map((x, idx) => (idx === i ? { ...x, ...patch } : x)));
    const failAt = (i: number, msg: string) => { upd(i, { status: 'error' }); setErr(msg); setPhase('error'); };

    try {
      const bal = (await pub.readContract({ address: ADDR.fxrp, abi: ERC20_ABI, functionName: 'balanceOf', args: [a] })) as bigint;
      if (bal < AMT) return failAt(0, 'You need at least 100 FXRP. Mint some on the Faucet first.');

      // 1. split FXRP -> PT + YT
      await ensureAllowance(a, ADDR.fxrp, ADDR.splitter, AMT);
      const splitTx = await send(a, ADDR.splitter, SPLITTER_ABI, 'split', [AMT]);
      upd(0, { status: 'done', tx: splitTx }); upd(1, { status: 'active' });

      // 2. open the RFQ, escrowing the YT
      await ensureAllowance(a, ADDR.yt, ADDR.rfq, AMT);
      const openTx = await send(a, ADDR.rfq, RFQ_ABI, 'openRfq', [AMT, 2_000000n]);
      const rfqId = ((await pub.readContract({ address: ADDR.rfq, abi: RFQ_ABI, functionName: 'nextId' })) as bigint) - 1n;
      upd(1, { status: 'done', tx: openTx }); upd(2, { status: 'active' });

      // 3. backend: sealed bids + enclave settlement for YOUR rfqId
      const r = await fetch('/api/tee-demo', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ rfqId: Number(rfqId) }) });
      const j = await r.json();
      if (!r.ok) return failAt(2, j.error || 'settlement failed');
      upd(2, { status: 'done', tx: j.settleTx });
      setRes(j as Result); setPhase('done');
    } catch (e) {
      const x = e as { shortMessage?: string; message?: string };
      setSteps((prev) => prev.map((st) => (st.status === 'active' ? { ...st, status: 'error' } : st)));
      setErr(x?.shortMessage || x?.message || 'failed'); setPhase('error');
    }
  };

  const running = phase === 'running';
  const done = phase === 'done' && !!res;
  const started = steps.length > 0;
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
            makers bid privately inside a Flare Confidential Compute enclave (AMD SEV); it signs only the
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

              {!started ? (
                <>
                  {!address ? (
                    <button onClick={connect} className="mt-4 w-full rounded-full bg-[#254839] px-5 py-3.5 text-[15px] font-medium text-[#fdf8ed] transition-colors hover:bg-[#1F3D31]">
                      Connect wallet to request quotes
                    </button>
                  ) : (
                    <button onClick={requestQuotes} className="mt-4 w-full rounded-full bg-[#254839] px-5 py-3.5 text-[15px] font-medium text-[#fdf8ed] transition-colors hover:bg-[#1F3D31]">
                      Request quotes
                    </button>
                  )}
                  <p className="mt-3 text-center text-[12px] text-fg-muted">
                    Request quotes splits your FXRP into principal + yield, opens a sealed-bid RFQ, and pays
                    you the winning premium. About 3 signatures.
                  </p>
                </>
              ) : (
                <>
                  {/* live stepper */}
                  <ol className="mt-5 space-y-3.5">
                    {steps.map((s) => (
                      <li key={s.key} className="flex items-start gap-3">
                        <StepIcon status={s.status} n={steps.indexOf(s) + 1} />
                        <div className="min-w-0 flex-1 pt-0.5">
                          <div className={clsx('text-[13.5px] leading-snug', s.status === 'pending' ? 'text-fg-muted' : 'text-fg font-medium')}>
                            {s.label}
                          </div>
                          <div className="mt-0.5 flex items-center gap-2 text-[12px]">
                            {s.status === 'done' && s.tx ? (
                              <a href={explorerTx(s.tx)} target="_blank" rel="noreferrer" className="inline-flex items-center gap-1 text-[#254839] underline-offset-2 hover:underline">
                                {short(s.tx)} <ExternalLink className="h-3 w-3" />
                              </a>
                            ) : s.status === 'active' ? (
                              <span className="text-fg-muted">{s.hint || 'in progress…'}</span>
                            ) : s.status === 'error' ? (
                              <span className="text-red-600">failed</span>
                            ) : (
                              <span className="text-fg-muted/70">{s.hint}</span>
                            )}
                          </div>
                        </div>
                      </li>
                    ))}
                  </ol>

                  {phase === 'error' && <p className="mt-4 text-center text-[12px] text-red-600 break-words">{err}</p>}

                  {(done || phase === 'error') && (
                    <button onClick={reset} className="mt-4 w-full rounded-full bg-[#254839] px-5 py-3.5 text-[15px] font-medium text-[#fdf8ed] transition-colors hover:bg-[#1F3D31]">
                      {done ? 'Request quotes again' : 'Try again'}
                    </button>
                  )}
                </>
              )}
            </div>

            {/* Result */}
            <div className={CARD}>
              <div className="flex items-center justify-between">
                <h2 className="text-[13px] uppercase tracking-wider text-fg-muted">Sealed bids</h2>
                <span className="text-[12px] text-fg-muted">
                  {done ? `settled · RFQ #${res!.rfqId} · you` : running ? 'sealing…' : '—'}
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
                        win ? 'bg-[#254839]' : 'bg-white/60 border border-[#254839]/10',
                        running && 'animate-pulse'
                      )}
                    >
                      <span className={clsx('flex h-8 w-8 items-center justify-center rounded-full text-[12px] font-semibold', win ? 'bg-[#fdf8ed]/15 text-[#fdf8ed]' : 'bg-[#254839]/[0.08] text-[#254839]')}>
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
                  <div className="flex items-center gap-2 rounded-2xl bg-[#254839]/[0.06] px-4 py-2.5 text-[13px] text-fg">
                    <Check className="h-4 w-4 text-[#254839]" /> {res.price.toFixed(2)} FXRP premium paid to your wallet ({short(res.seller)}).
                  </div>
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
                      <dd className="text-fg">{res.enclave.hwmodel || 'GCP_AMD_SEV'} · {res.enclave.dbgstat || 'disabled-since-boot'}</dd>
                      <dt className="text-fg-muted">Image</dt>
                      <dd className="font-mono text-fg break-all">{(res.enclave.imageDigest || '').slice(0, 24) || '—'}…</dd>
                    </dl>
                    <div className="mt-2 flex flex-wrap gap-3 text-[12px]">
                      {res.openTx && (
                        <a href={explorerTx(res.openTx)} target="_blank" rel="noreferrer" className="inline-flex items-center gap-1 text-[#254839] underline-offset-2 hover:underline">open RFQ <ExternalLink className="h-3 w-3" /></a>
                      )}
                      <a href={explorerTx(res.settleTx)} target="_blank" rel="noreferrer" className="inline-flex items-center gap-1 text-[#254839] underline-offset-2 hover:underline">settle tx <ExternalLink className="h-3 w-3" /></a>
                    </div>
                  </div>
                </div>
              ) : (
                <p className="mt-4 text-center text-[13px] text-fg-muted">
                  {running ? 'Sealed bids to the enclave, winner signed in the TEE, settled on chain.' : 'Request quotes to open your auction.'}
                </p>
              )}
            </div>
          </div>

          {/* How it works */}
          <div>
            <h2 className="text-[13px] uppercase tracking-wider text-fg-muted pb-3">How the auction works</h2>
            <div className="grid gap-4 md:grid-cols-3">
              <Feature icon={<Lock className="h-4 w-4" />} title="Sealed bids" desc="Market makers submit encrypted bids for your YT. No bidder sees another's price, and a quote forged for another maker is rejected." />
              <Feature icon={<ShieldCheck className="h-4 w-4" />} title="Settled in a TEE" desc="A Flare Confidential Space enclave (AMD SEV, non-debuggable), registered as a Flare Compute Extension, opens the bids, clears the auction and signs only the winner. settle() verifies the signer is an active machine in Flare's registry." />
              <Feature icon={<Sparkles className="h-4 w-4" />} title="Best premium to you" desc="The highest bid clears and settles atomically on Coston2. The premium funds your fixed rate; the spread stays with you." />
            </div>
          </div>
        </div>
      </section>
    </>
  );
}

function StepIcon({ status, n }: { status: StepStatus; n: number }) {
  if (status === 'done')
    return <span className="mt-0.5 flex h-6 w-6 shrink-0 items-center justify-center rounded-full bg-[#254839] text-[#fdf8ed]"><Check className="h-3.5 w-3.5" /></span>;
  if (status === 'active')
    return <span className="mt-0.5 flex h-6 w-6 shrink-0 items-center justify-center rounded-full bg-[#254839]/[0.10] text-[#254839]"><Loader2 className="h-3.5 w-3.5 animate-spin" /></span>;
  if (status === 'error')
    return <span className="mt-0.5 flex h-6 w-6 shrink-0 items-center justify-center rounded-full bg-red-100 text-red-600"><X className="h-3.5 w-3.5" /></span>;
  return <span className="mt-0.5 flex h-6 w-6 shrink-0 items-center justify-center rounded-full bg-[#254839]/[0.06] text-[12px] font-semibold text-fg-muted">{n}</span>;
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
