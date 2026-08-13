"use client";

import { useAccount, useConnect, useDisconnect, useSwitchChain } from "wagmi";
import { coston2 } from "@/lib/chain";
import { short } from "./format";

export function TopNav() {
  const { address, isConnected, chainId } = useAccount();
  const { connect, connectors, isPending } = useConnect();
  const { disconnect } = useDisconnect();
  const { switchChain } = useSwitchChain();
  const injected = connectors.find((c) => c.id === "injected") ?? connectors[0];
  const onChain = isConnected && chainId === coston2.id;
  const wrongChain = isConnected && chainId !== coston2.id;

  return (
    <nav className="nav">
      <div className="wrap nav-inner">
        <div className="brand">
          <div className="mark">A</div>
          <div>
            Agama
            <small>fixed income · XRP</small>
          </div>
        </div>
        <div className="nav-right">
          <span className="chip">
            <span className="dot" style={{ background: onChain ? "var(--up)" : "var(--faint)" }} />
            {onChain ? "Coston2 · live" : "Flare Coston2"}
          </span>
          {!isConnected && (
            <button className="btn-wallet accent" disabled={isPending} onClick={() => injected && connect({ connector: injected })}>
              {isPending ? "Connecting…" : "Connect wallet"}
            </button>
          )}
          {wrongChain && (
            <button className="btn-wallet accent" onClick={() => switchChain({ chainId: coston2.id })}>
              Switch to Coston2
            </button>
          )}
          {onChain && (
            <button className="btn-wallet" onClick={() => disconnect()} title="Disconnect">
              {short(address)}
            </button>
          )}
        </div>
      </div>
    </nav>
  );
}
