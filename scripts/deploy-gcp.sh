#!/usr/bin/env bash
#
# deploy-gcp.sh — put the extension in a real TEE and everything else beside it.
#
# Two machines, because they have different jobs:
#
#   agama-fce-tee      GCP Confidential Space (AMD SEV). Runs ONLY the extension
#                      image. This is the machine whose code hash is attested and
#                      whitelisted on chain; the quote book lives in its memory.
#   agama-fce-support  An ordinary VM: redis, the extension proxy, MySQL and the
#                      C-chain indexer. None of it is confidential — the proxy
#                      sees opaque action bodies — so it does not belong in the TEE.
#
# The TEE reaches the proxy on the internal network (:6663); Flare's data providers
# reach it on the public one (:6664).
#
# Usage:
#   gcloud auth login                 # once, interactively
#   ./scripts/deploy-gcp.sh           # build, push, create both VMs, wire them up
#   ./scripts/deploy-gcp.sh --info    # print the proxy URL, code hash and teeId
#   ./scripts/deploy-gcp.sh --destroy # delete both VMs (the contracts stay on chain)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

REGION="${REGION:-us-central1}"
ZONE="${ZONE:-us-central1-a}"
TEE_VM="${TEE_VM:-agama-fce-tee}"
SUPPORT_VM="${SUPPORT_VM:-agama-fce-support}"
REPO="${AR_REPO:-agama}"

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "${GREEN}[gcp]${NC} $*"; }
step() { echo -e "\n${CYAN}=== $* ===${NC}"; }
die()  { echo -e "${RED}[gcp] ERROR:${NC} $*" >&2; exit 1; }

command -v gcloud >/dev/null || die "gcloud is required"
command -v docker >/dev/null || die "docker is required"

if [[ -f "$PROJECT_DIR/.env" ]]; then
    set -a; source "$PROJECT_DIR/.env"; set +a
fi

PROJECT_ID="${PROJECT_ID:-$(gcloud config get-value project 2>/dev/null)}"
[[ -n "$PROJECT_ID" && "$PROJECT_ID" != "(unset)" ]] || die "set PROJECT_ID or run: gcloud config set project <id>"
IMAGE="$REGION-docker.pkg.dev/$PROJECT_ID/$REPO/agama-fce-extension"

support_ip() { gcloud compute instances describe "$SUPPORT_VM" --zone="$ZONE" --format='value(networkInterfaces[0].networkIP)' 2>/dev/null; }
support_public_ip() { gcloud compute instances describe "$SUPPORT_VM" --zone="$ZONE" --format='value(networkInterfaces[0].accessConfigs[0].natIP)' 2>/dev/null; }

case "${1:-}" in
    --info)
        ip="$(support_public_ip)" || die "no support VM"
        log "proxy: http://$ip:6664"
        curl -s --max-time 20 "http://$ip:6664/info" | jq '.machineData | {extensionId, codeHash, platform, initialOwner}' 2>/dev/null \
            || die "the proxy did not answer — check: gcloud compute ssh $SUPPORT_VM --zone=$ZONE --command 'docker logs agama-fce-ext-proxy-1'"
        exit 0 ;;
    --destroy)
        gcloud compute instances delete "$TEE_VM" "$SUPPORT_VM" --zone="$ZONE" --quiet
        exit 0 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
esac

[[ -f "$PROJECT_DIR/config/extension.env" ]] \
    || die "config/extension.env is missing — run ./scripts/pre-build.sh first (it needs a funded key)"
# shellcheck source=/dev/null
source "$PROJECT_DIR/config/extension.env"

step "Project $PROJECT_ID, zone $ZONE"
gcloud config set project "$PROJECT_ID" >/dev/null
gcloud services enable confidentialcomputing.googleapis.com compute.googleapis.com artifactregistry.googleapis.com >/dev/null

# The Confidential Space VM's service account must pull the image and reach the
# attestation service; without workloadUser the launcher gets no token.
SA="$(gcloud iam service-accounts list --format='value(email)' --filter='displayName~Compute' | head -1)"
[[ -n "$SA" ]] || die "no compute service account found"
for role in artifactregistry.reader logging.logWriter confidentialcomputing.workloadUser; do
    gcloud projects add-iam-policy-binding "$PROJECT_ID" --member="serviceAccount:$SA" --role="roles/$role" >/dev/null
done

step "Build and push the extension image (MODE=0, real attestation)"
gcloud artifacts repositories create "$REPO" --repository-format=docker --location="$REGION" 2>/dev/null || true
gcloud auth configure-docker "$REGION-docker.pkg.dev" -q >/dev/null

# The base image carries the tee-node binary the Python image copies in.
"$SCRIPT_DIR/build-node-base.sh"

# MODE=0 is baked here rather than overridden at launch, so the code hash on chain
# belongs to an image that can only run production attestation.
SOURCE_DATE_EPOCH="$(git -C "$PROJECT_DIR" log -1 --format=%ct)"
TEE_NODE_REF="$(bash -c "source '$SCRIPT_DIR/lib/versions.sh'; load_versions '$PROJECT_DIR'; echo \$TEE_NODE_REF")"
docker build --platform linux/amd64 \
    -f "$PROJECT_DIR/python/Dockerfile" \
    --build-arg SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH" \
    --build-arg TEE_NODE_REF="$TEE_NODE_REF" \
    -t "$IMAGE:latest" "$PROJECT_DIR"
