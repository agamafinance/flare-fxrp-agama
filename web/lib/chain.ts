import { defineChain } from "viem";

export const RPC_URL = "https://coston2-api.flare.network/ext/C/rpc";

/** Flare's Coston2 testnet, where the whole fixed-rate stack is deployed. */
export const coston2 = defineChain({
  id: 114,
  name: "Coston2",
  nativeCurrency: { name: "Coston2 Flare", symbol: "C2FLR", decimals: 18 },
  rpcUrls: { default: { http: [RPC_URL] } },
  blockExplorers: {
    default: { name: "Coston2 Explorer", url: "https://coston2-explorer.flare.network" },
  },
  testnet: true,
});
