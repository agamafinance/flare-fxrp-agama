import { ADDR, VAULTS } from "@/lib/contracts";

const EXPLORER = "https://coston2-explorer.flare.network/address/";

const rows: Array<[string, string]> = [
  ["FixedRateVault (arFXRP)", VAULTS[0].vault],
  ["Anchor router", VAULTS[0].anchor],
  ["Confidential RFQ (TEE)", ADDR.rfq],
  ["FTSO reader", ADDR.ftso],
];

export function Footer() {
  return (
    <footer>
      <div className="wrap foot">
        <div style={{ maxWidth: "32em" }}>
          <div className="brand" style={{ marginBottom: 10 }}>
            <div className="mark">A</div>
            <div>
              Agama
              <small>fixed income · XRP</small>
            </div>
          </div>
          <p className="sub" style={{ margin: 0 }}>
            A fixed-rate savings pool on Flare Coston2. Deposit FXRP, lock a rate, withdraw more at
            maturity. Proof of concept, unaudited, testnet only. Not financial advice.
          </p>
        </div>
        <div className="addrs">
          <div className="eyebrow" style={{ marginBottom: 4 }}>Deployed contracts</div>
          {rows.map(([label, addr]) => (
            <a key={addr} href={`${EXPLORER}${addr}`} target="_blank" rel="noreferrer">
              <span>{label}</span>
              {addr.slice(0, 8)}…{addr.slice(-6)}
            </a>
          ))}
        </div>
      </div>
    </footer>
  );
}
