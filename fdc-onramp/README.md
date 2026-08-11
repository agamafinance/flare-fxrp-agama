# Native-XRP on-ramp (FDC + FAssets)

The interoperable-asset path proven end to end on Coston2: real XRP on the XRPL becomes real FXRP
on Flare, with no bridge trust, using the enshrined Flare Data Connector (FDC) and FAssets.

## Two things are proven

**1. FDC attestation, verified on chain.** A real XRPL testnet payment is attested by the FDC and
verified against the live Relay Merkle root by `XrpOnRamp` (see `../test/FdcRealProof.t.sol`).
Reproduce with `run.py`.

**2. A full FAssets mint of real FTestXRP.** Native XRP paid to a FAssets agent, attested by the
FDC, mints real FTestXRP:

| Step | Contract / action | Evidence |
| --- | --- | --- |
| Reserve collateral | `AssetManager.reserveCollateral(agent, 1 lot, ...)` | crtId `48120141`, agent XRPL `r4uKJRy9mjxGHw1yzS1SrtaKCUwT66MCcP` |
| Pay XRP to the agent | XRPL Payment (10.025 XRP) with the reservation reference | tx `B97FA8A14546573623BC44AFE2E19359EBD49DD25523B23E39CFBCE9C4431D10` |
| Attest the payment | FDC `prepareRequest` + `requestAttestation` + DA layer proof | round `1422601` |
| Execute the mint | `AssetManager.executeMinting(proof, crtId)` (`../script/ExecuteMinting.s.sol`) | FTestXRP balance 10 -> 20, payment status 0 |

## Key facts

- FXRP (Coston2 FTestXRP): `0x0b6A3645c240605887a5532109323A3E12273dc7` (6 decimals)
- AssetManagerFXRP: `0xc1Ca88b937d0b528842F95d5731ffB586f4fbDFA`, lot size 10 XRP
- FdcHub `0x48aC463d7975828989331F4De43341627b9c5f1D`, Relay protocol id 200
- Verifier: `https://fdc-verifiers-testnet.flare.network/verifier/xrp/Payment/prepareRequest`,
  public testnet key `00000000-0000-0000-0000-000000000000`
- DA layer: `https://ctn2-data-availability.flare.network/api/v1/fdc/proof-by-request-round-raw`
- The FDC leaf is `keccak256` of the raw attested response bytes (20 words, including a trailing
  word); verify against `Relay.merkleRoots(200, votingRound)`.

## Requirements

`xrpl-py`, `requests`, and foundry `cast` on PATH; a Coston2 key with C2FLR in `PRIVATE_KEY`.
