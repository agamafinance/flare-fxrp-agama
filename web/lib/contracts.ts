import type { Address } from "viem";

/** Shared, live Coston2 addresses (demo FXRP has a public mint()). The confidential-market showcase
 *  (rfq/yt/splitter) runs on its own long-lived stack, independent of the saver vault selector. */
export const ADDR = {
  fxrp: "0xb23b0daDa02c86D2A7E76d2060c34Fff14D1E3A6",
  ftso: "0x46c8E98A9Dce3A3327C36fAF69c899F8288e353f",
  pt: "0x7779771976CF16a8EF522E03158620d4dAA516c1",
  yt: "0x1592f5cd44676f182162AC9DC09F9B12C68E0B4D",
  rfq: "0x73F18087dd45d180e75cADcD383479624326E336",
  splitter: "0xcB633439CCa82035Dfb0553Caed2552818E3a29E",
} as const satisfies Record<string, Address>;

/** Fixed-rate vault (90-day). Liquid: withdraw anytime at market, or 1:1 at maturity. */
export type VaultCfg = { key: string; label: string; short: boolean; anchor: Address; vault: Address };
export const VAULTS: readonly VaultCfg[] = [
  { key: "long", label: "90 days", short: false, anchor: "0x8d7AF20B48a42e3D365Dff15ADa569a746E86cfE", vault: "0xFC3af2dC051dA32Bda2017B768E59019Fbf1Ebf8" },
] as const;

export const DECIMALS = 6; // FXRP / PT / arFXRP

export const vaultAbi = [
  { type: "function", name: "deposit", stateMutability: "nonpayable", inputs: [{ type: "uint256" }, { type: "address" }], outputs: [{ type: "uint256" }] },
  { type: "function", name: "redeem", stateMutability: "nonpayable", inputs: [{ type: "uint256" }, { type: "address" }, { type: "address" }], outputs: [{ type: "uint256" }] },
  { type: "function", name: "withdrawEarly", stateMutability: "nonpayable", inputs: [{ type: "uint256" }, { type: "uint256" }], outputs: [{ type: "uint256" }] },
  { type: "function", name: "previewWithdrawEarly", stateMutability: "view", inputs: [{ type: "uint256" }], outputs: [{ type: "uint256" }] },
  { type: "function", name: "balanceOf", stateMutability: "view", inputs: [{ type: "address" }], outputs: [{ type: "uint256" }] },
  { type: "function", name: "maxRedeem", stateMutability: "view", inputs: [{ type: "address" }], outputs: [{ type: "uint256" }] },
  { type: "function", name: "maturity", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
] as const;

export const anchorAbi = [
  { type: "function", name: "previewLock", stateMutability: "view", inputs: [{ type: "uint256" }], outputs: [{ type: "uint256" }, { type: "uint256" }] },
  { type: "function", name: "maturity", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
] as const;

export const erc20Abi = [
  { type: "function", name: "mint", stateMutability: "nonpayable", inputs: [{ type: "address" }, { type: "uint256" }], outputs: [] },
  { type: "function", name: "approve", stateMutability: "nonpayable", inputs: [{ type: "address" }, { type: "uint256" }], outputs: [{ type: "bool" }] },
  { type: "function", name: "balanceOf", stateMutability: "view", inputs: [{ type: "address" }], outputs: [{ type: "uint256" }] },
  { type: "function", name: "allowance", stateMutability: "view", inputs: [{ type: "address" }, { type: "address" }], outputs: [{ type: "uint256" }] },
] as const;

export const ftsoAbi = [
  { type: "function", name: "xrpUsd1e18", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
] as const;

export const splitterAbi = [
  { type: "function", name: "split", stateMutability: "nonpayable", inputs: [{ type: "uint256" }], outputs: [] },
] as const;

export const rfqAbi = [
  { type: "function", name: "openRfq", stateMutability: "nonpayable", inputs: [{ type: "uint256" }, { type: "uint256" }], outputs: [{ type: "uint256" }] },
  { type: "function", name: "cancel", stateMutability: "nonpayable", inputs: [{ type: "uint256" }], outputs: [] },
  { type: "function", name: "nextId", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { type: "function", name: "rfqs", stateMutability: "view", inputs: [{ type: "uint256" }], outputs: [{ type: "address" }, { type: "uint256" }, { type: "uint256" }, { type: "uint256" }, { type: "bool" }] },
] as const;

export const MAX_UINT = (2n ** 256n) - 1n;
