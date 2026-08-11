#!/usr/bin/env python3
"""
Generate the synthetic Confidential Space attestation vectors used by the on-chain registry tests.
One test RSA key signs three JWTs in the exact CS format: a valid production token, a debug token
(dbgstat enabled), and a non-TDX token. Production verification uses Google's JWKS key instead; these
let the tests exercise the verifier (including the hardened hwmodel/swname/dbgstat claims) with a key
we control. Run from anchor-poc:  python3 enclave/gen_test_vectors.py
"""
import json, base64
from cryptography.hazmat.primitives.asymmetric import rsa, padding
from cryptography.hazmat.primitives import hashes

ENCLAVE = "0x1724fa1ab2c8b088128cd1c6f1efdfa1514d5253"
IMAGE = "sha256:" + "cf" * 32
b64 = lambda b: base64.urlsafe_b64encode(b).rstrip(b"=").decode()

key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
n = key.public_key().public_numbers().n.to_bytes(256, "big").hex()

def make(dbgstat, hwmodel):
    header = b64(json.dumps({"alg": "RS256", "kid": "test", "typ": "JWT"}, separators=(",", ":")).encode())
    payload = b64(json.dumps({
        "iss": "https://confidentialcomputing.googleapis.com", "aud": "agama-anchor",
        "iat": 1786460000, "exp": 1893456000, "eat_nonce": ENCLAVE,
        "hwmodel": hwmodel, "swname": "CONFIDENTIAL_SPACE", "dbgstat": dbgstat,
        "submods": {"container": {"image_digest": IMAGE}},
    }, separators=(",", ":")).encode())
    sig = key.sign(f"{header}.{payload}".encode(), padding.PKCS1v15(), hashes.SHA256()).hex()
    return {"n": n, "imageDigest": IMAGE, "headerB64": header, "payloadB64": payload,
            "sig": "0x" + sig, "enclave": ENCLAVE}

vectors = {
    "cs_attestation_jwt.json":   make("disabled-since-boot", "GCP_INTEL_TDX"),  # valid production
    "cs_attestation_debug.json": make("enabled", "GCP_INTEL_TDX"),               # debug -> rejected
    "cs_attestation_nontdx.json": make("disabled-since-boot", "GCP_AMD_SEV"),    # non-TDX -> rejected
}
for name, v in vectors.items():
    json.dump(v, open("test/vectors/" + name, "w"), indent=2)
    print("wrote test/vectors/" + name)
