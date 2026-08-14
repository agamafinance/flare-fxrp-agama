'use client';

import { useState } from 'react';
import Link from 'next/link';
import { ArrowRight, Check, Copy, ExternalLink } from 'lucide-react';
import { useFlareWallet } from '@/lib/flare/WalletProvider';
import { useFlareData, send } from '@/lib/flare/useFlare';
import { ADDR, toBaseUnits } from '@/lib/flare/config';
import { ERC20_ABI } from '@/lib/flare/abis';

const GAS_FAUCET = 'https://faucet.flare.network/coston2';
const fmt = (n: number) => n.toLocaleString('en-US', { maximumFractionDigits: 2 });

export default function FlareFaucetPage() {
  const { address, connect } = useFlareWallet();
  const { account, refresh } = useFlareData(address as `0x${string}` | undefined);
  const [copied, setCopied] = useState(false);
  const [busy, setBusy] = useState(false);

  const copyAddress = async () => {
    if (!address) return;
    await navigator.clipboard.writeText(address);
    setCopied(true);
    setTimeout(() => setCopied(false), 1500);
  };
  const mint = async () => {
    if (!address) return;
    setBusy(true);
    try { await send(address as `0x${string}`, ADDR.fxrp, ERC20_ABI, 'mint', [address, toBaseUnits('1000')]); refresh(); }
    finally { setBusy(false); }
  };

  return (
    <>
      {/* Hero */}
      <section className="px-6 md:px-24 pt-10 md:pt-14 pb-8">
        <div className="max-w-[1400px] mx-auto relative">
          <div aria-hidden className="pointer-events-none absolute right-4 top-2 z-20 hidden lg:block">
            <img src="/logos/fxrp.svg" alt="" className="h-[170px] w-[170px] drop-shadow-[0_18px_30px_rgba(20,50,35,0.25)]" />
          </div>

          <h1 className="mt-3 text-[34px] md:text-[44px] leading-[1.05] text-fg font-semibold">Get FXRP</h1>
          <p className="mt-4 max-w-[640px] text-[15px] text-fg-muted">
            Mint demo FXRP on Flare Coston2. A few clicks and you are funded, ready for the fixed-rate pool.
          </p>

          <div className="mt-7 flex flex-wrap gap-8">
            <Stat label="Network" value="Flare Coston2" />
            <Stat label="Asset" value="FXRP" />
            <Stat label="Your FXRP" value={account ? fmt(account.fxrp) : '—'} />
          </div>
        </div>
      </section>

      {/* Steps */}
      <section className="vault-panel relative z-10 rounded-t-[20px] px-6 md:px-24 pt-10 md:pt-14 pb-24">
        <div className="max-w-[1400px] mx-auto space-y-3">
          <h2 className="text-[13px] uppercase tracking-wider text-fg-muted mb-2">Get funded</h2>

          <StepRow logo="/logos/fxrp.svg" title="Mint FXRP" blurb="1,000 FXRP from the Agama faucet, mint as often as you like.">
            {!address ? (
              <button type="button" onClick={connect} className="h-11 px-6 rounded-full bg-[#254839] text-[#fdf8ed] text-[14px] font-medium hover:bg-[#1F3D31] whitespace-nowrap">
                Connect
              </button>
            ) : (
              <button type="button" onClick={mint} disabled={busy} className="h-11 px-6 rounded-full bg-[#254839] text-[#fdf8ed] text-[14px] font-medium hover:bg-[#1F3D31] disabled:opacity-45 whitespace-nowrap">
                {busy ? 'Confirming…' : 'Mint 1,000 FXRP'}
              </button>
            )}
          </StepRow>

          <p className="pt-2 text-[12px] text-fg-muted">
            Need C2FLR for gas? Grab some from{' '}
            <a href={GAS_FAUCET} target="_blank" rel="noreferrer" className="underline hover:text-fg inline-flex items-center gap-1">
              faucet.flare.network <ExternalLink className="h-3 w-3" />
            </a>
            <button type="button" onClick={copyAddress} disabled={!address} className="ml-3 inline-flex items-center gap-1.5 rounded-full bg-[#254839]/[0.08] px-3 py-1 text-[12px] text-[#254839] hover:bg-[#254839]/[0.16] disabled:opacity-40">
              {copied ? <Check className="h-3.5 w-3.5" /> : <Copy className="h-3.5 w-3.5" />}
              {copied ? 'Copied!' : 'Copy address'}
            </button>
          </p>

          {/* Next step */}
          <Link href="/" className="group mt-6 flex items-center gap-4 rounded-2xl bg-[#254839] px-5 py-4">
            <img src="/logos/arfxrp.svg" alt="" className="h-10 w-10" />
            <div>
              <div className="text-[15px] font-medium text-[#fdf8ed]">Funded? Lock a fixed rate</div>
              <div className="text-[13px] text-[#fdf8ed]/70">Deposit FXRP into the fixed-rate pool and receive arFXRP</div>
            </div>
            <ArrowRight className="ml-auto h-5 w-5 text-[#fdf8ed]/80 transition-transform group-hover:translate-x-0.5" />
          </Link>
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

function StepRow({ title, blurb, children, logo }: { title: string; blurb: string; children: React.ReactNode; logo: string }) {
  return (
    <div className="flex flex-col gap-4 rounded-2xl bg-[#fdfaf1] px-5 py-4 shadow-[0_1px_3px_rgba(20,50,35,0.06),0_10px_30px_rgba(20,50,35,0.09)] md:flex-row md:items-center">
      <img src={logo} alt="" className="h-10 w-10 shrink-0 rounded-full" />
      <div className="min-w-0">
        <div className="text-[15px] text-fg font-medium">{title}</div>
        <div className="text-[13px] text-fg-muted break-all">{blurb}</div>
      </div>
      <div className="md:ml-auto shrink-0">{children}</div>
    </div>
  );
}
