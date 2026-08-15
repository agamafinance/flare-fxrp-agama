#!/usr/bin/env bash
#
# verify-registration.sh — does the chain agree with the live TEE?
#
# Prints, side by side, what the running node reports and what the FlareTeeManager
# holds. Every line must match, and the machine status must be 2 (production).
# When registration stalls, this says in one screen whether the fault is on this
# side or waiting on Flare's FTDC.
#
# Usage: ./scripts/verify-registration.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; NC='\033[0m'
ok()   { echo -e "  ${GREEN}✓${NC} $*"; }
bad()  { echo -e "  ${RED}✗${NC} $*"; }
warn() { echo -e "  ${YELLOW}!${NC} $*"; }

set -a; source "$PROJECT_DIR/.env"; set +a
[[ -f "$PROJECT_DIR/config/extension.env" ]] && { set -a; source "$PROJECT_DIR/config/extension.env"; set +a; }

RPC="${CHAIN_URL:?CHAIN_URL not set}"
PROXY="${EXT_PROXY_URL:?EXT_PROXY_URL not set}"
EXT_ID_DEC=$((EXTENSION_ID))
FTM=$(python3 -c "
import json,sys
print(next(e['address'] for e in json.load(open(sys.argv[1])) if e['name']=='FlareTeeManager'))
" "$PROJECT_DIR/$ADDRESSES_FILE")

echo "extension $EXT_ID_DEC · FlareTeeManager $FTM"
echo

# --- the live node's view ---------------------------------------------------
INFO=$(curl -sf -m 20 "$PROXY/info") || { bad "the proxy at $PROXY did not answer"; exit 1; }
read -r LIVE_TEE LIVE_CODEHASH LIVE_PLATFORM LIVE_EXT <<<"$(echo "$INFO" | python3 -c "
import sys, json, hashlib
d = json.load(sys.stdin)
k = d['teeInfo']['publicKey']
m = d.get('machineData', {})
plat = m.get('platform','') or ''
plat = bytes.fromhex(plat[2:]).decode().rstrip('\x00') if plat.startswith('0x') else plat
print(k['x'][2:] + k['y'][2:], m.get('codeHash'), plat, m.get('extensionId'))
")"
LIVE_TEE=0x$(cast keccak "0x$LIVE_TEE" | tail -c 41)

# --- the chain's view -------------------------------------------------------
RECORD=$(cast call "$FTM" 'getTeeMachine(address)((address,address,string))' "$LIVE_TEE" --rpc-url "$RPC" 2>/dev/null)
CHAIN_URL_REC=$(echo "$RECORD" | sed -E 's/.*"(.*)".*/\1/')
STATUS=$(cast call "$FTM" 'getTeeMachineStatus(address)(uint8)' "$LIVE_TEE" --rpc-url "$RPC" 2>/dev/null)
SENDER=$(cast call "$FTM" 'getTeeExtensionInstructionsSender(uint256)(address)' "$EXT_ID_DEC" --rpc-url "$RPC" 2>/dev/null)
ACTIVE=$(cast call "$FTM" 'getActiveTeeMachines(uint256)(address[],string[])' "$EXT_ID_DEC" --rpc-url "$RPC" 2>/dev/null | head -1)

echo "machine $LIVE_TEE"
# Compare case-insensitively: cast returns checksummed addresses, keccak gives lowercase.
lower() { tr '[:upper:]' '[:lower:]'; }
RECORD_L=$(printf '%s' "$RECORD" | lower)
[[ "$RECORD_L" == *"$(printf '%s' "$LIVE_TEE" | lower)"* ]] \
  && ok "registered on chain" || bad "not registered on chain"
[[ "$CHAIN_URL_REC" == "${PROXY%/}" ]] \
  && ok "url matches: $CHAIN_URL_REC" \
  || bad "url mismatch — chain says '$CHAIN_URL_REC', proxy is '$PROXY' (fix: ./scripts/update-tee-url.sh)"
[[ "$LIVE_PLATFORM" == "GCP_AMD_SEV" ]] \
  && ok "attested on real hardware ($LIVE_PLATFORM)" \
  || warn "platform is $LIVE_PLATFORM — simulated attestation, FTDC will reject it"
[[ "$LIVE_CODEHASH" == "0x194844cf417dde867073e5ab7199fa4d21fd82b5dbe2bdea8b3d7fc18d10fdc2" ]] \
  && warn "code hash is the simulated one" \
  || ok "code hash measured: $LIVE_CODEHASH"

echo
echo "extension $EXT_ID_DEC"
# bash 3.2 (stock macOS) has no ${var,,} — the same trap this repo reports upstream.
[[ "$(printf '%s' "$SENDER" | lower)" == "$(printf '%s' "${INSTRUCTION_SENDER:-}" | lower)" ]] \
  && ok "instruction sender matches config/extension.env" \
  || bad "chain says $SENDER, config says ${INSTRUCTION_SENDER:-unset}"
[[ "$LIVE_EXT" == "$EXTENSION_ID" ]] \
  && ok "the node is running under this extension id" \
  || bad "the node reports $LIVE_EXT"

echo
case "$STATUS" in
  2) ok "status 2 — in production" ;;
  1) warn "status 1 — registered, not promoted."
     echo "     Everything above being green means the missing piece is the FTDC availability"
     echo "     proof, which Flare's data providers publish. Retry: REGISTER_TEE_COMMAND=Rap ./scripts/post-build.sh" ;;
  *) bad "status ${STATUS:-unknown}" ;;
esac
[[ "$ACTIVE" == "[]" ]] && warn "no active machine for this extension yet" || ok "active machines: $ACTIVE"
