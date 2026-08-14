// Agama on Flare Coston2 — the fixed-rate FXRP savings product.
// Deposit FXRP, lock a fixed rate, withdraw anytime (market) or 1:1 at maturity.
// Contracts deployed + verified from the anchor-poc (agamafinance/flare-fxrp-agama).
import { defineChain } from 'viem';

export const coston2 = defineChain({
  id: 114,
  name: 'Flare Coston2',
  nativeCurrency: { name: 'Coston2 Flare', symbol: 'C2FLR', decimals: 18 },
  rpcUrls: { default: { http: ['https://coston2-api.flare.network/ext/C/rpc'] } },
  blockExplorers: { default: { name: 'Coston2 Explorer', url: 'https://coston2-explorer.flare.network' } },
  testnet: true,
});

export const COSTON2_HEX = '0x72'; // 114

export const ADDR = {
  vault: '0xFC3af2dC051dA32Bda2017B768E59019Fbf1Ebf8', // FixedRateVault (arFXRP), 90-day
  anchor: '0x8d7AF20B48a42e3D365Dff15ADa569a746E86cfE', // fixed-rate router (previewLock)
  fxrp: '0xb23b0daDa02c86D2A7E76d2060c34Fff14D1E3A6', // demo FXRP (public mint)
  ftso: '0x46c8E98A9Dce3A3327C36fAF69c899F8288e353f', // FtsoReader (XRP/USD)
} as const;

export const FLARE_DECIMALS = 6; // FXRP / arFXRP
export const MAX_UINT = 2n ** 256n - 1n;

export const explorerTx = (h: string) => `https://coston2-explorer.flare.network/tx/${h}`;
export const explorerAddr = (a: string) => `https://coston2-explorer.flare.network/address/${a}`;

export function toBaseUnits(human: string | number): bigint {
  const s = String(human).trim();
  if (!s) return 0n;
  const [whole = '0', frac = ''] = s.replace(/,/g, '').split('.');
  const padded = (frac + '0'.repeat(FLARE_DECIMALS)).slice(0, FLARE_DECIMALS);
  return BigInt(whole || '0') * 10n ** BigInt(FLARE_DECIMALS) + BigInt(padded || '0');
}

export function fromBaseUnits(v: bigint | undefined, precision = 2): string {
  if (v === undefined) return '—';
  const neg = v < 0n;
  const abs = neg ? -v : v;
  const base = 10n ** BigInt(FLARE_DECIMALS);
  const whole = abs / base;
  const frac = abs % base;
  const fracStr = frac.toString().padStart(FLARE_DECIMALS, '0').slice(0, precision);
  const out = precision > 0 ? `${whole.toLocaleString('en-US')}.${fracStr}` : whole.toLocaleString('en-US');
  return neg ? `-${out}` : out;
}
