"use client";

import { useState } from "react";
import { useAccount, useSwitchChain, useWriteContract } from "wagmi";
import { waitForTransactionReceipt } from "@wagmi/core";
import { useQueryClient } from "@tanstack/react-query";
import { config } from "@/lib/wagmi";
import { coston2 } from "@/lib/chain";

export type Status = { msg: string; kind: "" | "ok" | "err" };

/** Runs a sequence of write steps (e.g. approve then deposit), waiting for each receipt,
 *  surfaces a status line, and refreshes all on-chain reads on success. Guarantees the wallet
 *  is on Coston2 first, so a tx can never be sent on the wallet's default (e.g. Ethereum). */
export function useAction() {
  const { writeContractAsync } = useWriteContract();
  const { chainId } = useAccount();
  const { switchChainAsync } = useSwitchChain();
  const qc = useQueryClient();
  const [status, setStatus] = useState<Status>({ msg: "", kind: "" });
  const [busy, setBusy] = useState(false);

  async function run(steps: Array<() => Promise<`0x${string}`>>, pending: string, done: string) {
    setBusy(true);
    try {
      if (chainId !== coston2.id) {
        setStatus({ msg: "Switching your wallet to Coston2…", kind: "" });
        await switchChainAsync({ chainId: coston2.id });
      }
      for (const step of steps) {
        setStatus({ msg: pending, kind: "" });
        const hash = await step();
        setStatus({ msg: `Sent ${hash.slice(0, 10)}… waiting for confirmation`, kind: "" });
        await waitForTransactionReceipt(config, { hash });
      }
      setStatus({ msg: done, kind: "ok" });
      await qc.invalidateQueries();
    } catch (e: unknown) {
      const err = e as { shortMessage?: string; message?: string };
      setStatus({ msg: err?.shortMessage || err?.message || "Transaction failed", kind: "err" });
    } finally {
      setBusy(false);
    }
  }

  return { run, status, setStatus, busy, writeContractAsync };
}
