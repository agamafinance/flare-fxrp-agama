#!/usr/bin/env bash
#
# start-indexer.sh — run our own C-chain indexer for the extension proxy.
#
# The proxy reads FSP data (signing policies, voter registrations, recent voting
# rounds) from a C-chain indexer database. Flare issues credentials to a hosted
# one on request; this runs the same open-source indexer locally instead, so the
# deployment does not depend on anyone else's database.
#
# Usage:
#   ./scripts/start-indexer.sh          # clone if needed, build, start, wait for sync
#   ./scripts/start-indexer.sh --logs   # follow the indexer log
#   ./scripts/start-indexer.sh --stop   # stop it (the synced data volume survives)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_NAME="$(basename "$PROJECT_DIR")"

INDEXER_REPO="${INDEXER_REPO:-https://github.com/flare-foundation/flare-system-c-chain-indexer.git}"
INDEXER_REF="${INDEXER_REF:-main}"
SRC_DIR="$PROJECT_DIR/.indexer-src"

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
log() { echo -e "${GREEN}[indexer]${NC} $*"; }
die() { echo -e "${RED}[indexer] ERROR:${NC} $*" >&2; exit 1; }

if [[ -f "$PROJECT_DIR/.env" ]]; then
    set -a; source "$PROJECT_DIR/.env"; set +a
fi

compose() {
    docker compose -p "$PROJECT_NAME" -f "$PROJECT_DIR/docker-compose.indexer.yaml" "$@"
}

case "${1:-}" in
    --stop) compose stop; exit 0 ;;
    --logs) compose logs -f c-chain-indexer; exit 0 ;;
    -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
esac

command -v docker >/dev/null || die "docker is required"

if [[ ! -d "$SRC_DIR" ]]; then
    log "cloning the indexer ($INDEXER_REF)"
    git clone --depth 1 --branch "$INDEXER_REF" "$INDEXER_REPO" "$SRC_DIR" >/dev/null 2>&1 \
        || die "could not clone $INDEXER_REPO"
fi

log "starting indexer-db + c-chain-indexer"
compose up -d --build

# The proxy panics if the indexer is behind, so wait for the first blocks rather
# than letting the next script fail on a cold database.
log "waiting for the first indexed blocks (a cold start takes a few minutes)"
deadline=$(( $(date +%s) + 900 ))
while :; do
    blocks="$(compose exec -T indexer-db mysql -uindexer -pindexer -N -B \
        -e 'select count(*) from flare_ftso_indexer.blocks' 2>/dev/null | tr -d '[:space:]' || true)"
    if [[ "$blocks" =~ ^[0-9]+$ && "$blocks" -gt 0 ]]; then
        log "indexed $blocks blocks — the proxy can start"
        break
    fi
    if (( $(date +%s) > deadline )); then
        echo "" >&2
        compose logs --tail 30 c-chain-indexer >&2
        die "the indexer produced no blocks in 15 minutes — see the log above"
    fi
    sleep 10
done

log "point the proxy at it: host indexer-db, db flare_ftso_indexer, user/password indexer"
