# Getting started — local

Runs the extension end to end on a local devnet: deploy
`AgamaRfqInstructionSender`, register the extension, start the TEE node + proxy,
and run one sealed-bid round trip through it.

## Prerequisites

| Need | Why |
|---|---|
| Docker + Compose | runs the extension TEE, proxy and redis |
| Go 1.25+ | the `tools/` CLIs: deploy, register, and the round-trip test |
| Foundry (`forge`, `cast`) | compiles `contracts/`, reads chain state |
| Python 3.11+ | the extension itself, and its unit tests |
| A funded key | deploys contracts and registers the extension |
| FCC infrastructure running | Hardhat node + indexer + redis + the "normal" TEE proxy. Not in this repo |

## The implementation

This repo ships one implementation, in Python. Discovery is by directory: each
implementation carries a `<lang>/language.env` manifest, and `LANGUAGE` in `.env`
selects it — here, `python`. See [languages.md](languages.md).

## One command

```bash
cp .env.example .env        # then set DEPLOYMENT_PRIVATE_KEY and CHAIN_ID
./scripts/full-setup.sh --test
```

That chains pre-build (deploy + register) → start-services (node, proxy, redis) →
post-build (allow version, set governance, register TEE) → `test.sh`.

For Coston2, add a tunnel so the proxy is publicly reachable:

```bash
./scripts/full-setup.sh --chain coston2 --tunnel --test
```

## Verify it works

```bash
docker compose ps                      # redis, ext-proxy, extension-tee
curl -s http://localhost:6674/info     # extension id, code hash, platform
./scripts/test.sh                      # one sealed-bid round trip
```

A passing run opens an RFQ, gets two sealed quotes accepted by the enclave,
settles at the higher of the two and ends on `All tests passed.`

## Configuration

Everything lives in `.env` (start from `.env.example`); per-chain copies go in
`.env.<chain>` and `use-chain.sh` activates them.

| Var | Default | Note |
|---|---|---|
| `LANGUAGE` | `python` | which implementation directory gets built |
| `DEPLOYMENT_PRIVATE_KEY` | Hardhat dev key | funded deployer |
| `CHAIN_URL` / `CHAIN_ID` | `http://127.0.0.1:8545` | `CHAIN_ID` is **required** — unset leaves `chainID=0` and every TEE signature comes back empty |
| `SIMULATED_TEE` | `true` | `true` on a laptop, **`false`** on real Confidential hardware |
| `EXT_PROXY_URL` | `http://localhost:6674` | this extension's proxy; must be publicly reachable on testnets |
| `NORMAL_PROXY_URL` | `http://localhost:6662` | the infrastructure FTDC proxy (post-build) |
| `ADDRESSES_FILE` | auto-detected | path to `deployed-addresses.json` |
| `EXTENSION_ID` | from `config/extension.env` | bytes32 hex, written by pre-build |
| `INSTRUCTION_SENDER` | from `config/extension.env` | contract address, written by pre-build |
| `INITIAL_OWNER` | derived from the deployer key | initial contract owner |
| `PROXY_PRIVATE_KEY` | Hardhat dev key | proxy signing key |
| `EXTENSION_OWNER_KEY` | falls back to `DEPLOYMENT_PRIVATE_KEY` | key override for `allow-tee-version` |
| `TEE_VERSION` | `v0.1.0` | version string for TEE registration |
| `GOVERNANCE_SIGNERS` | `INITIAL_OWNER` | comma-separated 0x addresses — see below |
| `GOVERNANCE_THRESHOLD` | `1` | minimum distinct governance signatures |
| `WAIT_TIMEOUT` | `120` | service wait timeout, seconds |
| `REGISTRY` | (unset) | pull images from a remote registry instead of building |
| `LOG_LEVEL` | `INFO` | `DEBUG` for verbose container logs |

### TEE governance

Every TEE machine registers under a **governance** — a signer set plus a threshold
that authorises governance actions for the extension. Two parties must agree on it or
`register-tee` reverts with `InvalidGovernanceHash`: the **TEE node**, which signs its
machine data with a `governanceHash` derived from `(signers, threshold)`, and the
**on-chain registry** where the governance is registered.

The scaffold keeps them consistent by reading both from `.env`:

```bash
GOVERNANCE_SIGNERS="0xAbc...,0xDef..."   # comma-separated 0x addresses
GOVERNANCE_THRESHOLD=2
```

Unset, both default to the deployer as sole signer, threshold 1 — fine for
development. `post-build.sh` registers the set on-chain idempotently before
`register-tee`, and passes the same values to the node container via Compose.

## Ports

| Port | What |
|---|---|
| 6674 | extension proxy, external (Docker) |
| 6664 | extension proxy when run as a local Go process (`--local`) |
| 6662 | the "normal" FTDC proxy (infrastructure, not this repo) |
| 6382 | this extension's redis |

## Stopping

```bash
./scripts/stop-services.sh --chain local
./scripts/stop-services.sh --chain coston2 --tunnel   # also stops the tunnel
```

## Common failures

| Symptom | Cause |
|---|---|
| `config/proxy/extension_proxy.<chain>.docker.toml not found` | it is gitignored; copy the `.example` and fill in the `[db]` credentials |
| docker `rootfs` mount error, or the path is now a directory | an older run mounted the missing config; `rm -rf` the directory, then copy the `.example` |
| `tee-node v… is below the v0.0.22 minimum` | bump the pin in `tools/go.mod`, the only `go.mod` this repo ships |
| `tee-node mismatch` from `check-versions.sh` | a second `go.mod` was added and the pins drifted; align them or the images and the tooling run different builds |
| `--chain` seems ignored | `.env` is sourced after flag parsing, so `CHAIN` in `.env` wins |
| `signature must be 65 bytes, got 0` | `CHAIN_ID` unset → `chainID=0` |
| `Verification.ChallengeExpired` | `register-tee` ran without `-command rRap` |
| `InvalidGovernanceHash` | `GOVERNANCE_SIGNERS` / `GOVERNANCE_THRESHOLD` differ between `post-build.sh` and the node container |
| `Extension ID already set.` | `setExtensionId()` is one-shot; redeploy the `InstructionSender` |
| `EXTENSION_ID … not found in proxy /info` | the proxy is filtering for a different extension |
| proxy `/info` wait times out on a testnet | `EXT_PROXY_URL` is not reachable from outside — start a tunnel ([cloudflared.md](cloudflared.md)) |
| `pollAction` timeout / `/action/result` 404 | more than one active TEE machine; see [deployment-steps.md](deployment-steps.md) |
