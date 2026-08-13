const IconDeposit = (
  <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round">
    <path d="M12 3v10" />
    <path d="m8 9 4 4 4-4" />
    <path d="M4 17v2a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-2" />
  </svg>
);
const IconLock = (
  <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round">
    <rect x="4" y="10" width="16" height="11" rx="2" />
    <path d="M8 10V7a4 4 0 0 1 8 0v3" />
    <path d="M12 14v3" />
  </svg>
);
const IconGrow = (
  <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round">
    <path d="M3 17l6-6 4 4 7-8" />
    <path d="M17 7h4v4" />
  </svg>
);

export function Steps() {
  return (
    <section className="block" id="how">
      <div className="wrap">
        <div className="eyebrow">How it works</div>
        <h2>Three steps. No jargon.</h2>
        <p className="sublead">
          You only ever deposit and withdraw. Under the hood a principal token is bought at a discount
          and redeemed 1:1 at maturity, but the pool hides all of it.
        </p>
        <div className="steps">
          <div className="step">
            <span className="idx">01</span>
            <div className="ic">{IconDeposit}</div>
            <h3>Deposit FXRP</h3>
            <p>One transaction into the fixed-rate pool. You receive arFXRP shares in your wallet.</p>
          </div>
          <div className="step">
            <span className="idx">02</span>
            <div className="ic">{IconLock}</div>
            <h3>Your rate is fixed</h3>
            <p>You see the exact amount you will hold at maturity before you confirm. It cannot drift.</p>
          </div>
          <div className="step">
            <span className="idx">03</span>
            <div className="ic">{IconGrow}</div>
            <h3>Withdraw more</h3>
            <p>At maturity, redeem for your deposit plus the fixed gain, one share for one FXRP.</p>
          </div>
        </div>
      </div>
    </section>
  );
}
