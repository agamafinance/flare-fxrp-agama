#!/bin/bash
# Deploy the confidential matcher to GCP Confidential Space (Intel TDX) and print its attestation
# token. Run from the anchor-poc directory. Set PROJECT_ID first.
#
#   gcloud auth login
#   PROJECT_ID=your-project ./enclave/deploy-gcp.sh
#
# The enclave key whose address is registered on chain (settlements are signed with the matching
# private key in .env.enclave). Keep it as-is so the existing RFQ keeps working.
set -e
: "${PROJECT_ID:?set PROJECT_ID}"
REGION=us-central1
ZONE=us-central1-a
IMAGE="$REGION-docker.pkg.dev/$PROJECT_ID/agama/rfq-enclave:latest"
ENCLAVE_ADDRESS=0x1724fa1ab2c8b088128cd1c6f1efdfa1514d5253

gcloud config set project "$PROJECT_ID"
gcloud services enable confidentialcomputing.googleapis.com compute.googleapis.com artifactregistry.googleapis.com

# 1. build + push the enclave image
gcloud artifacts repositories create agama --repository-format=docker --location=$REGION 2>/dev/null || true
gcloud auth configure-docker $REGION-docker.pkg.dev -q
docker build --platform linux/amd64 -t "$IMAGE" enclave/
docker push "$IMAGE"
DIGEST=$(gcloud artifacts docker images describe "$IMAGE" --format='value(image_summary.digest)')
echo "IMAGE DIGEST (set this as the on-chain expected image): sha256:${DIGEST#sha256:}"

# 2. run it on a Confidential Space VM (TDX). debug image so the token is visible in the serial log.
gcloud compute instances create rfq-enclave --zone=$ZONE --machine-type=c3-standard-4 \
  --confidential-compute-type=TDX --maintenance-policy=TERMINATE --shielded-secure-boot \
  --image-family=confidential-space-debug --image-project=confidential-space-images \
  --scopes=cloud-platform \
  --metadata="^~^tee-image-reference=$IMAGE~tee-container-log-redirect=true~tee-env-ENCLAVE_ADDRESS=$ENCLAVE_ADDRESS"

echo "waiting ~90s for the workload to boot and print the token..."
sleep 90

# 3. read the attestation token from the serial console
gcloud compute instances get-serial-port-output rfq-enclave --zone=$ZONE \
  | sed -n '/Confidential Space attestation token/,+2p'
echo
echo "Copy the long eyJ... token above and send it back. Then the on-chain registry is configured"
echo "with Google's JWKS key + this image digest and verifies the real token."
