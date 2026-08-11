# Confidential matcher image for GCP Confidential Space (Intel TDX).
# Build + push to a registry, then run on a Confidential Space VM. Its image digest is what
# ConfidentialSpaceRegistry pins; the attestation token binds the enclave key to this digest.
FROM python:3.12-slim

WORKDIR /enclave
RUN pip install --no-cache-dir eth-account eth-abi eth-utils requests
COPY matcher.py /enclave/matcher.py

# Confidential Space launch policy. Allow the enclave key address to be set at launch (eat_nonce).
LABEL "tee.launch_policy.allow_cmd_override"="false"
LABEL "tee.launch_policy.log_redirect"="always"
LABEL "tee.launch_policy.allow_env_override"="ENCLAVE_ADDRESS"

ENTRYPOINT ["python", "/enclave/matcher.py"]
