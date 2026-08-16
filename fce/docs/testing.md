# Testing

Tests split into two groups: those covering **your extension**, and those covering the **deployment tooling**. Cheapest first — only the last needs a chain.

## Your extension

| Layer | What it tests | How to run | Chain? |
|-------|--------------|------------|--------|
| **Unit** | Your handlers, dispatch, encoding — in your chosen language | `./scripts/test-unit.sh` | no |
| **Conformance** | The wire contract, against golden fixtures | `./scripts/test-conformance.sh` | no |
| **End-to-end** | Full instruction lifecycle (deploy → send → process → verify) | `./scripts/test.sh` | yes |

Both script-driven layers accept a language or `--all`:

```bash
./scripts/test-unit.sh python
```

```bash
./scripts/test-conformance.sh --all
```

They dispatch through `LANGUAGE_TEST_CMD` in each `<lang>/language.env`, so they work for any language you add without modification.

### Conformance testing

This is the layer that keeps multiple implementations honest, and the acceptance test for a new language.

`scripts/test-conformance.sh` starts **only the extension process** — no tee-node, no proxy, no chain, no Docker — replays the 10 fixtures in `testdata/conformance/`, and diffs every response field. The response payload is compared **byte-for-byte**, because tee-node hashes it and signs the result.

```bash
./scripts/test-conformance.sh --all
```

It runs in seconds, which is what makes writing a new language port tractable: a correctness signal without a full deploy cycle.

The fixtures are **order-dependent** and share one process — counters accumulate across cases and the final fixture asserts the resulting state. `index.json` fixes the order.

If you change a request or response shape, regenerate rather than hand-editing:

```bash
./python/.venv/bin/python testdata/conformance/gen_fixtures.py
```

Fixtures are generated from `gen_fixtures.py` so the hex encodings are derived rather than hand-assembled. Adding a case is a code edit there.

> When this suite disagrees with your implementation, check [extension-contract.md](extension-contract.md) before changing the fixture. The contract is normative; the fixtures encode it.

## The deployment tooling

`tools/` is a standalone Go module with no dependency on any language implementation — which is what lets one deployment and test path serve Go, Python and TypeScript alike. It has its own tests.

| Layer | What it tests | How to run |
|-------|--------------|------------|
| **Unit tests** | Revert decoding, state file I/O, env parsing, validation, report formatting | `cd tools && go test ./...` |
| **Integration tests** | On-chain constructor validation, revert reasons, idempotent registration, pre-flight checks | `cd tools && go test -tags integration ./integration/ -v` |

### Tooling unit tests

These require no external services. They cover:

- **Revert reason decoding** (`tools/pkg/fccutils/revert_test.go`) — Verifies `decodeRevertHex` and `DecodeRevertReason` correctly decode ABI-encoded `Error(string)` reverts, including all 7 revert messages from `InstructionSender.sol`. Also tests edge cases: nil errors, wrapped errors, custom error selectors, invalid hex, short data.
- **Support revert decoding** (`tools/pkg/support/support_test.go`) — Tests `decodeRevertFromError` which extracts revert reasons from go-ethereum JSON-RPC error types.
- **State file I/O** (`tools/pkg/fccutils/registration_test.go`) — Tests `loadState`/`saveState` for the TEE machine registration resume flow: missing files, valid/invalid JSON, overwrite behavior, roundtrip consistency, read-only directories.
- **Validation checks** (`tools/pkg/validate/checks_test.go`) — Extension env format validation, deployer key source detection, service/registration/TEE check functions with various config states.
- **Report formatting** (`tools/pkg/validate/report_test.go`) — Report summary, JSON output, colored terminal output, empty reports, unknown statuses.
- **Validation primitives** (`tools/pkg/validate/validate_test.go`) — `AddressNotZero`, `AddressHasCode`, `KeyHasFunds`, `IsUsingDevKey` with nil clients, zero addresses, edge cases.

```bash
cd tools && go test ./... -v
```

### Tooling integration tests

Integration tests run against a live Ethereum node (Hardhat, Anvil, or Coston2). They are excluded from `go test ./...` via the `integration` build tag.

**What they test:**

- **Constructor validation** — Deploys `InstructionSender` with zero addresses, EOA addresses, and valid addresses. Verifies revert messages are decoded correctly (not binary garbage).
- **setExtensionId errors** — Calls `setExtensionId` before registration ("Extension ID not found.") and after it's already set ("Extension ID already set."). Verifies the full revert decoding chain works: `DecodeRevertReason` → `SimulateAndDecodeRevert` fallback.
- **CheckTx revert reasons** — Submits transactions that revert on-chain (with manual gas limit to bypass estimation), then verifies `CheckTx` replays the call and returns human-readable revert reasons.
- **Idempotent registration** — Runs `SetupExtension` twice with the same instruction sender address. Verifies the second run detects the existing registration and returns the same extension ID without submitting duplicate transactions.
- **Pre-flight validation** — Tests `AddressHasCode` against deployed registry contracts and random EOAs. Tests `KeyHasFunds` against the funded deployer and unfunded random keys.

