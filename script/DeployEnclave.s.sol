// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "forge-std/Script.sol";
import "../src/EnclaveRegistry.sol";

/**
 * Deploys the attestation-gated EnclaveRegistry and registers the enclave key ON CHAIN by
 * verifying a real RS256 attestation (test/vectors/rsa_attestation.json). In production the
 * attester modulus is Google's Confidential Space key and the vector is a live attestation JWT.
 *   PRIVATE_KEY=0x.. forge script script/DeployEnclave.s.sol:DeployEnclave --rpc-url coston2 --broadcast
 */
contract DeployEnclave is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        string memory j = vm.readFile("test/vectors/rsa_attestation.json");
        bytes memory n = vm.parseJsonBytes(j, ".n");
        address enclave = vm.parseJsonAddress(j, ".enclave");
        bytes32 imageDigest = vm.parseJsonBytes32(j, ".imageDigest");
        uint256 nonce = vm.parseJsonUint(j, ".nonce");
        bytes memory sig = vm.parseJsonBytes(j, ".sig");

        vm.startBroadcast(pk);
        EnclaveRegistry reg = new EnclaveRegistry(n, hex"010001", imageDigest);
        reg.registerEnclave(enclave, imageDigest, nonce, sig); // verified on chain
        vm.stopBroadcast();

        console2.log("EnclaveRegistry", address(reg));
        console2.log("enclaveSigner (from attestation)", reg.enclaveSigner());
    }
}
