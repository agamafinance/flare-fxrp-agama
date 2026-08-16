# Upstream issue drafts — Flare Foundation repos

Draft bug reports found while building and deploying this extension. **Nothing here has
been filed.** Each entry is written so it can be pasted into a GitHub issue with minimal
editing; a human should review, trim, and file them.

## Provenance and verification

These findings originate in a repo derived from `flare-foundation/fce-extension-scaffold`,
so every one was re-checked against a **fresh clone of current upstream `main`** before
being written up. Each issue states its verification status explicitly.

| Repo | Commit checked | Date |
|---|---|---|
| `flare-foundation/fce-extension-scaffold` | `e3f5879` | 2026-08-11 |
| `flare-foundation/tee-proxy` | `25003f7` | 2026-08-12 |
| `flare-foundation/tee-node` | `86f2ee6` | 2026-08-06 |
| `flare-foundation/flare-system-c-chain-indexer` | `65a3b80` | 2026-07-20 |

Deployment context for all of them: Coston2 (chain 114), `tee-node v0.0.24`,
`tee-proxy v0.0.18`, extension id 66295, extension workload on a GCP Confidential Space
VM (AMD SEV), proxy + redis + indexer on an ordinary VM.

## Summary

| # | Repo | Issue | Status |
|---|---|---|---|
| 1 | scaffold | Launch-policy label omits `CHAIN_ID`, contradicting the repo's own docs | Verified upstream |
| 2 | scaffold | No `tee.launch_policy.log_redirect` label — production image cannot emit logs | Verified upstream |
| 3 | scaffold | `register-tee` polls 30s for a result that needs a 90s FDC round | Verified upstream |
| 4 | scaffold | Direct actions parsed as `DataFixed`; handler receives an empty payload | Verified upstream, reproduced |
| 5 | scaffold | `update-tee-url.sh` calls `python`; `test-conformance.sh` breaks on bash 3.2 | Verified upstream (bash cause differs from original report) |
| 6 | tee-proxy / tee-node | Fresh init loads one signing policy, restart loads two; 404 never logged | Verified upstream, with correction |
| 7A | scaffold | Documented VPN/indexer-DB prerequisite is not real | Verified upstream (target repo corrected) |
| 7B | c-chain-indexer | `new_block_check_millis` sets a floor on tip lag that amplifies near saturation | Mechanism verified; original framing corrected |
| 7C | — | `batch_size` starves the proxy at chain head | **Disproven — do not file.** See below |
| 8 | tee-proxy | `ActionResult` is wrapped in `{"result": …}`; envelope is undocumented | Verified upstream |
| 9 | scaffold | Framework hides the arrival channel; an on-chain-only op is reachable over `/direct` | Found here; scaffold dispatch confirmed channel-blind |

---

## Issue 1 — Launch policy label omits `CHAIN_ID`, so a Confidential Space deployment cannot set it

**Target repo:** `flare-foundation/fce-extension-scaffold`

**Title:** `tee.launch_policy.allow_env_override` omits `CHAIN_ID`, which the docs list as required

**Status:** Verified against upstream `e3f5879`.

**Environment:** GCP Confidential Space (AMD SEV), Coston2, `tee-node v0.0.24`. Not
reproducible under `docker-compose`.

### What happens

On a real Confidential Space VM the workload is launched with
`tee-env-CHAIN_ID=114` in the instance metadata. The variable does not reach the node,
which comes up with `chainID=0` and signs every response against chain 0. The proxy
rejects the very first response:

```
fetching initial TEE info: verifying response signature: invalid signature
```

The scaffold's own docs describe the adjacent symptom at
`docs/deployment-steps.md:262`: *"`CHAIN_ID` must be set — unset leaves `chainID=0` and
every signature comes back empty (`signature must be 65 bytes, got 0`)"*.

This is invisible locally: `docker-compose.coston2.yaml:14` passes `CHAIN_ID` straight
into the container, where no launch policy applies.

### Why it happens

Confidential Space only forwards environment variables that the image whitelists in
`tee.launch_policy.allow_env_override`. All three language images ship the same list, and
none of them include `CHAIN_ID`:

- `python/Dockerfile:87`
- `go/Dockerfile:94`
- `typescript/Dockerfile:89`

```dockerfile
LABEL "tee.launch_policy.allow_env_override"="LOG_LEVEL,PROXY_URL,INITIAL_OWNER,EXTENSION_ID,CHAIN_URL,MODE,CONFIG_PORT,SIGN_PORT,EXTENSION_PORT"
```

`docs/extension-contract.md:230-233` specifies this exact list normatively, under the
heading "Launch policy label — required". So the contract mandates a label that makes a
documented-required variable unsettable.

By contrast, `tee-node`'s own `Dockerfile:80` does include it:

```dockerfile
LABEL "tee.launch_policy.allow_env_override"="LOG_LEVEL,PROXY_URL,INITIAL_OWNER,EXTENSION_ID,CHAIN_ID,GOVERNANCE_SIGNERS,GOVERNANCE_THRESHOLD,GOVERNANCE_SAFE,GOVERNANCE_TEE_MANAGER"
```

The label is baked into the image, so correcting it changes the code hash and forces
re-registration — which is why finding it at deploy time is expensive.

### How to reproduce

1. Build any language image unmodified.
2. Deploy to a Confidential Space VM with `tee-env-CHAIN_ID=114` in the metadata.
3. `docker inspect <image> --format '{{index .Config.Labels "tee.launch_policy.allow_env_override"}}'` — `CHAIN_ID` is absent.
4. The node reports `chainID=0`; the proxy fails on the first `/info` signature check.

