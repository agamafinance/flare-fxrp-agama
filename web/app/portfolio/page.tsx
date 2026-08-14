'use client';

import Link from 'next/link';
import { TokenIcon } from '@/components/icons/TokenIcon';
import { useFlareWallet } from '@/lib/flare/WalletProvider';
import { useFlareData } from '@/lib/flare/useFlare';
import { explorerAddr } from '@/lib/flare/config';

const usd = (n: number) => `$${(Math.floor(n * 100) / 100).toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
const fmt = (n: number) => n.toLocaleString('en-US', { maximumFractionDigits: 2 });

export default function FlarePortfolioPage() {
  const { address, connect } = useFlareWallet();
  const { market, account } = useFlareData(address as `0x${string}` | undefined);

  const px = market?.xrpUsd ?? 0;
  const fxrpN = account?.fxrp ?? 0;
  const sharesN = account?.shares ?? 0;
  const netWorth = (fxrpN + sharesN) * px;

  return (
    <section className="px-6 md:px-24 pt-10 md:pt-14 pb-24">
      <div className="max-w-[1400px] mx-auto">
        <h1 className="mt-2 text-[34px] text-fg font-semibold">Portfolio</h1>

        {!address ? (
          <div className="mt-8 rounded-2xl bg-[#fdfaf1] p-8 text-center shadow-[0_1px_3px_rgba(20,50,35,0.06),0_10px_30px_rgba(20,50,35,0.09)]">
            <p className="text-[15px] text-fg-muted">Connect your wallet to view your positions.</p>
            <button type="button" onClick={connect} className="mt-4 h-11 px-6 rounded-full bg-[#254839] text-[#fdf8ed] text-[14px] font-medium hover:bg-[#1F3D31]">
              Connect Wallet
            </button>
          </div>
        ) : (
          <>
            <div className="mt-6 rounded-2xl bg-[#fdfaf1] p-6 shadow-[0_1px_3px_rgba(20,50,35,0.06),0_10px_30px_rgba(20,50,35,0.09)]">
              <div className="text-[12px] uppercase tracking-wider text-fg-muted">Net worth</div>
              <div className="text-[34px] text-fg font-semibold tabular-nums">{usd(netWorth)}</div>
              <a href={explorerAddr(address)} target="_blank" rel="noreferrer" className="mt-1 block text-[12px] text-fg-muted break-all underline-offset-2 hover:text-fg hover:underline">
                {address}
              </a>
            </div>

            <div className="mt-4 space-y-3">
              <Position symbol="FXRP" name="Flare XRP" amount={fmt(fxrpN)} sub={px ? usd(fxrpN * px) : undefined} href="/faucet" />
              <Position symbol="arFXRP" name="Agama Fixed-Rate FXRP" amount={fmt(sharesN)} sub={px ? `${usd(sharesN * px)} · at maturity` : undefined} href="/" />
            </div>
          </>
        )}
      </div>
    </section>
  );
}

function Position({ symbol, name, amount, sub, href }: { symbol: string; name: string; amount: string; sub?: string; href: string }) {
  return (
    <Link href={href} className="flex items-center gap-4 rounded-2xl bg-[#fdfaf1] px-5 py-4 shadow-[0_1px_3px_rgba(20,50,35,0.06)]">
      <TokenIcon symbol={symbol} size={36} />
      <div>
        <div className="text-[15px] text-fg font-medium">{symbol}</div>
        <div className="text-[13px] text-fg-muted">{name}</div>
      </div>
      <div className="ml-auto text-right">
        <div className="text-[16px] text-fg font-semibold tabular-nums">{amount}</div>
        {sub && <div className="text-[12px] text-fg-muted">{sub}</div>}
      </div>
    </Link>
  );
}
