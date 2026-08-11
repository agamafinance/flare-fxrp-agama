# Agama · fixed-rate FXRP on Flare

**Lock a fixed rate on your XRP. Sell the uncertainty.**

Agama brings fixed-rate savings to XRPFi on [Flare](https://flare.network). You
deposit FXRP, buy the **principal token (PT)** at a discount, and redeem it **1:1 at maturity**.
Your return is fixed the moment you buy, no matter what the underlying vault actually earns. The
variable yield goes to whoever wants the upside (the **yield token, YT**).

Built for the Flare Summer Signal hackathon. Live on Coston2.

## Why

XRPFi is yield poor and yield variable: today's vaults pay a few percent that nobody can promise
in advance. Agama turns that variable stream into a choice. Buy PT to lock certainty, or buy YT
to take the upside. Same deposit, two honest sides of the same trade.

## How it works

1. **Deposit into a vault.** FXRP earns real XRPFi yield in an ERC-4626 vault (e.g. Mystic Core
   FXRP or Bizantine SuperVault), issued as vault shares.
2. **Split into PT + YT.** The position is tokenized: principal and yield become two separate,
   tradable tokens. PT redeems 1:1 for principal at maturity; YT captures all the yield until then.
3. **Buy PT at a discount.** On a real YieldSpace AMM you buy PT below par. That discount *is*
   your fixed rate, locked at purchase.
4. **Redeem 1:1 at maturity.** Each PT redeems for exactly 1 FXRP of principal. Your return was
   fixed on day one, whatever the yield did.

The fixed rate is manufactured by the PT discount, not by anyone's balance sheet. As maturity
nears, the YieldSpace curve flattens to constant-sum and PT converges to par mechanically.

## Architecture

| Contract | Role |
| --- | --- |
| `YieldSplitter.sol` | The PT/YT engine over an ERC-4626 vault. Split, claim yield, redeem principal. MasterChef-style yield accounting stays correct when YT changes hands. |
| `SplitToken.sol` | Minimal ERC20 for PT and YT. The YT instance settles yield on every transfer. |
| `PtAmm.sol` | A real YieldSpace AMM (`x^(1-t) + y^(1-t) = k`) for PT vs FXRP, decimals-aware (real FXRP is 6 decimals), PRBMath fixed point. Buying PT locks a fixed rate. |
| `Anchor.sol` | The user-facing router. One call to lock a fixed rate, a quote for the front, and 1:1 redemption at maturity. |
| `ConfidentialYtRfq.sol` | The confidential YT demand side. Market makers quote privately inside a TEE; the enclave signs only the winning settlement, which this contract verifies and executes. |
| `FtsoReader.sol` | Reads the enshrined FTSOv2 oracle to denominate FXRP positions in USD (front and enclave). |
| `XrpOnRamp.sol` + `fdc/IFdc.sol` | Native-XRP on-ramp: verifies an FDC Payment proof against the enshrined FdcVerification, so real XRP from the XRPL is credited on Flare with no bridge trust. |
| `interfaces/IERC4626.sol` | The standard vault surface the splitter codes against, so a real vault is a one-line swap. |
| `MockERC20.sol`, `MockVault.sol` | Test and demo stand-ins for FXRP and a yield-bearing vault. |

## Flare integration (the whole enshrined stack)

Agama uses five of Flare's enshrined protocols, each doing real work, not a superficial call:

| Protocol | How Agama uses it |
| --- | --- |
| **FAssets (FXRP)** | The underlying asset. The product is fixed-rate savings on bridged XRP. |
| **Confidential Compute (TEE)** | The YT demand side runs as a confidential RFQ in a Confidential Space enclave: market makers quote privately, only the winning settlement is revealed. |
| **FTSO** | The enclave and front read live XRP/USD to bound quotes and denominate the fixed rate in USD. |
| **Secure RNG** | Breaks best-price ties between market makers fairly and verifiably in the confidential matcher. |
| **FDC** | Native-XRP deposits: an FDC Payment proof of an XRPL transfer is verified on chain before crediting. |

## Proven

`forge test` runs **17 tests, all green**, including:

- The full lifecycle: split, YT captures the yield, PT redeems principal 1:1.
- Sell YT to lock certainty; the yield accounting splits correctly on transfer.
- The YieldSpace AMM: PT trades at a discount, implies a 5% fixed APR, converges to par at maturity.
- End to end: a buyer's realized return equals the rate locked at purchase, **independent of the
  realized yield**, which flows entirely to YT.
- The unified router exercised at both 18 and the real **6 decimals** (identical result).
- A **live Flare mainnet fork test** binding the splitter to the real `bizFXRP` ERC-4626 vault:
  real FXRP deposit, real price-per-share, position equals principal.
- The confidential YT RFQ: an enclave-signed best-execution settlement is verified and settled on
  chain; a forged signature is rejected; the seller can reclaim escrowed YT.
- Live reads of the enshrined **FTSO** (XRP/USD) and **Secure RNG** on a Coston2 fork.
- The **FDC** Payment-proof verification path wired to the live FdcVerification, rejecting an
  unattested proof.

## Confidential Compute (Bounty 2)

Fixed-rate products need a two-sided market: for a buyer to lock certainty, someone must take the
variable yield (the YT). On a yield-poor chain that YT demand is thin, and market makers will not
post public quotes because an on-chain order book leaks their pricing.

`ConfidentialYtRfq` runs that demand side as a **confidential request-for-quote inside a Flare
Confidential Compute enclave (GCP Confidential Space, Intel TDX)**. Market makers submit sealed
quotes to the enclave; it runs best execution and signs **only the winning settlement**; the
contract verifies the enclave signature (registered on chain from its remote attestation) and
settles atomically. The losing quotes never touch the chain.

This makes the same product qualify for both hackathon tracks: an interoperable asset product
(Bounty 1) whose counterparty market is a private application built with Flare Confidential
Compute (Bounty 2). In this POC the enclave is a signer whose key the contract trusts (see
`script/Enclave.s.sol`); in production the identical matching code runs in Confidential Space and
its attestation registers the key.

## Live on Coston2 (chainId 114)

Self-contained demo deployment (demo FXRP has a public `mint()` so anyone can try it).

| Contract | Address |
| --- | --- |
| Anchor | `0xC0E346206B5d6446f69522D29A88BC45B2B5c719` |
| FXRP (demo) | `0xA6fC08A750dC00e6f613e2aabaB5a54949D8B356` |
| Vault | `0xD0c8Ca68cc81fF4486d5D725fCE612ddFeb0672D` |
| YieldSplitter | `0xBb4c3A08E108465b305205D92C089cd1a63976b6` |
| PT | `0x4557491bCd8Da8BD2e32861b5C3CB70EDCB3D1aE` |
| YT | `0x04A05b47fd57E5230a428111B9c3B45c16493752` |
| PtAmm | `0x77D28482ace00b7760766a7699e6DcdDeAeed82E` |
| ConfidentialYtRfq | `0xFc2440629530a11915E65E3261779E37f70e3790` |
| FtsoReader | `0x46c8E98A9Dce3A3327C36fAF69c899F8288e353f` |

A second instance with a short (10 minute) maturity is deployed for demoing the full lock to
redeem cycle live: Anchor `0xd84508307C035F409777e2b5E5eCa90bE34Eb292`.

Explorer: https://coston2-explorer.flare.network/address/0xC0E346206B5d6446f69522D29A88BC45B2B5c719

## Run it

```bash
forge test              # 10/10, plus a live Flare fork test
forge test -vv          # with the logged numbers
```

Front (browser dApp, viem):

```bash
./run-local.sh          # anvil + deploy + serve, then open http://127.0.0.1:8547/app.html
```

Or open `frontend/app.html` against Coston2 directly with a wallet. Deploy your own:
see [`DEPLOY.md`](./DEPLOY.md).

## Notes

- **Real vaults.** The splitter codes against ERC-4626, so it wraps any single-asset yield vault
  whose price-per-share only grows. `bizFXRP` is permissionless; Mystic `CSXRP` is the higher
  credibility target but gates deposits. DEX LP tokens are not strippable (no stable principal).
- **FAssets.** Native XRP becomes FXRP only through the FAssets protocol (an XRPL payment plus an
  FDC proof), so it is not a synchronous on-chain deposit. Build against FXRP as a plain ERC20;
  pre-mint test FXRP for a live demo.
- **Liquidity is the product.** The locked rate is the discount minus slippage. A trade that is
  large relative to the pool eats its own discount, so depth matters.

## Disclaimer

Proof of concept, unaudited, testnet only. Not financial advice.