### Suggested fix

Add `CHAIN_ID` to the label in all three Dockerfiles and to the normative list in
`docs/extension-contract.md:233`. Consider aligning with `tee-node`'s list more broadly —
`GOVERNANCE_SIGNERS` / `GOVERNANCE_THRESHOLD` have the same problem for anyone using
`set-governance`, since what the node signs must match what is registered on chain.

Two related notes for whoever touches that line:

- `docs/deployment-steps.md:244-249` states that Confidential Space *aborts* with
  `exit_code=4` on an env var outside the label. What we observed was the variable being
  dropped and the workload starting with `chainID=0`. Both are bad; the docs and the
  observed behaviour disagree, and it may be worth confirming which applies to the
  current launcher.
- The list includes `MODE`, which lets an operator downgrade a production image to
  simulated attestation (`MODE=1`) at launch without changing the code hash. That may be
  intentional for dev convenience, but it is worth a deliberate decision.

### Worked around here

`python/Dockerfile:98` — added `CHAIN_ID`, `GOVERNANCE_SIGNERS`, `GOVERNANCE_THRESHOLD`
to the label, and `scripts/deploy-gcp.sh` passes the matching `tee-env-*` metadata.
`MODE` was dropped from our list so the operator cannot weaken what the enclave attests
to.

---

## Issue 2 — No `tee.launch_policy.log_redirect` label, so a production image cannot emit logs

**Target repo:** `flare-foundation/fce-extension-scaffold`

**Title:** Images declare no `tee.launch_policy.log_redirect`; requesting log redirect shuts the VM down before the workload starts

**Status:** Verified against upstream `e3f5879` — no `log_redirect` label exists in
`python/Dockerfile`, `go/Dockerfile`, or `typescript/Dockerfile`.

**Environment:** GCP Confidential Space production image (non-debug), Coston2.

### What happens

Launching the VM with `tee-container-log-redirect=true` — the only way to get workload
logs off a Confidential Space VM — is refused, and the launcher does not degrade
gracefully. It logs:

```
logging redirection only allowed on debug environment by image
```

and shuts the VM down before the workload starts. Without the metadata flag the VM boots,
but the workload is then completely unobservable: no way to distinguish a crash-looping
extension from a healthy one.

### Why it happens

On a production (non-debug) Confidential Space image, log redirection must be opted into
by the image itself via the `tee.launch_policy.log_redirect` label. None of the scaffold's
images declare it, and the scaffold's docs never mention the label — `docs/` references
only `tee.launch_policy.allow_env_override`.

### How to reproduce

1. Build any language image unmodified and push it.
2. Create a Confidential Space VM with
   `--metadata="^~^tee-image-reference=<image>@<digest>~tee-container-log-redirect=true"`
   using `--image-family=confidential-space` (the production family, not `-debug`).
3. The VM terminates before the workload starts; the serial log carries the message above.

### Suggested fix

Add to all three Dockerfiles, and document it in `docs/extension-contract.md` §6
alongside the `allow_env_override` label:

```dockerfile
LABEL "tee.launch_policy.log_redirect"="always"
```

`"debugonly"` is the more conservative choice if a production image emitting logs is
considered a leak risk; either way the current state — where the documented deploy path
kills the VM — should not be the default. A note in `docs/deployment-steps.md` on which
value to pick would help, since the trade-off is a real one (the extension's own logging
discipline decides what is safe to emit).

### Worked around here

`python/Dockerfile:105` — `LABEL "tee.launch_policy.log_redirect"="always"`, with the
extension's logging restricted to counts and errors, never quote contents.

---

## Issue 3 — `register-tee` polls for 30s for a result that takes a 90s FDC round

**Target repo:** `flare-foundation/fce-extension-scaffold`

**Title:** `fccutils.ActionResult` polls ~30s, so FTDC availability-check registration times out on a healthy TEE

**Status:** Verified against upstream `e3f5879`.

### What happens

Registration reaches the FTDC availability-check step and fails with a bare status code,
on a TEE that is working correctly:

```
action result status not ok, got: 404
```

Re-running the same command later succeeds, which makes it look intermittent rather than
like a fixed timeout.

### Why it happens

`tools/pkg/fccutils/tee_calls.go:22`:

```go
const repeats = 15
```

and `tee_calls.go:92-97`:

```go
for range repeats {
    result, err = http.Get(nodeURL + "/action/result/" + actionID.Hex())
    if err == nil && result.StatusCode == http.StatusOK {
        break
    }
    time.Sleep(2 * time.Second)
}
```

15 × 2s is a 30-second budget. That is fine for an action our own TEE answers directly,
but the FTDC availability check resolves to an FDC proof, and an FDC voting round on
Coston2 is 90 seconds before it is even finalized. The poll can therefore never cover a
round, and the failure is reported as a bare 404 with nothing pointing at timing.

