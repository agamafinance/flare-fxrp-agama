'use client';

import AnimatedButton from './AnimatedButton';
import { useFlareWallet } from '@/lib/flare/WalletProvider';

// Same look as the other connect pills: dark-green AnimatedButton, address shortened and
// centred in a "Connect Wallet" footprint.
const pillProps = {
  variant: 'primary' as const,
  fillColor: 'rgba(20, 39, 31, 0.55)',
  borderColor: 'rgba(20, 39, 31, 0.55)',
  textRestColor: '#fff',
  textHoverColor: '#fff',
  className: 'h-10 px-[17px] text-[14px] font-medium whitespace-nowrap',
};

const shorten = (a: string) => `${a.slice(0, 4)}…${a.slice(-4)}`;

export function FlareConnectPill() {
  const { address, connect } = useFlareWallet();

  if (address) {
    return (
      <AnimatedButton {...pillProps} onClick={connect}>
        <span className="relative inline-block">
          <span className="invisible whitespace-nowrap">Connect Wallet</span>
          <span className="absolute inset-0 flex items-center justify-center whitespace-nowrap">{shorten(address)}</span>
        </span>
      </AnimatedButton>
    );
  }

  return (
    <AnimatedButton {...pillProps} onClick={connect}>
      Connect Wallet
    </AnimatedButton>
  );
}
