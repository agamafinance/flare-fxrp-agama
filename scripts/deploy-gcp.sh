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

TEE_ZONE_FILE="$PROJECT_DIR/config/tee-vm.env"
# shellcheck source=/dev/null
[[ -f "$TEE_ZONE_FILE" ]] && source "$TEE_ZONE_FILE"
TEE_ZONE="${TEE_ZONE:-$ZONE}"

case "${1:-}" in
    --info)
        ip="$(support_public_ip)" || die "no support VM"
        log "proxy: http://$ip:6674"
        curl -s --max-time 20 "http://$ip:6674/info" | jq '.machineData | {extensionId, codeHash, platform, initialOwner}' 2>/dev/null \
            || die "the proxy did not answer — check: gcloud compute ssh $SUPPORT_VM --zone=$ZONE --command 'docker logs agama-fce-ext-proxy-1'"
        exit 0 ;;
    --destroy)
        gcloud compute instances delete "$TEE_VM" --zone="$TEE_ZONE" --quiet 2>/dev/null || true
        gcloud compute instances delete "$SUPPORT_VM" --zone="$ZONE" --quiet
        exit 0 ;;
    --tee-only) TEE_ONLY=true ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
esac
TEE_ONLY="${TEE_ONLY:-false}"

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
for role in artifactregistry.reader artifactregistry.writer logging.logWriter confidentialcomputing.workloadUser; do
    gcloud projects add-iam-policy-binding "$PROJECT_ID" --member="serviceAccount:$SA" --role="roles/$role" >/dev/null
done

if [[ "$TEE_ONLY" == "false" ]]; then
step "Support VM: build host, redis, proxy, indexer"
gcloud artifacts repositories create "$REPO" --repository-format=docker --location="$REGION" 2>/dev/null || true

if ! gcloud compute instances describe "$SUPPORT_VM" --zone="$ZONE" >/dev/null 2>&1; then
    gcloud compute instances create "$SUPPORT_VM" \
        --zone="$ZONE" --machine-type=e2-standard-4 \
        --image-family=ubuntu-2404-lts-amd64 --image-project=ubuntu-os-cloud \
        --boot-disk-size=80GB --tags=agama-fce \
        --scopes=cloud-platform \
        --metadata=startup-script='#!/bin/bash
set -e
apt-get update
apt-get install -y docker.io docker-compose-v2 docker-buildx git jq
systemctl enable --now docker'
    log "waiting for docker on the support VM"
    for _ in $(seq 1 40); do
        gcloud compute ssh "$SUPPORT_VM" --zone="$ZONE" --quiet --command 'sudo docker info >/dev/null 2>&1' >/dev/null 2>&1 && break
        sleep 15
    done
fi

# The whole stack goes up, because this VM also BUILDS the extension image. The
# Confidential Space VM is x86; cross-building it on an arm64 laptop means running
# the entire Go toolchain under QEMU. Building where the architecture is native is
# both faster and closer to what an auditor would reproduce.
log "copying the stack to $SUPPORT_VM"
TARBALL="$(mktemp -t agama-fce-XXXX).tar.gz"
tar -czf "$TARBALL" -C "$PROJECT_DIR" \
    --exclude='.git' --exclude='.indexer-src' --exclude='python/.venv' \
    docker-compose.yaml docker-compose.coston2.yaml docker-compose.indexer.yaml \
    config scripts proxy python docker .env
gcloud compute scp "$TARBALL" "$SUPPORT_VM:~/stack.tar.gz" --zone="$ZONE" --quiet
rm -f "$TARBALL"

SOURCE_DATE_EPOCH="$(git -C "$PROJECT_DIR" log -1 --format=%ct)"
TEE_NODE_REF="$(bash -c "source '$SCRIPT_DIR/lib/versions.sh'; load_versions '$PROJECT_DIR'; echo \$TEE_NODE_REF")"

# sudo throughout: the login user's docker group membership does not apply to an
# already-authenticated ssh session.
log "building the extension image on the VM and pushing it (this takes a few minutes)"
gcloud compute ssh "$SUPPORT_VM" --zone="$ZONE" --quiet --command "
set -e
mkdir -p ~/agama-fce && tar -xzf ~/stack.tar.gz -C ~/agama-fce
cd ~/agama-fce

# Artifact Registry auth without gcloud: the VM's own metadata token.
TOKEN=\$(curl -s -H 'Metadata-Flavor: Google' \
  http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token | jq -r .access_token)
echo \"\$TOKEN\" | sudo docker login -u oauth2accesstoken --password-stdin https://$REGION-docker.pkg.dev

# Ubuntu's docker.io defaults to the classic builder, which does not understand
# the --mount cache directives these Dockerfiles use for reproducible apt/pip.
sudo apt-get install -y docker-buildx >/dev/null 2>&1 || true
export DOCKER_BUILDKIT=1
sudo -E docker build -f docker/node-base.Dockerfile \
  --build-arg TEE_NODE_REF=$TEE_NODE_REF --build-arg SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH \
  -t local/tee-node-base:$TEE_NODE_REF docker/
sudo -E docker build -f python/Dockerfile \
  --build-arg TEE_NODE_REF=$TEE_NODE_REF --build-arg SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH \
  -t $IMAGE:latest .
sudo docker push $IMAGE:latest

sudo -E docker build -f proxy/Dockerfile -t local/tee-proxy proxy
sudo ./scripts/start-indexer.sh
sudo docker compose -p agama-fce -f docker-compose.yaml -f docker-compose.coston2.yaml up -d redis ext-proxy
"

