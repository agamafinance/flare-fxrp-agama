#!/bin/bash
# Deploy the confidential YT matcher as a LIVE service in GCP Confidential Space (Intel TDX).
# The enclave generates its own signing key at boot, requests a Google attestation token binding that
# key to this image digest, and serves /pubkey, /attestation and /settle on :8080. Run from anchor-poc.
#
#   gcloud auth login
#   PROJECT_ID=your-project ./enclave/deploy-gcp.sh
set -e
: "${PROJECT_ID:?set PROJECT_ID}"
REGION=us-central1
ZONE=us-central1-a
IMAGE="$REGION-docker.pkg.dev/$PROJECT_ID/agama/rfq-enclave:latest"

gcloud config set project "$PROJECT_ID"
gcloud services enable confidentialcomputing.googleapis.com compute.googleapis.com artifactregistry.googleapis.com

# the Confidential Space VM's service account must pull the image and reach the attestation service
SA=$(gcloud iam service-accounts list --format='value(email)' --filter='displayName~Compute' | head -1)
for ROLE in artifactregistry.reader logging.logWriter confidentialcomputing.workloadUser; do
  gcloud projects add-iam-policy-binding "$PROJECT_ID" --member="serviceAccount:$SA" --role="roles/$ROLE" >/dev/null
done

# 1. build + push the enclave image
gcloud artifacts repositories create agama --repository-format=docker --location=$REGION 2>/dev/null || true
gcloud auth configure-docker $REGION-docker.pkg.dev -q
docker build --platform linux/amd64 -t "$IMAGE" enclave/
docker push "$IMAGE"
DIGEST=$(gcloud artifacts docker images describe "$IMAGE" --format='value(image_summary.digest)')
echo "IMAGE DIGEST (pinned on chain): sha256:${DIGEST#sha256:}"

# 2. open the service port and run the VM continuously (debug image so the token is also in the log)
gcloud compute firewall-rules create allow-enclave-8080 --allow=tcp:8080 --source-ranges=0.0.0.0/0 2>/dev/null || true
gcloud compute instances create rfq-enclave --zone=$ZONE --machine-type=c3-standard-4 \
  --confidential-compute-type=TDX --maintenance-policy=TERMINATE --shielded-secure-boot \
  --image-family=confidential-space-debug --image-project=confidential-space-images \
  --scopes=cloud-platform --tags=enclave \
  --metadata="^~^tee-image-reference=$IMAGE~tee-container-log-redirect=true"

IP=$(gcloud compute instances describe rfq-enclave --zone=$ZONE --format='value(networkInterfaces[0].accessConfigs[0].natIP)')
echo "waiting for the service to come up at http://$IP:8080 ..."
until curl -s --max-time 5 "http://$IP:8080/pubkey" | grep -q address; do sleep 10; done
echo "enclave key : $(curl -s http://$IP:8080/pubkey)"
echo "attestation : http://$IP:8080/attestation  (feed this token to DeployConfidentialSpace)"
echo
echo "Next: capture the token, set the registry to Google's JWKS key + the digest above, register the"
echo "enclave key on chain, point the RFQ at that registry, then ./enclave/settle-via-enclave.sh."
