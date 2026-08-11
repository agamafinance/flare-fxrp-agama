#!/usr/bin/env python3
"""
Generate the synthetic Confidential Space attestation vectors used by the on-chain registry tests.
One test RSA key signs JWTs in the exact CS format: a valid production token, a debug token, a non-TDX
token, and an INJECTION token that spoofs every claim via submods.container.env keys (which a raw
substring scan accepts but the exact-path JsonLite parser rejects). Production verification uses
Google's JWKS key; these let the tests drive the verifier with a key we control.
Run from anchor-poc:  python3 enclave/gen_test_vectors.py
"""
import json, base64
from cryptography.hazmat.primitives.asymmetric import rsa, padding
from cryptography.hazmat.primitives import hashes

ENCLAVE = "0x1724fa1ab2c8b088128cd1c6f1efdfa1514d5253"
IMAGE = "sha256:" + "cf" * 32
b64 = lambda b: base64.urlsafe_b64encode(b).rstrip(b"=").decode()

key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
n = key.public_key().public_numbers().n.to_bytes(256, "big").hex()

def make(dbgstat, hwmodel, image_digest=IMAGE, env=None):
    container = {"image_digest": image_digest, "image_reference": "ghcr.io/agamafinance/rfq-enclave@" + image_digest}
    if env is not None:
        container["env"] = env
    header = b64(json.dumps({"alg": "RS256", "kid": "test", "typ": "JWT"}, separators=(",", ":")).encode())
    payload = b64(json.dumps({
        "iss": "https://confidentialcomputing.googleapis.com", "aud": "agama-anchor",
        "iat": 1786460000, "exp": 1893456000, "eat_nonce": ENCLAVE,
        "hwmodel": hwmodel, "swname": "CONFIDENTIAL_SPACE", "dbgstat": dbgstat,
        "submods": {"container": container},
    }, separators=(",", ":")).encode())
    sig = key.sign(f"{header}.{payload}".encode(), padding.PKCS1v15(), hashes.SHA256()).hex()
    return {"n": n, "imageDigest": IMAGE, "headerB64": header, "payloadB64": payload,
            "sig": "0x" + sig, "enclave": ENCLAVE}

# an attacker: real machine is debug + AMD SEV + a different image, but env keys inject the approved
# claim strings so a substring scan would accept it. The exact-path parser reads the real top level.
spoof_env = {"hwmodel": "GCP_INTEL_TDX", "swname": "CONFIDENTIAL_SPACE",
             "dbgstat": "disabled-since-boot", "image_digest": IMAGE}

vectors = {
    "cs_attestation_jwt.json":       make("disabled-since-boot", "GCP_INTEL_TDX"),               # valid production
    "cs_attestation_debug.json":     make("enabled", "GCP_INTEL_TDX"),                            # debug -> rejected
    "cs_attestation_nontdx.json":    make("disabled-since-boot", "GCP_AMD_SEV"),                  # non-TDX -> rejected
    "cs_attestation_injection.json": make("enabled", "GCP_AMD_SEV", "sha256:" + "ab" * 32, spoof_env),  # substring-spoof -> rejected
}
for name, v in vectors.items():
    json.dump(v, open("test/vectors/" + name, "w"), indent=2)
    print("wrote test/vectors/" + name)
