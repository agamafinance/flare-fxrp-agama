'use client';

import Link from 'next/link';
import { usePathname } from 'next/navigation';
import clsx from 'clsx';
import { FlareConnectPill } from './FlareConnectPill';

const NAV = [
  { href: '/portfolio', label: 'Portfolio' },
  { href: '/', label: 'Earn' },
  { href: '/rfq', label: 'RFQ' },
  { href: '/faucet', label: 'Faucet' },
];

export function FlareNav() {
  const pathname = usePathname() || '/';
  const active = (href: string) =>
    href === '/' ? pathname === '/' : pathname === href || pathname.startsWith(href + '/');

  const items = (mobile: boolean) =>
    NAV.map((item) => (
      <Link
        key={item.href}
        href={item.href}
        className={clsx(
          'flex items-center rounded-full text-white transition-colors',
          mobile ? 'h-7 flex-1 justify-center text-[13px]' : 'h-10 px-4 md:px-5 text-[14px]',
          active(item.href) ? 'pill-active' : 'hover:bg-white/10'
        )}
      >
        {item.label}
      </Link>
    ));

  return (
    <>
      <header className="relative z-50 bg-[#1F3D31] md:bg-transparent px-4 md:pl-6 md:pr-[24px] py-3 md:py-[11px]">
        <div className="flex items-center justify-between gap-3">
          <Link href="/" className="flex items-center group shrink-0">
            <img src="/agama-logo-beige.svg" alt="Agama" className="h-[32.8px] w-auto" />
          </Link>

          <nav className="hidden md:flex pill-bar items-center gap-1 rounded-full h-[47px] -mb-[3px] px-[3.5px] mr-auto ml-10">
            {items(false)}
          </nav>

          <div className="flex items-center gap-2 shrink-0">
            <span
              className="pill-outline flex items-center gap-1.5 rounded-full h-10 pl-[6px] pr-3 text-white"
              title="Flare Coston2 (testnet)"
            >
              <span className="flex h-[20px] w-[20px] items-center justify-center rounded-full overflow-hidden">
                <img src="/flare-logo.jpeg" alt="Flare" className="h-[20px] w-[20px] object-cover" />
              </span>
              <span className="hidden sm:inline text-[13px]">Coston2</span>
            </span>
            <FlareConnectPill />
          </div>
        </div>
      </header>

      <div className="md:hidden bg-[#fdf8ed] px-2 pt-3 pb-3 border-b border-[#254839]/20">
        <nav className="pill-bar flex items-center gap-1 rounded-full h-[32px] px-[3.5px]">{items(true)}</nav>
      </div>
    </>
  );
}
