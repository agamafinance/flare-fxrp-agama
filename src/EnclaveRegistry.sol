// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "./rsa/RsaVerify.sol";

interface IEnclaveRegistry {
    function enclaveSigner() external view returns (address);
}

/**
 * @title EnclaveRegistry
 * @notice Attestation-gated registration of the confidential-matcher enclave key.
 *
 *   Replaces the manual `setEnclaveSigner` trust with a real check: the enclave key is registered
 *   only if a valid attestation, signed by the Confidential Space attestation authority over the
 *   enclave's exact code measurement (image digest), is presented. The attestation binds
 *   (enclaveSigner, imageDigest, nonce) and is RSA/RS256 signed, exactly as GCP Confidential Space
 *   issues it. On chain we verify that signature and require the measured image to be the approved
 *   one, so nobody, not even the deployer, can register an arbitrary key.
 *
 *   POC note: the attester RSA key here is a test key. For production, set it to Google's
 *   Confidential Space attestation JWKS key and parse the full JWT claims.
 */
contract EnclaveRegistry {
    bytes public attesterModulus; // RSA modulus of the attestation authority (GCP in prod)
    bytes public attesterExponent; // RSA exponent (0x010001)
    bytes32 public expectedImageDigest; // approved enclave code measurement
    address public enclaveSigner; // the currently registered enclave key
    uint256 public lastNonce;

    event EnclaveRegistered(address indexed enclaveSigner, bytes32 imageDigest, uint256 nonce);

    constructor(bytes memory _modulus, bytes memory _exponent, bytes32 _expectedImageDigest) {
        attesterModulus = _modulus;
        attesterExponent = _exponent;
        expectedImageDigest = _expectedImageDigest;
    }

    /// Register the enclave key from a signed Confidential Space attestation. No manual override.
    function registerEnclave(address _enclaveSigner, bytes32 imageDigest, uint256 nonce, bytes calldata rsaSig)
        external
    {
        require(imageDigest == expectedImageDigest, "unexpected enclave image");
        require(nonce > lastNonce, "stale attestation");
        bytes memory statement = abi.encode(_enclaveSigner, imageDigest, nonce);
        require(RsaVerify.verify(statement, rsaSig, attesterExponent, attesterModulus), "bad attestation signature");
        enclaveSigner = _enclaveSigner;
        lastNonce = nonce;
        emit EnclaveRegistered(_enclaveSigner, imageDigest, nonce);
    }
}
