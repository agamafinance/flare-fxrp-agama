// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "forge-std/Test.sol";
import "../src/tee/ConfidentialSpaceRegistry.sol";

/**
 * Verifies a REAL Google Confidential Space attestation token on chain. The vector
 * (test/vectors/cs_attestation_google.json) was produced by the enclave running in an actual GCP
 * Confidential Space VM (Intel TDX): a real RS256 JWT signed by Google's confidentialspace-sign
 * service account, with hwmodel GCP_INTEL_TDX, our container image_digest, and the enclave address
 * as eat_nonce. The vector embeds Google's JWKS modulus at capture time, so this test stays green
 * even after Google rotates keys.
 */
contract ConfidentialSpaceGoogleTest is Test {
    function test_RealGoogleAttestationVerifiesOnChain() public {
        string memory j = vm.readFile("test/vectors/cs_attestation_google.json");
        bytes memory n = vm.parseJsonBytes(j, ".n"); // Google's real signing key modulus
        bytes memory imageDigest = bytes(vm.parseJsonString(j, ".imageDigest"));
        bytes memory header = bytes(vm.parseJsonString(j, ".headerB64"));
        bytes memory payload = bytes(vm.parseJsonString(j, ".payloadB64"));
        bytes memory sig = vm.parseJsonBytes(j, ".sig");
        address enclave = vm.parseJsonAddress(j, ".enclave");

        ConfidentialSpaceRegistry reg = new ConfidentialSpaceRegistry(n, hex"010001", imageDigest);
        reg.registerEnclave(header, payload, sig, enclave);
        assertEq(reg.enclaveSigner(), enclave, "real Google Confidential Space token verified on chain");
    }
}