**Running against a local node:**

```bash
cd tools && go test -tags integration ./integration/ -v -count=1
```

Defaults: `CHAIN_URL=http://127.0.0.1:8545`, addresses file at `config/coston2/deployed-addresses.json`.

**Running against Coston2:**

```bash
cd tools && CHAIN_URL=https://coston2-api.flare.network/ext/C/rpc \
  DEPLOYMENT_PRIVATE_KEY=<your-funded-key> \
  go test -tags integration ./integration/ -v -count=1
```

**Environment variables:**

| Variable | Default | Description |
|----------|---------|-------------|
| `CHAIN_URL` | `http://127.0.0.1:8545` | RPC endpoint |
| `ADDRESSES_FILE` | `../../config/coston2/deployed-addresses.json` | Path to deployed registry addresses |
| `DEPLOYMENT_PRIVATE_KEY` | Hardhat dev key | Funded private key for deployments and transactions |

**Note:** Integration tests deploy fresh contracts on each run. On Coston2, this costs gas. On a local node, it's free.

## End-to-End Tests

After post-build completes, run the round trip against the deployed extension:

```bash
./scripts/test.sh
```

Or run everything in one shot:

```bash
./scripts/full-setup.sh --test
```

## What the test does

The test runner (`tools/cmd/run-test/main.go`) drives one full confidential RFQ against a deployed extension:

1. **Bind the contract.** `setExtensionId()` (idempotent), then `setTeeAddress` from the live proxy's `/info` — the TEE key is in enclave memory, so the machine address changes on every VM restart.
2. **Open an RFQ.** The seller approves and escrows 100 YT against a 2 FXRP reserve. Each run hands that escrow to the winner, and YT has no open mint, so the test mints FXRP and splits it when the seller runs short.
3. **Fund a market maker.** Derived deterministically from the tooling key, because the enclave refuses a quote signed by the RFQ's own seller. It gets gas, FXRP for the premium, and the approval `settle` will need.
4. **Post two sealed quotes** — 4 and 6 FXRP — to the proxy's `/direct`, each signed over the same `quoteDigest` preimage the contract exposes. Neither touches the chain.
5. **Request settlement** on chain, poll the result, and check that the enclave picked the 6 FXRP quote.
6. **Relay it.** `settle(result, signature)` verifies the TEE signature, the reserve and the USD premium band before it moves anything.

No stored result at step 4 means one of two things: the enclave rejected the quote — its reason stays inside the enclave, in the extension log — or this TEE is not registered yet, so run `post-build.sh`.

## Two things that make a passing run look like a failure

### Direct actions are tagged `submit`

`/action/result/<id>` defaults to the `threshold` tag, so a quote that completed fine 404s unless the tag is explicit: `/action/result/<id>?submissionTag=submit`.

### The result is wrapped

The proxy returns the `ActionResult` under `result`, beside the node and proxy signatures:

```json
{
  "result": {
    "id": "0x...",
    "status": 1,
    "log": "",
    "opType": "0x...",
    "opCommand": "0x...",
    "data": "<the extension's response bytes>"
  },
  "signature": "0x...",
  "proxySignature": "0x..."
}
```

- `status`: `0` = failed, `1` = success, `2` = pending
- `log`: error message when `status == 0`
- `data`: whatever the handler returned via `buildResult`

Decoding `status` at the top level silently yields the zero value — failure — so every result reads as a rejection, including the successful ones. Decode `result` (`types.ActionResponse` in tee-node's `pkg/types`, or the inline struct in `directResult`).

## Matching op types between Solidity and the extension

The contract defines the identifiers it sends as `bytes32` constants:

```solidity
bytes32 public constant OP_TYPE_RFQ = bytes32("RFQ");
bytes32 public constant OP_COMMAND_SETTLE = bytes32("SETTLE");
```

The extension registers the pairs up front and lets the framework dispatch:

```python
framework.handle(OP_TYPE_RFQ, OP_COMMAND_QUOTE, handle_quote)
framework.handle(OP_TYPE_RFQ, OP_COMMAND_SETTLE, handle_settle)
```

Both sides compare the same bytes32 encoding — the UTF-8 string right-padded with zeros to 32 bytes. **The strings must match exactly**; a mismatch is not a compile error, it silently falls through to "unsupported op type" (HTTP 501) at runtime.

`QUOTE` has no constant in the contract, by design: a quote only ever arrives as a direct action, so the chain never learns it existed.

## Where the assertions live

| What | Where |
|------|-------|
| RFQ terms the test uses (YT amount, reserve, the two bids) | the constants at the top of `tools/cmd/run-test/main.go` |
| The quote digest preimage, pinned across languages | `test/vectors/quote_digest.json`, replayed by `test/AgamaRfq.t.sol` and recomputed in `run-test` |
| What the contract refuses to trust | `test/AgamaRfq.t.sol` |
| The matcher's guarantees | `python/tests/` |
| The wire contract | `testdata/conformance/`, regenerate with `testdata/conformance/gen_fixtures.py` |