`registration.go:137` already acknowledges the window in a comment ("*after a wasted
on-chain tx + ~30s of polling*"), so the constant appears to have been sized for a
different class of action.

### How to reproduce

Run `register-tee` with the `a` (availability check) step against Coston2 on a healthy,
correctly-registered TEE. The poll expires before the FDC round finalizes.

### Suggested fix

Raise the budget past a full round with margin, and make the failure self-describing.
Minimum: `repeats = 180` at 1s, or 90 at 2s. Better: give `ActionResult` an explicit
timeout parameter so callers polling their own TEE keep the short budget while
FDC-backed calls get a round-length one, and on expiry return an error that names the
FDC round rather than only the HTTP status.

Two adjacent nits in the same function:

- The response body is not closed on retry iterations — only the final `result` gets a
  `defer result.Body.Close()` (`tee_calls.go:106`), and that line sits *after* the
  non-200 early return at `:102-105`, so every retried and every failed call leaks a body.
- The `time.Sleep` also runs after the final attempt, adding 2s to every failure path.

### Worked around here

`tools/pkg/fccutils/tee_calls.go:26` — `const repeats = 180`, with a comment recording the
round length as the reason.

---

## Issue 4 — Direct actions are parsed as `DataFixed`, so the handler receives an empty payload

**Target repo:** `flare-foundation/fce-extension-scaffold`

**Title:** Extension frameworks parse direct actions as `DataFixed`; payload arrives under `message`, not `originalMessage`, and is silently dropped

**Status:** Verified against upstream `e3f5879` and **reproduced against unmodified
upstream code** (transcript below). Affects the Python, TypeScript, and Go frameworks.

### What happens

Every authentic direct action — a request sent to the proxy's `POST /direct` and
forwarded to the extension — reaches the handler with an empty payload. The handler
rejects it, and the extension returns `status: 0` with a decode error that describes the
handler's own parse failure rather than the real cause. Direct actions are therefore
unusable in a scaffold-derived extension, while on-chain instructions work fine.

### Why it happens

Two different envelopes arrive at `POST /action`, distinguished by `data.type`:

- `type: "instruction"` → `data.message` is a `DataFixed`, payload under `originalMessage`
- `type: "direct"` → `data.message` is a `DirectInstruction`, payload under `message`

`tee-node` forwards the direct action verbatim
(`internal/processors/direct/default.go:40` posts the whole `*types.Action` to the
extension's `/action`), and `DirectInstruction` has no `originalMessage` field at all —
`tee-node/pkg/types/direct.go:8-12`:

```go
type DirectInstruction struct {
	OPType    common.Hash   `json:"opType"`
	OPCommand common.Hash   `json:"opCommand"`
	Message   hexutil.Bytes `json:"message"`
}
```

The frameworks never branch on `data.type` and parse everything as a `DataFixed`:

- `python/base/server.py:129` — `df = parse_data_fixed(json.loads(msg_bytes))`, then
  `:138` passes `df.original_message` to the handler. `python/base/types.py:181` defaults
  it: `original_message=raw.get("originalMessage") or "0x"`.
- `typescript/src/base/server.ts:125` and `:137` — same shape, `df.originalMessage ?? "0x"`.
- `go/internal/extension/extension.go:65` —
  `processorutils.Parse[instruction.DataFixed](action.Data.Message)`, then `df.OriginalMessage`.

The parse *succeeds*, because none of these paths reject unknown or missing fields
(`tee-node/pkg/processorutils/processutils.go:45` is a plain `json.Unmarshal`, no
`DisallowUnknownFields`). `opType` and `opCommand` are present in both envelopes, so
dispatch works and only the payload is lost — which is what makes the failure look like a
handler bug.

`tee-node` itself branches on this field in both its router
(`internal/router/router.go:274-284`) and its own dummy extension server
(`internal/testutils/extension.go:147-156`), so the distinction is established on the node
side and simply absent on the extension side.

### How to reproduce

Against unmodified upstream `python/`, identical payload and op pair, differing only in
envelope:

```python
import json, sys; sys.path.insert(0, '.')
from base.server import Server
from base.encoding import string_to_bytes32_hex
from app.handlers import register
from app.config import OP_TYPE_GREETING, OP_COMMAND_SAY_HELLO

srv = Server(0, 0, "1.0.0", register, lambda: {})
ot, oc = string_to_bytes32_hex(OP_TYPE_GREETING), string_to_bytes32_hex(OP_COMMAND_SAY_HELLO)
payload_hex = "0x" + json.dumps({"name": "Alice"}).encode().hex()
post = lambda a: srv.handle_request("POST", "/action", json.dumps(a).encode())

df = {"instructionId": "0x" + "11"*32, "opType": ot, "opCommand": oc, "originalMessage": payload_hex}
print(post({"data": {"id": "0x"+"aa"*32, "type": "instruction", "submissionTag": "threshold",
                     "message": "0x" + json.dumps(df).encode().hex()}}))

di = {"opType": ot, "opCommand": oc, "message": payload_hex}
print(post({"data": {"id": "0x"+"bb"*32, "type": "direct", "submissionTag": "",
                     "message": "0x" + json.dumps(di).encode().hex()}}))
```

Result:

```
INSTRUCTION -> status 1, data 0x7b226772656574696e67...  ("Hello, Alice! Welcome to …")
DIRECT      -> status 0, log "error: decoding request: Expecting value: line 1 column 1 (char 0)", data 0x
```

### Suggested fix

Branch on `action.data.type` before choosing the parser, in all three frameworks. For
Python, add to `base/types.py`:

```python
INSTRUCTION_ACTION = "instruction"
DIRECT_ACTION = "direct"

def parse_direct_instruction(raw: dict[str, Any]) -> DataFixed:
    """A direct action arrives as {"opType", "opCommand", "message"} — the
    DirectInstruction tee-node received on POST /direct, forwarded verbatim.
    There is no instruction id, no cosigners, no timestamp, and the payload
    lives under `message`, not `originalMessage`."""
    return DataFixed(
        instruction_id="",
        op_type=raw["opType"],
        op_command=raw.get("opCommand", ""),
        original_message=raw.get("message") or "0x",
    )
```

and dispatch on it in `server.py:_process_action`. Equivalent changes in
`typescript/src/base/server.ts` and `go/internal/extension/extension.go`.

Worth adding alongside: a conformance fixture in `testdata/conformance/` that posts a
direct action and asserts the handler sees the payload. The current 16 fixtures are all
`type: "instruction"`, which is why this passes CI. `docs/extension-contract.md` §4.2 also
documents `message` as "hex-encoded UTF-8 JSON that decodes to a DataFixed" without
mentioning the direct variant.

### Worked around here

`python/base/types.py` (`parse_direct_instruction`, `DIRECT_ACTION`) and
`python/base/server.py` (dispatch on `action.data.type`) — the diff above is the fix as
applied.

---

## Issue 5 — Script portability: `python` vs `python3`, and a bash 3.2 failure in the conformance runner

**Target repo:** `flare-foundation/fce-extension-scaffold`

**Title:** `update-tee-url.sh` invokes `python`; `test-conformance.sh` mis-reports three fixtures on bash 3.2 (stock macOS)

**Status:** Both verified against upstream `e3f5879`. **Note:** the bash problem is *not*
`${var,,}` as originally recorded — no bash-4 case-conversion expansion exists anywhere in
the repo. The real cause is different and is given below; the original characterisation
was wrong.

**Environment:** macOS with stock `/bin/bash` 3.2.57 (the only bash Apple ships).

### 5a. `update-tee-url.sh` calls `python`

`scripts/update-tee-url.sh:33` and `:40` invoke `python`, and `:17` lists it as a
requirement:

```bash
FTM=$(python -c "
XY=$(curl -sf -m 10 "$LOCAL_INFO" | python -c "
```

`python` does not exist on macOS (removed in Monterey) or on most current Linux distros,
where only `python3` is on `PATH`. Where a bare `python` does exist it may be Python 2.
Under `set -euo pipefail` (`:19`) the script dies at the first call with
`python: command not found`.

**Fix:** use `python3` at both call sites and in the requirements comment.

### 5b. `test-conformance.sh` mis-reports three fixtures on bash 3.2

`scripts/test-conformance.sh:19` sets `set -uo pipefail`. `run_fixture` builds an
argument array that is deliberately empty for GET fixtures (`:146`), then expands it
(`:157`):

```bash
local body_args=()
# ... populated only when the fixture has `body` or `raw_body`
code="$(curl -s -o "$resp_file" -w '%{http_code}' \
    -X "$method" -H 'Content-Type: application/json' \
    "${body_args[@]}" "http://127.0.0.1:$port$path" 2>/dev/null)"
```

Bash 3.2 treats `"${arr[@]}"` on an empty array as an unset variable under `set -u`; the
"empty array is not unset" behaviour arrived in bash 4.4. Minimal repro on stock macOS:

```
$ /bin/bash -c 'set -u; a=(); printf "%s\n" "${a[@]}"'
/bin/bash: a[@]: unbound variable
```

Because the expansion sits inside a command substitution, the script does **not** abort —
the subshell dies, `code` is assigned the empty string, and the run continues. The three
GET fixtures are exactly the ones with no `body` or `raw_body`, so all three fail with an
empty status, e.g. for `13-get-action-not-allowed`:

```
HTTP status: expected 405, got
```

and likewise `15-unknown-path` (expected 404) and `16-get-state` (expected 200). curl
never ran. On bash 3.2 the suite reports three failures that are an artifact of the shell
and points the reader at the extension.

**Fix:** use the bash-3.2-safe idiom, which is a no-op on bash 4+:

```bash
${body_args[@]+"${body_args[@]}"} "http://127.0.0.1:$port$path"
```

Alternatively, raise the requirement explicitly — the shebang is `#!/usr/bin/env bash`,
which silently picks up Homebrew's bash 5 when installed and stock 3.2 when not, so the
same checkout passes or fails depending on the developer's `PATH`. A version guard at the
top of the script would at least make the requirement legible.

### Worked around here

`scripts/test-conformance.sh:157` uses the `${arr[@]+"${arr[@]}"}` form;
`scripts/update-tee-url.sh` calls `python3`.

---

## Issue 6 — A freshly initialised proxy loads one signing policy where a restart loads two; the resulting 404 is never logged

**Target repo:** `flare-foundation/tee-proxy` (with a related note for `tee-node`)

**Title:** Fresh-init loads a single signing policy while restart loads two, stranding the proxy with no round for the current epoch; the rejection is a 404 with no log line

**Status:** Verified against upstream `25003f7`, **with one correction to the original
finding** — see "Correction" below.

**Environment:** Coston2, `tee-proxy v0.0.18`, self-hosted c-chain indexer,
`initial_signing_policy_offset = 0`.

### What happens

A proxy started in the wrong window serves nothing. Every instruction delivery is
rejected at the door with a 404 and no log output at any level, so from the outside the
TEE simply never receives the instruction and the extension looks dead. Restarting the
proxy alone fixes it.

### Why it happens

`internal/service/policy/policy.go:68` branches on whether the **tee-node** already holds
an initial signing policy hash — the proxy itself persists no policy state
(`METRICS.md:299`). The two branches load different numbers of policies:

**Restart path (`:68-106`) — loads two.** The code documents the reason itself (`:71-75`):

```go
// On restart the node already has policies up to lastID.
// Load lastID-1 and lastID so the instruction service's cyclic
// buffer has rounds for both the current and previous epoch
// (needed during the ~2h window when a new policy is initialized
// but the old epoch is still active).
```

ending at `:101` with `s.restartPolicies = []*cpolicy.SigningPolicy{prevPolicy, lastPolicy}`.

**Fresh-init path (`:108-125`) — loads one.** `InitializePolicyAction(...)` at `:110`
returns a single policy, assigned to `s.activePolicy` at `:119`; `restartPolicies` stays
nil.

The emission asymmetry is explicit in `Run`, `:135-145`:

```go
if s.restartPolicies != nil {
    for _, p := range s.restartPolicies {
        pChan <- *p          // two policies
    }
    s.restartPolicies = nil
} else {
    pChan <- *s.activePolicy  // one policy
}
```

Each policy becomes exactly one voting round
(`internal/service/instruction/instruction.go:180`, `StoreNewRound`). Flare initialises the
next reward epoch's signing policy roughly two hours *before* that epoch starts —
`METRICS.md:306` says as much: *"during the ~2h between a policy's on-chain initialization
and its reward epoch's start, that is the upcoming epoch, not the one currently
enforced."* A proxy that cold-starts inside that window with `offset = 0` therefore holds
a round for epoch N+1 and none for epoch N, which is the epoch every current instruction
is stamped with.

It does not self-heal. The update loop's next target is `s.activePolicy.RewardEpochID + 1`
= N+2 (`pkg/policy/policy.go:210`), which does not exist on chain for ~3.5 days; the
`!found` branch (`:221-230`) just waits.

**The rejection is silent.** `internal/service/instruction/voting/voting.go:275-278`:

```go
round, exists := s.Get(data.RewardEpochID)
if !exists {
    return nil, fmt.Errorf("%w %d", errNoRound, data.RewardEpochID)
}
```

with `errNoRound` classified as a 404 at `voting.go:30`. It propagates through
`instruction.go:117-127` (no log; metric only) to `internal/server/handler.go:112-121`:

```go
code := status.ErrToCode(err)   // 404
reason := err.Error()
if code == -1 {
    code = http.StatusInternalServerError
    reason = "internal processing error"
    logger.Warnf("error processing %s request: %s", source, err)   // the ONLY log
}
http.Error(w, reason, code)
```

The single log statement in the error path is gated on `code == -1`, so a classified 404
is written to the wire with no log line at any level. The only signal is the
`teeproxy_instructions_rejected_total{reason="no_round"}` counter, which is opt-in
(metrics default to disabled) and has no corresponding entry in
`examples/monitoring/alerts.yaml`.

### Correction to the original finding

The original phrasing was "loads only the NEWEST signing policy". That holds only when
`initial_signing_policy_offset = 0`. Fresh init actually loads `newest - offset`
(`pkg/policy/policy.go:62,73` — it requests `offset+1` logs newest-first and takes the
oldest), and upstream's default is **3** (`pkg/config/config.go:28`,
`config/config.example.toml:7`). With a non-zero offset the proxy starts behind and climbs,
so the missing round for epoch N is transient rather than permanent.

That does not make the issue go away, for two reasons. The asymmetry between the two
bootstrap paths is real and undocumented, and `internal/service/policy/` has no test file
at all. And `offset = 0` is a configuration users are actively pushed toward: the
scaffold's own local configs ship `initial_signing_policy_offset = 0`
(`config/proxy/extension_proxy.toml:4`, `extension_proxy.docker.toml:6`), and a non-zero
offset is unusable against a self-hosted indexer, because each climb needs that epoch's
`signNewSigningPolicy` transactions and the FSP pre-window backfill is log-only.

### How to reproduce

1. Point a proxy at a tee-node with no initial signing policy (fresh enclave).
2. Set `initial_signing_policy_offset = 0`.
3. Start it during the ~2h window after `SigningPolicyInitialized` for epoch N+1 has been
   emitted but before epoch N+1 begins.
4. `GET /info` reports `lastSigningPolicyId = N+1`.
5. Deliver any instruction stamped with epoch N: HTTP 404, empty proxy log.
6. Restart the proxy against the now-initialised node: it takes the two-policy path and
   the same instruction is accepted.

### Suggested fix

1. Make fresh init load the same window as restart — at minimum `newest-offset` through
   `newest`, so the cyclic buffer always holds the current epoch alongside any early
   announced one. The restart path's comment already states why two are needed; the
   reasoning applies equally to a cold start.
2. Log the rejection. A classified 4xx that means "this proxy cannot serve this epoch at
   all" should not be indistinguishable from a bad request. Either log at `Info`/`Warn`
   for `errNoRound` specifically, or lower the gate in `handler.go:118` to log all
   classified errors at debug level.
3. Consider a startup warning when the only resident policy's reward epoch is in the
   future.

### Related, in `tee-node`

When the node receives an instruction for an epoch whose policy it lacks,
`internal/policy/policy.go:85` returns `"policy of the given reward epoch not in the
storage"`. That propagates through
`internal/processors/instructions/instructions.go:107` → `preprocess` →
`processorutils.Invalid(a, err)`, which builds an `ActionResult` with `Status: 0` and the
message in `Log` (`pkg/processorutils/processutils.go:54-62`).

That is a reasonable in-band failure signal, but it is served over **HTTP 200**. Combined
with Issue 8's undocumented envelope, a caller that checks only the HTTP status code —
or that decodes `status` at the top level — reads a hard refusal as a success. Surfacing
this as a distinct status, or documenting that `result.status == 0` must always be
checked, would help.

### Worked around here

`config/proxy/` runs `initial_signing_policy_offset = 0`, and the indexer config adds an
explicit `[[indexer.collect_transactions]]` entry for
`FlareSystemsManager.signNewSigningPolicy` (`6b4c7bd6`), which FSP mode does not collect
by default. Detection is manual — comparing our proxy's `lastSigningPolicyId` against
Flare's:

```bash
curl -s "$EXT_PROXY_URL/info"                        | jq .teeInfo.lastSigningPolicyId
curl -s https://tee-proxy-coston2-1.flare.rocks/info | jq .teeInfo.lastSigningPolicyId
```

### Note for `fce-extension-scaffold`

`tools/pkg/fccutils/policy_consistency.go:22-24` gates this exact condition:

```go
func policyInSync(onchainEpoch, proxyPolicyID uint64) bool {
	return proxyPolicyID == onchainEpoch || proxyPolicyID == onchainEpoch+1
}
```

The `+1` tolerance is correct for a proxy holding *both* N and N+1, but
`LastSigningPolicyID` cannot distinguish that from a proxy holding *only* N+1 — the broken
state. The preflight therefore passes in precisely the case it exists to catch. It also
only ever checks Flare's FTDC proxy, never the operator's own.

---

## Issue 7A — Documented VPN / indexer-DB prerequisite is not real

**Target repo:** `flare-foundation/fce-extension-scaffold`
*(originally attributed to the indexer repo — corrected, see below)*

**Title:** `docs/deployment-steps.md` lists VPN access to Flare's indexer DB as a prerequisite; the indexer is self-hostable with no Flare-issued credentials

**Status:** Verified against upstream `e3f5879`.

### What happens

`docs/deployment-steps.md:12` lists among the prerequisites:

```
- VPN access to Flare's indexer DB (`35.241.249.150:3306`)
```

and the Coston/Coston2 proxy config examples ship placeholders implying credentials must
be obtained (`config/proxy/extension_proxy.coston2.toml.example:10-14`:
`host = "<indexer-db-host>"`, `username = "<indexer-db-user>"`, …). This reads as a hard
gate: a would-be extension author concludes they must request access from Flare before
they can deploy at all.

They do not. `flare-system-c-chain-indexer` is open source and fully self-hostable
against a public RPC endpoint and a local MySQL instance, with **no Flare-issued
credentials of any kind**. Verified in that repo at `65a3b80`:

- DB config is plain connection parameters with local defaults —
  `internal/config/config.go:103-115`, `config.example.toml:34-42` (`host = "localhost"`,
  `username = "root"`).
- The only API key is `NODE_API_KEY`, optional, appended to *your own* RPC provider's URL
  (`internal/config/config.go:304-317`).
- Contract addresses resolve on-chain from a registry at a fixed address, identical on all
  networks (`internal/contracts/resolver.go:15`), so not even an address list is handed
  out.
- The repo's own smoke test stands up MySQL in Docker and runs against an RPC URL
  (`test/smoke/`).

The indexer repo's own README states the prerequisites as "Go 1.24 and a running MySQL
database", with a bundled `docker-compose.yaml`.

**Correction on the target repo:** this finding was originally aimed at
`flare-system-c-chain-indexer`. That repo does not make the claim — nothing in its README,
CONTRIBUTING, or configs mentions Flare-issued database credentials. The claim lives in
the scaffold, so the issue belongs there.

**Correction on the framing:** the original note said the indexer "self-hosts in FSP
mode". Self-hosting is not an FSP-mode property — full mode is equally self-hostable and
the DB path is identical (`cmd/indexer/main.go:76` runs before the mode branch at `:91`).
What FSP mode buys is *less* indexing: hardcoded collectors plus a short full-block
window.

### Suggested fix

Reframe the prerequisite as a choice rather than a requirement — Flare's hosted indexer
if you have access, or your own via the open-source indexer — and add a short
"self-hosted indexer" path to `docs/deployment-steps.md` pointing at
`flare-system-c-chain-indexer` with a minimal working config. If VPN access remains the
recommended route, saying explicitly that it is optional would remove the gate.

Two things worth documenting on that path, because both cost real time to discover:

- The proxy refuses to serve if the indexer falls more than 60 seconds behind the chain
  (`outOfSyncTolerance`, hardcoded at `tee-proxy internal/proxy/proxy.go:35`). A
  self-hosted indexer must stay inside that window, not merely catch up eventually.
- FSP mode hardcodes collectors for Submission and Relay but not for
  `FlareSystemsManager.signNewSigningPolicy`, which is the transaction the proxy reads to
  build each new signing policy at reward-epoch rollover.

### Worked around here

`scripts/start-indexer.sh` plus `config/indexer/config.coston2.toml` run the indexer and
its database locally; the deployment has no dependency on Flare-issued credentials, and
the README says so.

---

## Issue 7B — `new_block_check_millis` sets a floor on tip lag that amplifies as per-block cost approaches the block interval

**Target repo:** `flare-foundation/flare-system-c-chain-indexer`

**Title:** Example `new_block_check_millis = 1000` can put the indexer tens of seconds behind the tip when per-block processing is slow

**Status:** Loop mechanism verified against upstream `65a3b80`. **The original framing —
"runs marginally slower than Coston2 produces blocks" — is not accurate** and should not
be filed as written; the corrected mechanism is below.

**Environment:** Coston2 (~1.8s block time) via a public RPC endpoint, consumed by
`tee-proxy v0.0.18`.

### What happens

With the example config's `new_block_check_millis = 1000`, the indexer's newest committed
block drifts steadily further behind the chain head over hours, with nothing in the log to
indicate it — the continuous loop prints no progress line and no rate. Consumers with a
freshness requirement break long after the indexer last looked healthy. In our case that
consumer is `tee-proxy`, which refuses to serve past a hardcoded 60-second tolerance
(`internal/proxy/proxy.go:35`, `outOfSyncTolerance = 1 * time.Minute`).

Lowering the value to `200` held the lag at 8-15 seconds in the same deployment.

### Why it happens

`internal/core/engine.go:477-502`:

```go
for blockNum <= ci.params.StopIndex {
    if blockNum > ixRange.end {
        time.Sleep(time.Millisecond * time.Duration(ci.params.NewBlockCheckMillis))
        ixRange, err = ci.updateLastIndexContinuous(ctx, ixRange)   // only refresh point
        ...
        continue
    }
    err = ci.indexContinuousIteration(ctx, blockNum)                // one block, no sleep
    blockNum++
}
```

`ixRange.end` — the loop's view of the chain head — is refreshed **only** inside the
caught-up branch, immediately after the sleep. So the loop alternates: sleep `P`, refresh
the tip, drain `k` blocks back-to-back at cost `T` each, repeat. The sleep is serialized
with the drain rather than overlapping it.

At equilibrium with block interval `B`, `k = P / (B - T)`, and the resulting lag is

```
lag ≈ P × B / (B − T)
```

The poll interval is thus not just an additive latency; it is *multiplied* by
`B / (B − T)`, which grows without bound as per-block processing cost `T` approaches the
block interval `B`. Against a public RPC endpoint where `T` is close to `B`, the
difference between `P = 1000` and `P = 200` is the difference between tens of seconds of
lag and a handful — which matches what we measured (60s+ at 1000, 8-15s at 200).

The loop is self-correcting in the sense that it never diverges while `T < B` — it settles
at a stable lag rather than falling behind indefinitely. But the stable lag is
proportional to `P`, and nothing surfaces it.

Two things make this hard to diagnose: the effective default when the key is absent is
`100` (`engine.go:95-97`), so the example config is 10× slower than the built-in default;
and `config.example.toml:9` describes it only as "interval for checking for new blocks",
which does not suggest any effect on steady-state lag.

### How to reproduce

Run the indexer in continuous mode against Coston2 via a public RPC with
`new_block_check_millis = 1000`, and poll `select max(number) from blocks` against the
chain head. Compare with `200` under otherwise identical conditions.

### Suggested fix

- Lower the example to `100`-`200` so it matches the code's own default, or add a comment
  stating that this value sets a floor on tip lag and should be well below the target
  chain's block time.
- Better: refresh `ixRange.end` on a ticker independent of the drain, or skip the sleep
  when the previous refresh returned new blocks, so the poll interval stops being
  serialized with per-block work.
- Log the current lag periodically in the continuous loop. Today there is no progress
  output at all, so a working sync and a stalled one are indistinguishable without
  querying the database directly.

### Worked around here

`config/indexer/config.coston2.toml:34` — `new_block_check_millis = 200`, with the
proxy's 60-second tolerance recorded as the reason.

---

## Issue 7C — `batch_size` starves the proxy at chain head — **DISPROVEN, DO NOT FILE**

The original finding held that `batch_size` doubles as the DB commit size, so the
example's `1000` means rows only land every 1000 blocks and a consumer can never see a
fresh row.

The first half is true and is upstream's own documented framing
(`internal/config/config.go:155-160`, `README.md:50`). **The consequence is wrong.**
`BatchSize` is used only in the history-catchup path — `internal/core/engine.go:176`,
`:178`, `:198`, `:236`, `:443` — and is never referenced by `IndexContinuous`. At the tip
the indexer processes one block per iteration (`engine.go:496-502`) and
`indexContinuousIteration` commits each block in its own transaction
(`engine.go:510-556` → `saveData`, `internal/core/database.go:24-76`). There is one DB
commit per block, roughly every 1.8s on Coston2.

Even during catchup the final batch is clamped to the range end
(`engine.go:198`, `lastBlockNumInRound := min(batchIx+ci.params.BatchSize-1, ixRange.end)`),
so there is no "wait for a full batch" state to be starved by.

The only accurate residual — a crash during history catchup re-processes up to
`batch_size` blocks — is already stated in the upstream README.

This repo's `batch_size = 20` is therefore harmless but not load-bearing; the real fix was
Issue 7B. This entry is kept so the claim is not re-filed later.

---

## Issue 8 — `ActionResult` is wrapped in `{"result": …}` and the envelope is undocumented

**Target repo:** `flare-foundation/tee-proxy`

**Title:** `GET /action/result/{id}` returns a signature envelope around `ActionResult`; nowhere documented, so clients read `status` at the top level and see 0

**Status:** Verified against upstream `25003f7`.

### What happens

A client that decodes the documented `ActionResult` fields at the top level of the
response silently gets zero values. `status` in particular decodes as `0`, which is the
failure value — so **every successful result reads as a rejection**, including successful
ones. There is no decode error to signal the mistake: the JSON is valid and the fields are
simply absent.

This cost us a debugging cycle in which registration aborted one step before the
availability request, reporting a TEE rejection for results that had in fact succeeded.

### Why it happens

The proxy serves the node's `ActionResponse`, not the bare `ActionResult` —
`tee-node/pkg/types/actions.go:40-44`:

```go
type ActionResponse struct {
	Result         ActionResult  `json:"result"`
	Signature      hexutil.Bytes `json:"signature"`
	ProxySignature hexutil.Bytes `json:"proxySignature"`
}
```

Served at `internal/server/external.go:140` (`GET /action/result/{actionID}`), handler
`resultH` at `:261-297`, with `ProxySignature` filled at `:286`. Wire shape:

```json
{
  "result": { "id": "0x…", "submissionTag": "…", "status": 1, "log": "",
              "opType": "0x…", "opCommand": "0x…",
              "additionalResultStatus": "0x…", "version": "…", "data": "0x…" },
  "signature": "0x…",
  "proxySignature": "0x…"
}
```

The envelope makes sense — the signatures are what make the result verifiable — but it is
documented nowhere. Checked exhaustively in the repo at `25003f7`: `README.md` documents
the ports and the `/direct` *request* body but nothing about `/action/result`;
`METRICS.md`, `CLAUDE.md`, `GOAI.md`, `CONTRIBUTING.md`, `SECURITY.md` and
`config/config.example.toml` say nothing about response shapes; there is no `docs/`
directory and no OpenAPI spec. The only mention of `ActionResponse` in any Markdown file
is `test/integration/Readme.md:32`, which refers to a `GetActionResponse()` that no longer
exists (the current function is `FetchAndVerifyActionResponse`,
`test/integration/utils/instruction_utils.go:308`) and gives no shape either way.

So the envelope is discoverable only by reading Go struct tags in a *different* repo
(`tee-node`), which a client author in another language has no reason to do.

### How to reproduce

```bash
curl -s "$PROXY_URL/action/result/0x<actionID>" | jq 'keys'
# ["proxySignature","result","signature"]
curl -s "$PROXY_URL/action/result/0x<actionID>" | jq '.status'
# null   ← a client decoding into a struct gets 0, i.e. "failed"
```

### Suggested fix

Document the response shape of `GET /action/result/{actionID}` in `README.md` — a single
annotated JSON block would do — and state that `status` lives under `result`. Fixing the
stale `GetActionResponse()` reference in `test/integration/Readme.md:32` at the same time
would help, since that is currently the only pointer a reader has.

If a broader API reference is in scope, the same treatment for `POST /direct`,
`POST /instruction` and `/info` would let clients be written without reading the Go
sources of two repos.

### Worked around here

`tools/pkg/fccutils/registration.go` — `WaitForOwnAttestationResult` decodes the envelope:

```go
var body struct {
    Result struct {
        Status uint8  `json:"status"`
        Log    string `json:"log"`
    } `json:"result"`
}
```

---

## Issue 9 — The framework hides the arrival channel from handlers, so an on-chain-only op is reachable over `/direct`

**Target repo:** `flare-foundation/fce-extension-scaffold`

**Environment:** any extension built on the scaffold that registers a handler
meant to run only for on-chain instructions (e.g. a settlement, a payout, a
state transition triggered by the extension's own contract).

### What happens

The framework dispatches purely on the `(opType, opCommand)` pair carried inside
the action's message, and never tells the handler which channel the action
arrived on. A direct action — anyone's unauthenticated `POST /direct` to the
proxy's public external server — and an on-chain instruction — emitted by the
extension's own contract and delivered through the main queue — reach the same
handler through the same call. tee-node signs *every* result, direct ones
included, with the TEE key. So any op the extension intended to be triggerable
only from its contract is in fact triggerable by anyone on the internet, and the
caller receives a TEE-signed result.

In this repo that was a confirmed, exploitable hole: an anonymous `POST /direct`
of an `RFQ/SETTLE` action made the enclave run best execution over the sealed
quote book and return the winning market maker, the exact winning price, and a
valid TEE signature — defeating the entire sealed-bid property. Any extension
with a privileged on-chain-only handler inherits the same exposure by default.

### Why it happens

`base/server.py` decides the *envelope shape* from `action.data.type`
(`direct` vs `instruction`) but then calls `framework.lookup(opType, opCommand)`
and invokes the handler regardless of that type. The handler signature carries
no channel argument, so a handler cannot refuse a channel even if it wants to.
The proxy's `validateDirect` only blocks system `F_*` op types; an
application op type passes.

### How to reproduce

Deploy any scaffold extension that has an on-chain-triggered handler. From an
unauthenticated client, `POST /direct` an action carrying that handler's
`(opType, opCommand)` and a plausible message, then `GET
/action/result/<id>?submissionTag=submit`. The handler runs and the result is
TEE-signed.

### Suggested fix

Give handlers a declared channel and enforce it at dispatch. Let
`framework.handle(...)` take an allowed-channel set (default both, so existing
extensions are unchanged), pass the arrival channel derived from
`action.data.type` into lookup, and refuse — before the handler runs — an action
whose channel the handler does not accept. A privileged handler then opts into
on-chain-only in one place. Shipping the scaffold's example with the settlement-
style handler already on-chain-only would make the safe pattern the default one.

### Worked around here

`python/base/types.py` adds `CHANNEL_DIRECT`/`CHANNEL_ONCHAIN`, a `channels`
argument to `Framework.handle`, and `lookup_for_channel`, which raises before the
handler runs; `python/base/server.py` maps `action.data.type` to the channel and
returns 403 on a mismatch; `python/app/handlers.py` registers `RFQ/SETTLE` as
on-chain-only. A `/direct` `SETTLE` now returns 403 before the book is computed.
