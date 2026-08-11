# Anchor — deployment

Fixed-rate XRPFi product. Full stack: demo-mintable 6-decimal FXRP + ERC-4626 vault +
YieldSplitter (PT/YT) + PtAmm (YieldSpace) + Anchor router.

## Status

- **10/10 Foundry tests green** (`forge test`): splitter, AMM, E2E, unified router at 18 & 6
  decimals, plus a live Flare-mainnet fork test against the real bizFXRP vault.
- **Deploy script proven on a local anvil**: full stack deploys, seeds a deep pool, and the
  deployed `Anchor.previewLock(500 FXRP)` returns 505.44 PT @ 5.00% fixed APR.

## Deploy to Coston2 (Flare testnet, chainId 114)

You need a deployer key funded with C2FLR (gas only — the demo FXRP is minted by the script).

1. **Fund a key** with C2FLR from the faucet: https://faucet.flare.network/coston2
   (paste the address of the key you'll deploy with).

2. **Broadcast:**
   ```bash
   cd anchor-poc
   PRIVATE_KEY=0x<your funded key> \
     forge script script/Deploy.s.sol:Deploy --rpc-url coston2 --broadcast
   ```
   The script prints all deployed addresses (FXRP, Vault, Splitter, PT, YT, PtAmm, Anchor).

3. **Sanity-check on-chain:**
   ```bash
   cast call <ANCHOR> "previewLock(uint256)(uint256,uint256)" 500000000 --rpc-url coston2
   # -> (ptOut in 6-dec, impliedApr in 1e18)  e.g. 505439680, 5e16
   ```

## Front (on-chain dApp)

An artifact can't call an RPC (strict CSP), so the on-chain front is a small Next.js + viem
app (Vercel-friendly, matches the Agama stack). It reads the deployed addresses from a config,
lets a user mint demo FXRP, calls `anchor.previewLock` for the live quote, then
`anchor.lockFixedRate` to lock, and `anchor.redeem` after maturity. The interactive artifact
(YieldSpace math, pool-depth slider) is the pitch/explainer; this is the live demo.

## Notes

- Demo FXRP has a public `mint()` so the front can fund test users. For a real deployment,
  point the splitter at a genuine ERC-4626 FXRP vault (see the vaults reference: bizFXRP is
  permissionless; CSXRP/Mystic is the credibility target but gates deposits).
- Native XRP -> FXRP can't be a synchronous on-chain deposit (FAssets needs an XRPL payment +
  FDC proof). For a stage demo, pre-mint FTestXRP; show bridging as a secondary flow.
