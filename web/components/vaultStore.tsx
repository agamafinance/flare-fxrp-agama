"use client";

import { createContext, useContext, useState, type ReactNode } from "react";
import { VAULTS, type VaultCfg } from "@/lib/contracts";

type Store = { vault: VaultCfg; idx: number; setIdx: (i: number) => void };
const Ctx = createContext<Store>({ vault: VAULTS[0], idx: 0, setIdx: () => {} });

export function VaultProvider({ children }: { children: ReactNode }) {
  const [idx, setIdx] = useState(0);
  return <Ctx.Provider value={{ vault: VAULTS[idx], idx, setIdx }}>{children}</Ctx.Provider>;
}

export const useSelectedVault = () => useContext(Ctx);
