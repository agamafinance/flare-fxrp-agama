# Architecture

Agama's sealed-bid RFQ for yield tokens, running as a Flare Compute Extension.
Market makers' quotes never reach the chain: each one is signed and sent straight
to the enclave, matching runs inside attested hardware, and only the signed
winning settlement comes back out for the contract to verify.

## Components

| Piece | Where | Role |
|---|---|---|
| `AgamaRfqInstructionSender` | `contracts/InstructionSender.sol` | escrows the YT, holds the RFQ lifecycle, verifies the TEE signature before it moves a token |
| Extension | `python/` | `app/handlers.py` (the two handlers), `app/quotes.py` (quote authentication, the in-enclave book, best execution), `app/chain.py` (the reads made inside the enclave) |
| tee-node | pinned in `tools/go.mod` | runs inside the TEE, signs responses, talks to the proxy |
| tee-proxy | `proxy/Dockerfile` | bridges TEE ↔ chain/FTDC; serves `/info`, `/direct` and `/action/result` |
| redis | compose service | the proxy's queue |
| C-chain indexer | `scripts/start-indexer.sh` | the FSP data the proxy verifies against, self-hosted so no Flare credentials are needed |
| Deployment tooling | `tools/cmd/*` | deploy, register, allow versions, query state, run the round trip |

On-chain the extension is identified by an **extension id**, assigned by
`TeeExtensionRegistry` and latched into the contract by `setExtensionId()`.

## Request flow

Two channels in, one out.

```
market maker ──POST /direct (RFQ/QUOTE)──▶ proxy ──▶ TEE ─┐  book in enclave memory
                                                          │
seller ──openRfq──▶ AgamaRfqInstructionSender (escrows YT) │
       ──requestSettlement──▶ registry ──▶ data providers ─┤
                                                          │
                              best execution ─────────────┘
                                          │
                            signed winning settlement
                                          │
anyone ──settle(result, sig)──▶ contract verifies the TEE signature, then pays
```

The node signs every response against `CHAIN_ID`; a mismatch with the proxy's
`chain_id` or the on-chain registry fails verification. The contract accepts a
settlement only from the machine set with `setTeeAddress`, and re-checks the
seller's reserve and the USD premium band before it moves anything.

## Op codes

Instructions carry an op type and an op command, hashed to `bytes32`. The
Solidity side and the handler must agree on the string.

| Op | Channel | Handler | Response |
|---|---|---|---|
| `RFQ` / `QUOTE` | direct action, never on chain | `handle_quote` | accepted or rejected — nothing about the quote itself |
| `RFQ` / `SETTLE` | on-chain instruction from `requestSettlement` | `handle_settle` | the winning settlement, ABI-encoded and signed by the node |

Defined in `contracts/InstructionSender.sol` and `python/app/config.py`. An
unmatched pair is not a compile error: it falls through to "unsupported op type"
(HTTP 501) at runtime.

## State

The quote book lives in `app/quotes.py`, in enclave memory, and never leaves it.
`GET /state` reports counts only — never a price, never a market maker — and a
settled RFQ's quotes are dropped. Nothing is persisted, so a relaunch loses the
book **and mints a new `teeId`**; see [deployment-steps.md](deployment-steps.md).

## Language layout

This extension ships Python only, but the repo root stays language-agnostic. The
implementation is discovered through `python/language.env`, which declares the
Dockerfile plus the setup / build / test / run commands, and the scripts glob
`*/language.env` rather than holding a list. The Python image runs the tee-node
binary beside the handler — `docker/node-base.Dockerfile` builds it — where a Go
implementation would link tee-node as a library. See [languages.md](languages.md)
and [extension-contract.md](extension-contract.md).

## Entry points

| Script | Does |
|---|---|
| `pre-build.sh` | generate bindings, compile, deploy `AgamaRfqInstructionSender`, register the extension |
| `start-indexer.sh` | our own C-chain indexer and its database |
| `start-services.sh` | build + start node/proxy/redis, sync the tunnel on testnets |
| `post-build.sh` | allow the TEE version, set governance, register and promote the TEE machine |
| `test.sh` | one full sealed-bid round trip against a running deployment |
| `verify-registration.sh` | print the live node's view beside the `FlareTeeManager` record |
| `deploy-gcp.sh` | Confidential Space VM for the extension, an ordinary VM for the rest |
| `full-setup.sh` | pre-build, start-services and post-build in order |
| `check-versions.sh` | fails the build when dependency pins drift or fall below the floor |

## Version pinning

`tools/go.mod` carries the tee-node and tee-proxy pins;
`scripts/lib/versions.sh` derives `TEE_NODE_REF` from it so the image builds the
same ref that the tooling links, and `check-versions.sh` enforces that plus the
minimum version.

## Where to look next

[getting-started.md](getting-started.md) to run it ·
[extension-guide.md](extension-guide.md) to write your own handler ·
[deployment-steps.md](deployment-steps.md) for Coston2
