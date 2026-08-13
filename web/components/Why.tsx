export function Why() {
  return (
    <section className="block" id="why">
      <div className="wrap">
        <div className="eyebrow">Why Agama</div>
        <h2>A bond&apos;s certainty, a savings app&apos;s simplicity.</h2>
        <div className="why">
          <div className="card">
            <h3>
              Locked <span className="k">at entry</span>
            </h3>
            <p>
              Your rate is set the moment you deposit and no later deposit can re-price it. Shares are
              par-denominated: one arFXRP is one FXRP at maturity.
            </p>
          </div>
          <div className="card">
            <h3>
              <span className="k">Zero</span> liquidations
            </h3>
            <p>
              There is no collateral to margin-call and no health factor to watch. You hold a claim
              that redeems for principal plus the fixed gain, whatever the market does.
            </p>
          </div>
          <div className="card">
            <h3>
              On-chain &amp; <span className="k">transparent</span>
            </h3>
            <p>
              Priced by Flare&apos;s FTSO oracle, built on a self-contained PT/YT primitive with 42
              tests and an OpenZeppelin ERC-4626 vault. No black box, no off-chain desk.
            </p>
          </div>
        </div>
      </div>
    </section>
  );
}
