# Confidential matcher (GCP Confidential Space, Intel TDX)

The YT RFQ matcher that runs inside a Trusted Execution Environment. Market makers' quotes never
leave the enclave; only the signed winning settlement is published. The enclave's signing key is
trusted on chain only because a Confidential Space attestation, verified on chain, binds it to this
container's code image.

## What it does

- Holds a signing key sealed in the enclave.
- Requests a Confidential Space attestation OIDC token whose `eat_nonce` is the enclave key.
- Runs best execution over sealed quotes (FTSO-bounded, ties broken by Flare Secure RNG) and signs
  only the winning settlement, in the exact format `ConfidentialYtRfq` verifies.

`matcher.py` runs locally as a simulation (`ENCLAVE_PK=0x.. python matcher.py`); its signature is
byte-for-byte compatible with the deployed RFQ (checked in the settle helper).

## Deploy to Confidential Space (the real TEE)

Following Flare's Confidential Compute / GCP Confidential Space docs:

```bash
# 1. build and push the image (its digest is what the on-chain registry pins)
docker build -t ghcr.io/agamafinance/rfq-enclave:latest enclave/
docker push ghcr.io/agamafinance/rfq-enclave:latest
DIGEST=$(docker inspect --format='{{index .RepoDigests 0}}' ghcr.io/agamafinance/rfq-enclave:latest)

# 2. run it on a Confidential Space VM (Intel TDX)
gcloud compute instances create rfq-enclave \
  --confidential-compute-type=TDX --maintenance-policy=TERMINATE --zone=us-central1-a \
  --image-family=confidential-space --image-project=confidential-space-images \
  --metadata="tee-image-reference=$DIGEST,tee-container-log-redirect=true"
```

The container gets its attestation token from the launcher socket
(`/run/container_launcher/teeserver.sock`), an RS256 JWT signed by Google's confidentialspace-sign
service account, with claims `iss`, `submods.container.image_digest` and the `eat_nonce`.

## Register the key on chain

`ConfidentialSpaceRegistry` verifies that JWT on chain (RS256 against the attester JWKS key, then
requires the approved image digest and the presented enclave key as `eat_nonce`). For production:

- set the registry's attester modulus to Google's JWKS key (kid rotates; fetch from
  `https://www.googleapis.com/service_accounts/v1/metadata/jwk/signer@confidentialspace-sign.iam.gserviceaccount.com`),
- set the expected image digest to the pushed image,
- call `registerEnclave(headerB64, payloadB64, signature, enclaveKey)` with the token parts.

In this POC the attester is a test RSA key and the token is in the exact CS format
(`../test/vectors/cs_attestation_jwt.json`), so the full on-chain verification is provable without
a GCP deployment. The only step that needs GCP is producing a Google-signed token.
