// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "../rsa/RsaVerify.sol";
import "../EnclaveRegistry.sol"; // IEnclaveRegistry

/// base64url decoder (RFC 4648, no padding), for JWT payloads.
library Base64URL {
    function decode(bytes memory data) internal pure returns (bytes memory) {
        uint256 len = data.length;
        if (len == 0) return "";
        uint256 rem = len % 4;
        uint256 outLen = (len / 4) * 3 + (rem == 2 ? 1 : (rem == 3 ? 2 : 0));
        bytes memory out = new bytes(outLen);
        uint256 oi;
        uint256 i;
        while (i + 4 <= len) {
            uint256 n = (_idx(data[i]) << 18) | (_idx(data[i + 1]) << 12) | (_idx(data[i + 2]) << 6) | _idx(data[i + 3]);
            out[oi++] = bytes1(uint8(n >> 16));
            out[oi++] = bytes1(uint8(n >> 8));
            out[oi++] = bytes1(uint8(n));
            i += 4;
        }
        if (rem == 2) {
            uint256 n = (_idx(data[i]) << 18) | (_idx(data[i + 1]) << 12);
            out[oi++] = bytes1(uint8(n >> 16));
        } else if (rem == 3) {
            uint256 n = (_idx(data[i]) << 18) | (_idx(data[i + 1]) << 12) | (_idx(data[i + 2]) << 6);
            out[oi++] = bytes1(uint8(n >> 16));
            out[oi++] = bytes1(uint8(n >> 8));
        }
        return out;
    }

    function _idx(bytes1 ch) private pure returns (uint256) {
        uint8 c = uint8(ch);
        if (c >= 65 && c <= 90) return c - 65; // A-Z
        if (c >= 97 && c <= 122) return c - 71; // a-z
        if (c >= 48 && c <= 57) return c + 4; // 0-9
        if (c == 45) return 62; // -
        if (c == 95) return 63; // _
        revert("bad b64url");
    }
}

/**
 * @title ConfidentialSpaceRegistry
 * @notice Attestation-gated enclave key, following the real GCP Confidential Space remote
 *         attestation flow (per Flare's Confidential Compute docs).
 *
 *   The enclave (running in Intel TDX Confidential Space) generates a signing key and requests an
 *   attestation OIDC token whose `eat_nonce` carries that key. Google's Confidential Space signer
 *   returns an RS256 JWT with claims including `iss`, `submods.container.image_digest`, `hwmodel`
 *   and the `eat_nonce`. This contract verifies that JWT on chain: RS256 against Google's real
 *   attestation public key, then requires the token to carry the approved code image digest and
 *   bind the presented enclave key. Only then is the key registered. `ConfidentialYtRfq` reads it.
 *
 *   Set the attester modulus to Google's JWKS key (the confidentialspace-sign service account).
 *   This POC uses a test key so the flow is verifiable end to end without a GCP deployment; the
 *   enclave workload is in ../../enclave.
 */
contract ConfidentialSpaceRegistry is IEnclaveRegistry {
    bytes public attesterModulus; // Google CS signer RSA modulus (JWKS `n`)
    bytes public attesterExponent; // 0x010001
    bytes public expectedImageDigest; // approved container image digest, e.g. "sha256:..."
    address public enclaveSigner; // registered enclave key
    bytes constant ISSUER = '"iss":"https://confidentialcomputing.googleapis.com"';

    event EnclaveRegistered(address indexed enclaveSigner, bytes imageDigest);

    constructor(bytes memory _modulus, bytes memory _exponent, bytes memory _expectedImageDigest) {
        attesterModulus = _modulus;
        attesterExponent = _exponent;
        expectedImageDigest = _expectedImageDigest;
    }

    /// Register the enclave key from a Confidential Space attestation JWT (header.payload.signature
    /// passed as its three base64url parts). `claimedKey` must appear as the token's eat_nonce.
    function registerEnclave(bytes calldata headerB64, bytes calldata payloadB64, bytes calldata signature, address claimedKey)
        external
    {
        // 1. RS256: verify Google's signature over the JWT signing input
        bytes memory signingInput = bytes.concat(headerB64, ".", payloadB64);
        require(RsaVerify.verify(signingInput, signature, attesterExponent, attesterModulus), "bad attestation signature");

        // 2. decode the payload and check the claims
        bytes memory payload = Base64URL.decode(payloadB64);
        require(_contains(payload, ISSUER), "issuer not Confidential Space");
        require(_contains(payload, bytes.concat('"image_digest":"', expectedImageDigest, '"')), "unexpected enclave image");
        // the enclave key must be present as the token's eat_nonce (robust to string or array form)
        require(_contains(payload, bytes('"eat_nonce"')), "no eat_nonce");
        require(_contains(payload, _toHex(claimedKey)), "enclave key not attested");

        enclaveSigner = claimedKey;
        emit EnclaveRegistered(claimedKey, expectedImageDigest);
    }

    function _contains(bytes memory h, bytes memory n) private pure returns (bool) {
        if (n.length > h.length) return false;
        for (uint256 i = 0; i + n.length <= h.length; i++) {
            bool m = true;
            for (uint256 j = 0; j < n.length; j++) {
                if (h[i + j] != n[j]) {
                    m = false;
                    break;
                }
            }
            if (m) return true;
        }
        return false;
    }

    function _toHex(address a) private pure returns (bytes memory) {
        bytes memory hexChars = "0123456789abcdef";
        bytes memory s = new bytes(42);
        s[0] = "0";
        s[1] = "x";
        uint160 v = uint160(a);
        for (uint256 i = 0; i < 20; i++) {
            uint8 b = uint8(v >> (8 * (19 - i)));
            s[2 + i * 2] = hexChars[b >> 4];
            s[3 + i * 2] = hexChars[b & 0x0f];
        }
        return s;
    }
}
