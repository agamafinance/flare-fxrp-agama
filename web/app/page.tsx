import { TopNav } from "@/components/TopNav";
import { DepositWidget } from "@/components/DepositWidget";
import { Steps } from "@/components/Steps";
import { Why } from "@/components/Why";
import { PositionCard } from "@/components/PositionCard";
import { TeeDemo } from "@/components/TeeDemo";
import { AdvancedRfq } from "@/components/AdvancedRfq";
import { Footer } from "@/components/Footer";

export default function Page() {
  return (
    <>
      <TopNav />
      <main>
        <div className="wrap">
          <section className="hero">
            <div className="fadeup">
              <div className="eyebrow">Fixed income · Flare XRPFi</div>
              <h1>
                Fixed income for your <span className="em">XRP</span>.
              </h1>
              <p className="lead">
                Deposit FXRP, lock a return the day you deposit, and withdraw more at maturity. No
                liquidations, no lock-ups you can&apos;t see, no rate that drifts with the market.
              </p>
              <div className="trust">
                <span className="chip">Live on Flare Coston2</span>
                <span className="chip">FTSO-priced</span>
                <span className="chip">Audited PT/YT primitive</span>
              </div>
              <div className="stats">
                <div className="stat">
                  <b>1:1</b>
                  <span>redeemed at maturity</span>
                </div>
                <div className="stat">
                  <b>0</b>
                  <span>liquidations, ever</span>
                </div>
                <div className="stat">
                  <b>42</b>
                  <span>tests, all green</span>
                </div>
              </div>
            </div>
            <DepositWidget />
          </section>
        </div>

        <Steps />
        <Why />
        <PositionCard />
        <TeeDemo />
        <AdvancedRfq />
        <Footer />
      </main>
    </>
  );
}