fi

DIGEST="$(gcloud artifacts docker images describe "$IMAGE:latest" --format='value(image_summary.digest)')"
[[ -n "$DIGEST" ]] || die "no image in $IMAGE — run without --tee-only first"
log "image digest (this is what gets attested): $DIGEST"

# Container 6663/6664 are published on host 6673/6674 (docker-compose.yaml), so the
# firewall and every URL below use the HOST ports. Getting this wrong is silent:
# the TEE simply never reaches the proxy and never announces itself.
gcloud compute firewall-rules create agama-fce-proxy \
    --allow=tcp:6674 --source-ranges=0.0.0.0/0 --target-tags=agama-fce 2>/dev/null || true
gcloud compute firewall-rules create agama-fce-proxy-internal \
    --allow=tcp:6673 --source-ranges=10.128.0.0/9 --target-tags=agama-fce 2>/dev/null || true

SUPPORT_INTERNAL="$(support_ip)"
SUPPORT_PUBLIC="$(support_public_ip)"
log "proxy internal http://$SUPPORT_INTERNAL:6673 · public http://$SUPPORT_PUBLIC:6674"

step "Confidential Space VM (AMD SEV)"
# --confidential-compute-type=SEV: FCC attests GCP_AMD_SEV, not TDX.
# The launch policy only accepts the env vars the image whitelists — see the
# tee.launch_policy.allow_env_override label in python/Dockerfile.
# Delete any previous enclave, wherever it landed: capacity moves it between zones,
# so looking only in $ZONE leaves one behind and the next create fails on the name.
while read -r name zone; do
    [[ -n "$name" ]] || continue
    log "deleting the previous TEE VM in $zone (a relaunch mints a new teeId anyway)"
    gcloud compute instances delete "$name" --zone="$zone" --quiet
done < <(gcloud compute instances list --filter="name=$TEE_VM" --format='value(name,zone.basename())')

# Confidential VM shapes run out. The support VM is reachable on the internal
# network across every zone of its region, so falling back to another zone costs
# nothing — the TEE only has to reach $SUPPORT_INTERNAL:6663.
TEE_ZONES="${TEE_ZONES:-$ZONE us-central1-b us-central1-c us-central1-f}"
TEE_TYPES="${TEE_TYPES:-n2d-standard-2 n2d-standard-4 n2d-standard-8}"
TEE_ZONE=""
for zone in $TEE_ZONES; do
    for mtype in $TEE_TYPES; do
        log "trying $mtype in $zone"
        if gcloud compute instances create "$TEE_VM" \
            --zone="$zone" --machine-type="$mtype" \
            --confidential-compute-type=SEV --maintenance-policy=TERMINATE --shielded-secure-boot \
            --image-family=confidential-space --image-project=confidential-space-images \
            --scopes=cloud-platform --tags=agama-fce \
            --metadata="^~^tee-image-reference=$IMAGE@$DIGEST~tee-container-log-redirect=true~tee-env-MODE=0~tee-env-CHAIN_URL=${CHAIN_URL:-https://coston2-api.flare.network/ext/C/rpc}~tee-env-EXTENSION_ID=$EXTENSION_ID~tee-env-INITIAL_OWNER=$INITIAL_OWNER~tee-env-PROXY_URL=http://$SUPPORT_INTERNAL:6673~tee-env-CHAIN_ID=${CHAIN_ID:-114}~tee-env-GOVERNANCE_SIGNERS=${GOVERNANCE_SIGNERS:-$INITIAL_OWNER}~tee-env-GOVERNANCE_THRESHOLD=${GOVERNANCE_THRESHOLD:-1}" 2>&1 | tail -3; then
            TEE_ZONE="$zone"
            break 2
        fi
    done
done
[[ -n "$TEE_ZONE" ]] || die "no zone in [$TEE_ZONES] had capacity for [$TEE_TYPES] — try again later or set TEE_ZONES"

# Remember where it landed: --info and --destroy need the zone, and it is not $ZONE.
printf 'TEE_ZONE=%s\n' "$TEE_ZONE" > "$PROJECT_DIR/config/tee-vm.env"
log "TEE VM up in $TEE_ZONE"

# The proxy panics if the TEE does not answer its first info request within five
# minutes of startup, and a cold Confidential Space boot takes longer than that.
# So the proxy is restarted once the TEE is actually up, not before.
log "waiting for the enclave to boot, then restarting the proxy"
for _ in $(seq 1 30); do
    sleep 20
    if gcloud compute instances get-serial-port-output "$TEE_VM" --zone="$TEE_ZONE" 2>/dev/null \
        | grep -q "workload task started"; then
        log "workload started"
        break
    fi
done
gcloud compute ssh "$SUPPORT_VM" --zone="$ZONE" --quiet --command \
    'cd ~/agama-fce && sudo docker compose -p agama-fce -f docker-compose.yaml -f docker-compose.coston2.yaml restart ext-proxy'


cat <<EOF

$(step "Next")
  1. Wait for the workload, then read the attested identity:
       ./scripts/deploy-gcp.sh --info
     Expect platform GCP_AMD_SEV and a codeHash that is NOT 0x194844cf… (simulated).

  2. Point .env at the live proxy and register the machine on chain:
       EXT_PROXY_URL=http://$SUPPORT_PUBLIC:6674
       ./scripts/post-build.sh

  3. Bind the RFQ to that TEE and run a full sealed-bid round trip:
       ./scripts/test.sh

  The image digest attested on chain is:
       $DIGEST
EOF
