// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

/**
 * @title RsaVerify
 * @notice RSASSA-PKCS1-v1_5 signature verification over SHA-256 (RS256), using the modexp
 *         precompile (0x05). This is the exact primitive Google Confidential Space uses to sign
 *         its attestation token, so verifying it on chain lets a contract trust an enclave key
 *         only because a valid attestation over the enclave's code measurement was presented.
 */
library RsaVerify {
    // DigestInfo prefix for SHA-256 (EMSA-PKCS1-v1_5)
    bytes constant SHA256_DIGEST_INFO = hex"3031300d060960864801650304020105000420";

    /// Verify that `sig` is a valid RS256 signature over `message` for RSA key (exponent, modulus).
    function verify(bytes memory message, bytes memory sig, bytes memory exponent, bytes memory modulus)
        internal
        view
        returns (bool)
    {
        uint256 k = modulus.length;
        if (sig.length != k) return false;
        if (!_lt(sig, modulus)) return false; // reject non-canonical sigs (s >= n); s and s+n verify alike,
            // which would otherwise defeat a keccak(sig)-keyed one-time guard

        // modexp: decrypted = sig ^ exponent mod modulus
        bytes memory input = abi.encodePacked(uint256(sig.length), uint256(exponent.length), uint256(k), sig, exponent, modulus);
        (bool ok, bytes memory decrypted) = address(0x05).staticcall(input);
        if (!ok || decrypted.length != k) return false;

        // rebuild the expected EMSA-PKCS1-v1_5 block: 00 01 FF..FF 00 DigestInfo SHA256(message)
        bytes32 h = sha256(message);
        bytes memory em = new bytes(k);
        em[0] = 0x00;
        em[1] = 0x01;
        uint256 psEnd = k - SHA256_DIGEST_INFO.length - 32 - 1; // index of the 0x00 separator
        for (uint256 i = 2; i < psEnd; i++) {
            em[i] = 0xFF;
        }
        em[psEnd] = 0x00;
        uint256 p = psEnd + 1;
        for (uint256 i = 0; i < SHA256_DIGEST_INFO.length; i++) {
            em[p + i] = SHA256_DIGEST_INFO[i];
        }
        p += SHA256_DIGEST_INFO.length;
        for (uint256 i = 0; i < 32; i++) {
            em[p + i] = h[i];
        }
        return keccak256(em) == keccak256(decrypted);
    }

    /// big-endian a < b for equal-length byte arrays
    function _lt(bytes memory a, bytes memory b) private pure returns (bool) {
        for (uint256 i = 0; i < a.length; i++) {
            if (a[i] < b[i]) return true;
            if (a[i] > b[i]) return false;
        }
        return false; // equal
    }
}
