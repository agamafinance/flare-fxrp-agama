# Testing against a Coston2 deployment

For exercising an extension that is already deployed and registered on Coston2 —
either on a Confidential Space VM, or locally with a public tunnel. To deploy one
first, see [deployment-steps.md](deployment-steps.md).

## What you need

| Need | Note |
|---|---|
| `.env.coston2` | filled in; `use-chain.sh coston2` activates it |
| A funded Coston2 key | sends the test instructions; get C2FLR from the [faucet](https://faucet.flare.network/coston2) |
| `config/coston2/deployed-addresses.json` | the `FlareTeeManager` diamond and friends |
| `config/proxy/extension_proxy.coston2.docker.toml` | gitignored — copy the `.example` and fill in `[db]` |
| A reachable `EXT_PROXY_URL` | the VM's URL, or a tunnel if the proxy runs locally |

## Confirm the deployment is live

```bash
curl -s "$EXT_PROXY_URL/info" | jq '{extensionId, codeHash, platform}'
```

| Field | Expect |
|---|---|
| `extensionId` | matches `EXTENSION_ID` in `config/extension.env` |
| `codeHash` | the hash registered on-chain — `0x194844cf…` means simulated, not real hardware |
| `platform` | `GCP_AMD_SEV` on real hardware, `TEST_PLATFORM` when simulated |

Then check the on-chain side:

```bash
cd tools
go run ./cmd/query-tee -ext <extensionId> -rpc "$CHAIN_URL"
go run ./cmd/verify-deploy -a ../config/coston2/deployed-addresses.json -c "$CHAIN_URL"
```

`query-tee` lists the TEE machines registered for the extension. **More than one
active machine is a problem** — instructions are load-balanced across them, so a
stale one swallows roughly half your requests. See
[deployment-steps.md](deployment-steps.md).

## Run the test

```bash
./scripts/use-chain.sh coston2
./scripts/test.sh
```

Runs one full sealed-bid round trip: open an RFQ on chain, post two sealed quotes
straight to the proxy's `/direct`, ask the enclave to settle, relay the signed
winner back and check who was paid. The higher quote must win on price. A pass
looks like:

```
RFQ <id> open (seller 0x37F5…, reserve 2000000)
Quote 4000000 accepted by the enclave (never touched the chain)
Quote 6000000 accepted by the enclave (never touched the chain)
Enclave signed: winner 0xF275… at 6000000
Settled on chain: 0x…
All tests passed.
```

Before sending anything, `test.sh` reads the live machine address from
`/info` and points `setTeeAddress` at it — the TEE key is in enclave memory only,
so that address changes on every VM restart and a stale one reverts `settle` with
`bad TEE signature`.

The quote book lives in enclave memory, so a TEE relaunch drops the quotes held
for any open RFQ; the seller can `cancel` once the settle window has passed.

## Testing a local proxy against Coston2

The proxy must be publicly reachable for FTDC data providers to answer it. Start
the tunnel and let the scripts wire the URL in:

```bash
./scripts/full-setup.sh --chain coston2 --tunnel --test
```

That writes the tunnel URL into `.env` as `EXT_PROXY_URL`, so `post-build.sh` and
`test.sh` pick it up. Details in [cloudflared.md](cloudflared.md).

## If something's blocked

| Symptom | Cause |
|---|---|
| `pollAction` timeout, `/action/result` 404 | multiple active TEE machines; pause the stale ones |
| A direct action's result 404s although it succeeded | direct actions are tagged `submit`; `/action/result` defaults to `threshold`, so the tag has to be explicit |
| Every result reads as `status 0` | the result is wrapped in `{"result": {…}}`; reading `status` at the top level yields the zero value |
| `Verification.ChallengeExpired` | re-registration without `-command rRap` |
| `REGISTER_TEE_COMMAND=Rap` fails on a machine that was working | a VM restart minted a new machine address; it must be pre-registered first, so use `rRap` |
| `Database out of sync`, hours after a working deploy | the indexer is drifting behind the head; `new_block_check_millis = 200`, `batch_size = 20` |
| `no round` / 404 from the FTDC proxy | proxy signing policy out of sync with the on-chain reward epoch; `register-tee` pre-flights this |
| `signature must be 65 bytes, got 0` | `CHAIN_ID` unset on the node |
| `InvalidTeePublicKeyOrSignature` | node `CHAIN_ID`, proxy `chain_id` and the registry disagree — all three must say 114 |
| `bad TEE signature` from `settle` | the contract's `teeAddress` points at a machine from an earlier enclave; re-run `test.sh`, which reads it from `/info` |
| Instructions never arrive | `EXT_PROXY_URL` not reachable from outside, or a rotated tunnel URL left stale in `.env` |
| `Extension ID already set.` | `setExtensionId()` is one-shot; a redeploy is the only reset |
