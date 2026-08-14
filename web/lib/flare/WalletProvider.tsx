'use client';

import { createContext, useContext, ReactNode } from 'react';
import { useWallet } from './useFlare';

const Ctx = createContext<ReturnType<typeof useWallet>>({ address: undefined, connect: async () => {} });

export function FlareWalletProvider({ children }: { children: ReactNode }) {
  const wallet = useWallet();
  return <Ctx.Provider value={wallet}>{children}</Ctx.Provider>;
}

export function useFlareWallet() {
  return useContext(Ctx);
}
