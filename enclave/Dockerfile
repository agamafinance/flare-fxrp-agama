# Confidential matcher image for GCP Confidential Space (Intel TDX).
# Build + push to a registry, then run on a Confidential Space VM. Its image digest is what
# ConfidentialSpaceRegistry pins; the attestation token binds the enclave key to this digest.
FROM python:3.12-slim

WORKDIR /enclave
RUN pip install --no-cache-dir eth-account eth-abi eth-utils requests
COPY matcher.py /enclave/matcher.py

# Confidential Space launch policy: no debug, so the attestation states disabled-since-boot.
LABEL "tee.launch_policy.allow_cmd_override"="false"
LABEL "tee.launch_policy.log_redirect"="always"

ENTRYPOINT ["python", "/enclave/matcher.py"]
