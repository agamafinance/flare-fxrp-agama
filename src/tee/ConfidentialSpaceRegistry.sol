// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "../rsa/RsaVerify.sol";
import "../IEnclaveRegistry.sol";
import "./JsonLite.sol";

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
 *   attestation OIDC token whose `eat_nonce` carries that key. This contract verifies that JWT on
 *   chain: RS256 against Google's confidentialspace-sign key, then it decodes the payload and reads
 *   each claim AT ITS EXACT JSON PATH (JsonLite, not a substring scan) so a debug / non-TDX /
 *   wrong-image workload cannot forge claims by injecting `submods.container.env` keys. It requires a
 *   non-debuggable production Intel TDX enclave running the approved image, a non-expired token, and
 *   is owner-gated and one-time per token so a stale/leaked token cannot be replayed to roll the key.
 */
contract ConfidentialSpaceRegistry is IEnclaveRegistry {
    bytes public attesterModulus; // Google CS signer RSA modulus (JWKS `n`)
    bytes public attesterExponent; // 0x010001
    bytes public expectedImageDigest; // approved container image digest, e.g. "sha256:..."
    address public enclaveSigner; // registered enclave key
    address public owner; // only the owner may (re)register, so a replayed token cannot roll the key
    mapping(bytes32 => bool) public usedToken; // one-time per attestation token

    bytes constant ISSUER = "https://confidentialcomputing.googleapis.com";
    bytes constant HWMODEL = "GCP_INTEL_TDX";
    bytes constant SWNAME = "CONFIDENTIAL_SPACE";
    bytes constant NODEBUG = "disabled-since-boot"; // production; a debug enclave reports "enabled"

    event EnclaveRegistered(address indexed enclaveSigner, bytes imageDigest);

    constructor(bytes memory _modulus, bytes memory _exponent, bytes memory _expectedImageDigest) {
        attesterModulus = _modulus;
        attesterExponent = _exponent;
        expectedImageDigest = _expectedImageDigest;
        owner = msg.sender;
    }

    /// Register the enclave key from a Confidential Space attestation JWT (its three base64url parts).
    /// `claimedKey` must be the token's eat_nonce. Owner-only, one-time per token, non-expired.
    function registerEnclave(bytes calldata headerB64, bytes calldata payloadB64, bytes calldata signature, address claimedKey)
        external
    {
        require(msg.sender == owner, "only owner");

        // 1. RS256: verify Google's signature over the JWT signing input (payload is well-formed after)
        bytes memory signingInput = bytes.concat(headerB64, ".", payloadB64);
        require(RsaVerify.verify(signingInput, signature, attesterExponent, attesterModulus), "bad attestation signature");

        // 2. one-time: a stale/leaked token cannot be replayed to roll the enclave key back
        bytes32 tokenId = keccak256(signature);
        require(!usedToken[tokenId], "token replayed");
        usedToken[tokenId] = true;

        // 3. read each claim at its EXACT path (never a global substring scan)
        bytes memory p = Base64URL.decode(payloadB64);
        uint256 n = p.length;
        require(_topEq(p, n, "iss", ISSUER), "issuer not Confidential Space");
        require(_topEq(p, n, "hwmodel", HWMODEL), "not Intel TDX");
        require(_topEq(p, n, "swname", SWNAME), "not Confidential Space");
        require(_topEq(p, n, "dbgstat", NODEBUG), "debug enclave not allowed");
        require(_topEq(p, n, "eat_nonce", _toHex(claimedKey)), "enclave key not the eat_nonce");

        // 4. freshness: reject an expired token
        (uint256 xs, uint256 xe) = JsonLite.get(p, 0, n, "exp");
        require(JsonLite.toUint(p, xs, xe) > block.timestamp, "attestation expired");

        // 5. approved image at submods.container.image_digest (exact path, so env keys cannot spoof it)
        (uint256 ss, uint256 se) = JsonLite.get(p, 0, n, "submods");
        (uint256 cs, uint256 ce) = JsonLite.get(p, ss, se, "container");
        (uint256 is0, uint256 ie) = JsonLite.get(p, cs, ce, "image_digest");
        require(JsonLite.equals(p, is0, ie, expectedImageDigest), "unexpected enclave image");

        enclaveSigner = claimedKey;
        emit EnclaveRegistered(claimedKey, expectedImageDigest);
    }

    function _topEq(bytes memory p, uint256 n, bytes memory key, bytes memory val) private pure returns (bool) {
        (uint256 vs, uint256 ve) = JsonLite.get(p, 0, n, key);
        return JsonLite.equals(p, vs, ve, val);
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
