import { formatUnits } from "viem";
import { DECIMALS } from "@/lib/contracts";

export function fmt(v: bigint | undefined, dp = 2): string {
  if (v === undefined || v === null) return "—";
  return Number(formatUnits(v, DECIMALS)).toLocaleString("en-US", { maximumFractionDigits: dp });
}

export function toNum(v: bigint | undefined): number {
  if (v === undefined || v === null) return 0;
  return Number(formatUnits(v, DECIMALS));
}

export function short(a?: string): string {
  return a ? `${a.slice(0, 6)}…${a.slice(-4)}` : "";
}
