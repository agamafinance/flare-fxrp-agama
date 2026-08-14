import type { Metadata } from 'next';
import { Inter } from 'next/font/google';
import './globals.css';
import { AppFrame } from '@/components/AppFrame';
import { FlareWalletProvider } from '@/lib/flare/WalletProvider';

const inter = Inter({ subsets: ['latin'], variable: '--font-sans', display: 'swap' });

export const metadata: Metadata = {
  title: 'Agama · fixed-rate FXRP on Flare',
  description:
    'Lock a fixed rate on your XRP. Deposit FXRP, withdraw anytime at market or 1:1 at maturity. Live on Flare Coston2.',
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en" className={`dark ${inter.variable}`} suppressHydrationWarning>
      <body className="min-h-screen bg-bg text-fg antialiased" suppressHydrationWarning>
        <FlareWalletProvider>
          <AppFrame>{children}</AppFrame>
        </FlareWalletProvider>
      </body>
    </html>
  );
}