docker push "$IMAGE:latest"
DIGEST="$(gcloud artifacts docker images describe "$IMAGE:latest" --format='value(image_summary.digest)')"
log "image digest (this is what gets attested): $DIGEST"

step "Support VM: redis, proxy, indexer"
if ! gcloud compute instances describe "$SUPPORT_VM" --zone="$ZONE" >/dev/null 2>&1; then
    gcloud compute instances create "$SUPPORT_VM" \
        --zone="$ZONE" --machine-type=e2-standard-2 \
        --image-family=ubuntu-2404-lts --image-project=ubuntu-os-cloud \
        --boot-disk-size=50GB --tags=agama-fce \
        --metadata=startup-script='#!/bin/bash
set -e
apt-get update
apt-get install -y docker.io docker-compose-v2 git jq
usermod -aG docker $(ls /home | head -1) || true
systemctl enable --now docker'
    log "waiting for docker on the support VM"
    for _ in $(seq 1 40); do
        gcloud compute ssh "$SUPPORT_VM" --zone="$ZONE" --command 'docker info >/dev/null 2>&1' >/dev/null 2>&1 && break
        sleep 15
    done
fi

# Ship the compose stack and its config. The extension itself is NOT started here —
# it only ever runs inside the TEE.
log "copying the stack to $SUPPORT_VM"
TARBALL="$(mktemp -t agama-fce-XXXX).tar.gz"
tar -czf "$TARBALL" -C "$PROJECT_DIR" \
    --exclude='.git' --exclude='python/.venv' --exclude='.indexer-src' --exclude='out' --exclude='lib' \
    docker-compose.yaml docker-compose.coston2.yaml docker-compose.indexer.yaml \
    config scripts proxy python tools foundry.toml .env
gcloud compute scp "$TARBALL" "$SUPPORT_VM:~/stack.tar.gz" --zone="$ZONE"
rm -f "$TARBALL"

gcloud compute ssh "$SUPPORT_VM" --zone="$ZONE" --command '
set -e
mkdir -p ~/agama-fce && tar -xzf ~/stack.tar.gz -C ~/agama-fce
cd ~/agama-fce
./scripts/start-indexer.sh
docker compose -p agama-fce -f docker-compose.yaml -f docker-compose.coston2.yaml up -d redis ext-proxy
'

gcloud compute firewall-rules create agama-fce-proxy \
    --allow=tcp:6664 --source-ranges=0.0.0.0/0 --target-tags=agama-fce 2>/dev/null || true
gcloud compute firewall-rules create agama-fce-proxy-internal \
    --allow=tcp:6663 --source-ranges=10.128.0.0/9 --target-tags=agama-fce 2>/dev/null || true

SUPPORT_INTERNAL="$(support_ip)"
SUPPORT_PUBLIC="$(support_public_ip)"
log "proxy internal http://$SUPPORT_INTERNAL:6663 · public http://$SUPPORT_PUBLIC:6664"

step "Confidential Space VM (AMD SEV)"
# --confidential-compute-type=SEV: FCC attests GCP_AMD_SEV, not TDX.
# The launch policy only accepts the env vars the image whitelists — see the
# tee.launch_policy.allow_env_override label in python/Dockerfile.
if gcloud compute instances describe "$TEE_VM" --zone="$ZONE" >/dev/null 2>&1; then
    log "deleting the previous TEE VM (a relaunch mints a new teeId anyway)"
    gcloud compute instances delete "$TEE_VM" --zone="$ZONE" --quiet
fi
gcloud compute instances create "$TEE_VM" \
    --zone="$ZONE" --machine-type=n2d-standard-2 \
    --confidential-compute-type=SEV --maintenance-policy=TERMINATE --shielded-secure-boot \
    --image-family=confidential-space --image-project=confidential-space-images \
    --scopes=cloud-platform --tags=agama-fce \
    --metadata="^~^tee-image-reference=$IMAGE@$DIGEST~tee-container-log-redirect=true~tee-env-MODE=0~tee-env-CHAIN_URL=${CHAIN_URL:-https://coston2-api.flare.network/ext/C/rpc}~tee-env-EXTENSION_ID=$EXTENSION_ID~tee-env-INITIAL_OWNER=$INITIAL_OWNER~tee-env-PROXY_URL=http://$SUPPORT_INTERNAL:6663"

cat <<EOF

$(step "Next")
  1. Wait for the workload, then read the attested identity:
       ./scripts/deploy-gcp.sh --info
     Expect platform GCP_AMD_SEV and a codeHash that is NOT 0x194844cf… (simulated).

  2. Point .env at the live proxy and register the machine on chain:
       EXT_PROXY_URL=http://$SUPPORT_PUBLIC:6664
       ./scripts/post-build.sh

  3. Bind the RFQ to that TEE and run a full sealed-bid round trip:
       ./scripts/test.sh

  The image digest attested on chain is:
       $DIGEST
EOF
