# Confidential matcher image for GCP Confidential Space (Intel TDX).
# Build + push to a registry, then run on a Confidential Space VM. Its image digest is what
# ConfidentialSpaceRegistry pins; the attestation token binds the enclave key to this digest.
FROM python:3.12-slim

WORKDIR /enclave
RUN pip install --no-cache-dir eth-account eth-abi eth-utils requests
COPY matcher.py /enclave/matcher.py
EXPOSE 8080

# Confidential Space launch policy. The signing key is generated inside the enclave at boot, so no
# env override is needed: the attestation binds that generated key (eat_nonce) to this image digest.
LABEL "tee.launch_policy.allow_cmd_override"="false"
LABEL "tee.launch_policy.log_redirect"="always"

ENTRYPOINT ["python", "/enclave/matcher.py"]
