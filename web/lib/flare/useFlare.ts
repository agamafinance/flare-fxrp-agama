'use client';

import { useCallback, useEffect, useState } from 'react';
import { createPublicClient, createWalletClient, custom, http, formatUnits } from 'viem';
import { coston2, COSTON2_HEX, ADDR, MAX_UINT } from './config';
import { ERC20_ABI, VAULT_ABI, ANCHOR_ABI, FTSO_ABI } from './abis';

const RPC = typeof window === 'undefined' ? coston2.rpcUrls.default.http[0] : '/api/flare-rpc';
export const pub = createPublicClient({ chain: coston2, transport: http(RPC) });

export interface FlareMarket {
  apr: number; // headline fixed rate %
  xrpUsd: number;
}
export interface FlareAccount {
  address: `0x${string}`;
  fxrp: number; // FXRP wallet balance
  shares: number; // arFXRP (value at maturity, 1:1)
  earlyValue: number; // FXRP you'd get by exiting now (market)
  maturity: number; // unix seconds
}

const n = (v: bigint, d = 6) => Number(formatUnits(v, d));

export function useFlareData(address?: `0x${string}`) {
  const [market, setMarket] = useState<FlareMarket | null>(null);
  const [account, setAccount] = useState<FlareAccount | null>(null);
  const [tick, setTick] = useState(0);
  const refresh = useCallback(() => setTick((t) => t + 1), []);

  useEffect(() => {
    let alive = true;
    (async () => {
      try {
        const [quote, xrp] = await Promise.all([
          pub.readContract({ address: ADDR.anchor, abi: ANCHOR_ABI, functionName: 'previewLock', args: [1000_000000n] }),
          pub.readContract({ address: ADDR.ftso, abi: FTSO_ABI, functionName: 'xrpUsd1e18' }).catch(() => 0n),
        ]);
        if (!alive) return;
        setMarket({ apr: Number(formatUnits((quote as [bigint, bigint])[1], 18)) * 100, xrpUsd: Number(formatUnits(xrp as bigint, 18)) });
      } catch (e) { console.error('flare market', e); }
    })();
    return () => { alive = false; };
  }, [tick]);

  useEffect(() => {
    if (!address) { setAccount(null); return; }
    let alive = true;
    (async () => {
      try {
        const [fxrp, shares, maturity] = await Promise.all([
          pub.readContract({ address: ADDR.fxrp, abi: ERC20_ABI, functionName: 'balanceOf', args: [address] }),
          pub.readContract({ address: ADDR.vault, abi: VAULT_ABI, functionName: 'balanceOf', args: [address] }),
          pub.readContract({ address: ADDR.vault, abi: VAULT_ABI, functionName: 'maturity' }),
        ]);
        let early = 0n;
        if ((shares as bigint) > 0n) {
          early = (await pub.readContract({ address: ADDR.vault, abi: VAULT_ABI, functionName: 'previewWithdrawEarly', args: [shares as bigint] }).catch(() => 0n)) as bigint;
        }
        if (!alive) return;
        setAccount({ address, fxrp: n(fxrp as bigint), shares: n(shares as bigint), earlyValue: n(early), maturity: Number(maturity as bigint) });
      } catch (e) { console.error('flare acct', e); }
    })();
    return () => { alive = false; };
  }, [address, tick]);

  return { market, account, refresh };
}

// ---- injected wallet (MetaMask / Rabby), switch to Coston2 ----
export function useWallet() {
  const [address, setAddress] = useState<`0x${string}` | undefined>();
  const connect = useCallback(async () => {
    const eth = (window as any).ethereum;
    if (!eth) { alert('Install MetaMask or Rabby'); return; }
    const [acc] = await eth.request({ method: 'eth_requestAccounts' });
    try {
      await eth.request({ method: 'wallet_switchEthereumChain', params: [{ chainId: COSTON2_HEX }] });
    } catch (e: any) {
      if (e.code === 4902) await eth.request({ method: 'wallet_addEthereumChain', params: [{ chainId: COSTON2_HEX, chainName: 'Flare Coston2', nativeCurrency: { name: 'C2FLR', symbol: 'C2FLR', decimals: 18 }, rpcUrls: ['https://coston2-api.flare.network/ext/C/rpc'], blockExplorerUrls: ['https://coston2-explorer.flare.network'] }] });
    }
    setAddress(acc);
  }, []);
  useEffect(() => {
    const eth = (window as any).ethereum;
    if (!eth) return;
    eth.request({ method: 'eth_accounts' }).then((a: string[]) => { if (a[0]) setAddress(a[0] as `0x${string}`); }).catch(() => {});
  }, []);
  return { address, connect };
}

async function walletClient() {
  const eth = (window as any).ethereum;
  return createWalletClient({ chain: coston2, transport: custom(eth) });
}

export async function send(address: `0x${string}`, to: `0x${string}`, abi: any, fn: string, args: any[]) {
  const wc = await walletClient();
  const hash = await wc.writeContract({ account: address, address: to, abi, functionName: fn, args, chain: coston2 });
  await pub.waitForTransactionReceipt({ hash });
  return hash;
}

export async function ensureAllowance(address: `0x${string}`, token: `0x${string}`, spender: `0x${string}`, need: bigint) {
  const cur = (await pub.readContract({ address: token, abi: ERC20_ABI, functionName: 'allowance', args: [address, spender] })) as bigint;
  if (cur < need) await send(address, token, ERC20_ABI, 'approve', [spender, MAX_UINT]);
}
