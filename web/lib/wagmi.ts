import { http, createConfig, createStorage, cookieStorage } from "wagmi";
import { injected } from "wagmi/connectors";
import { coston2 } from "./chain";

// Reads are routed through the app's own /api/rpc proxy (no browser CORS); writes go
// through the injected wallet. In SSR there is no origin, so fall back to the public RPC.
const readUrl = typeof window === "undefined" ? coston2.rpcUrls.default.http[0] : "/api/rpc";

export const config = createConfig({
  chains: [coston2],
  connectors: [injected({ shimDisconnect: true })],
  transports: { [coston2.id]: http(readUrl) },
  storage: createStorage({ storage: cookieStorage }),
  ssr: true,
});

declare module "wagmi" {
  interface Register {
    config: typeof config;
  }
}
