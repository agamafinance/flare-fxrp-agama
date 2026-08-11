// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "forge-std/Script.sol";
import "../src/tee/ConfidentialSpaceRegistry.sol";

/**
 * Deploys ConfidentialSpaceRegistry and registers the enclave key ON CHAIN by verifying a real
 * Confidential Space attestation JWT (test/vectors/cs_attestation_jwt.json). In production set the
 * attester modulus to Google's confidentialspace-sign JWKS key and the image digest to the pushed
 * enclave image.
 *   PRIVATE_KEY=0x.. forge script script/DeployConfidentialSpace.s.sol:DeployConfidentialSpace --rpc-url coston2 --broadcast
 */
contract DeployConfidentialSpace is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        string memory j = vm.readFile("test/vectors/cs_attestation_jwt.json");
        bytes memory n = vm.parseJsonBytes(j, ".n");
        bytes memory imageDigest = bytes(vm.parseJsonString(j, ".imageDigest"));
        bytes memory header = bytes(vm.parseJsonString(j, ".headerB64"));
        bytes memory payload = bytes(vm.parseJsonString(j, ".payloadB64"));
        bytes memory sig = vm.parseJsonBytes(j, ".sig");
        address enclave = vm.parseJsonAddress(j, ".enclave");

        vm.startBroadcast(pk);
        ConfidentialSpaceRegistry reg = new ConfidentialSpaceRegistry(n, hex"010001", imageDigest);
        reg.registerEnclave(header, payload, sig, enclave); // verified on chain
        vm.stopBroadcast();

        console2.log("ConfidentialSpaceRegistry", address(reg));
        console2.log("enclaveSigner (from CS attestation)", reg.enclaveSigner());
    }
}
