"use client";

import { useState } from "react";

type Bid = { mm: string; price: number; won: boolean };
type Result = {
  enclave: { address: string; hwmodel: string; dbgstat: string; imageDigest: string };
  onchainTrusted: boolean;
  rfqId: number;
  openTx: string;
  reserve: number;
  forgedRejected: boolean;
  bids: Bid[];
  winner: string;
  price: number;
  signature: { v: number; r: string };
  settleTx: string;
  sellerPremium: number;
  explorer: string;
};

const short = (a: string) => (a ? `${a.slice(0, 6)}…${a.slice(-4)}` : "");

export function TeeDemo() {
  const [loading, setLoading] = useState(false);
  const [res, setRes] = useState<Result | null>(null);
  const [err, setErr] = useState("");

  async function run() {
    setLoading(true);
    setErr("");
    setRes(null);
    try {
      const r = await fetch("/api/tee-demo", { method: "POST" });
      const j = await r.json();
      if (!r.ok || j.error) setErr(j.error || "failed");
      else setRes(j as Result);
    } catch (e) {
      setErr((e as Error)?.message || "failed");
    } finally {
      setLoading(false);
    }
  }

  const digest = res?.enclave.imageDigest ? `${res.enclave.imageDigest.slice(0, 14)}…${res.enclave.imageDigest.slice(-6)}` : "";

  return (
    <section className="block" id="tee">
      <div className="wrap">
        <div className="eyebrow">Confidential compute · Bounty 2</div>
        <h2>See the private market settle, live.</h2>
        <p className="sublead">
          The yield side runs as a sealed-bid auction inside a Flare Confidential Compute enclave
          (Intel TDX). Click to run a real settlement on Coston2: market makers bid privately, the
          enclave picks the best and signs it in the TEE, and only the winner settles on chain. The
          losing bid never appears.
        </p>

        <div className="panel" style={{ marginTop: 24 }}>
          {!res && (
            <button className="btn-primary" style={{ maxWidth: 380 }} onClick={run} disabled={loading}>
              {loading ? "Running a real settlement on Coston2…" : "▶ Run a live confidential settlement"}
            </button>
          )}
          {loading && (
            <p className="sub" style={{ marginTop: 14 }}>
              Opening the RFQ, collecting sealed bids, signing in the TEE, settling on-chain. About 60
              seconds, real transactions.
            </p>
          )}
          {err && <div className="status err" style={{ marginTop: 12 }}>Demo failed: {err}</div>}

          {res && (
            <div>
              <div className="att">
                <span className="b">Intel TDX</span>
                <span className="b">{res.enclave.dbgstat === "disabled-since-boot" ? "prod · non-debuggable" : res.enclave.dbgstat}</span>
                <span className="b">image {digest}</span>
                <span className="b">key {short(res.enclave.address)}</span>
                {res.onchainTrusted && <span className="b">trusted on-chain ✓</span>}
              </div>

              <div className="resrow">
                <span>Seller opened</span>
                <b>RFQ #{res.rfqId}</b>
                <span>· 100 YT escrowed · reserve {res.reserve} FXRP</span>
                <a className="reslink" href={`${res.explorer}/tx/${res.openTx}`} target="_blank" rel="noreferrer">tx ↗</a>
              </div>
              {res.forgedRejected && (
                <div className="resrow">
                  <span>Guardrail:</span>
                  <b style={{ color: "var(--up)" }}>a forged quote was rejected off-chain ✓</b>
                </div>
              )}

              <div style={{ margin: "16px 0 4px", fontSize: 12, color: "var(--faint)", fontWeight: 600, textTransform: "uppercase", letterSpacing: ".06em" }}>
                Sealed bids to the enclave
              </div>
              {res.bids.map((b) => (
                <div key={b.mm} className={`bid ${b.won ? "win" : "lose"}`}>
                  <span>
                    Market maker {short(b.mm)} <span className="price">{b.price} FXRP</span>
                  </span>
                  <span className="tag">{b.won ? "WON · signed in the TEE" : "HIDDEN · never on chain"}</span>
                </div>
              ))}

              <div className="resrow" style={{ marginTop: 14 }}>
                <span>Enclave signature</span>
                <b className="tnum">v={res.signature.v} r={res.signature.r.slice(0, 14)}…</b>
              </div>
              <div className="resrow">
                <span>Settled on-chain:</span>
                <b>seller +{res.sellerPremium} FXRP premium</b>
                <a className="reslink" href={`${res.explorer}/tx/${res.settleTx}`} target="_blank" rel="noreferrer">tx ↗</a>
              </div>

              <button className="btn-ghost" style={{ marginTop: 18, maxWidth: 260 }} onClick={run} disabled={loading}>
                {loading ? "Running…" : "Run another settlement"}
              </button>
            </div>
          )}
        </div>
      </div>
    </section>
  );
}
