// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "forge-std/Script.sol";
import "../src/ConfidentialYtRfq.sol";
import "../src/IEnclaveRegistry.sol";
import "../src/interfaces/IERC4626.sol";

/**
 * Deploys ConfidentialYtRfq wired to an existing FXRP/YT and an attestation-gated EnclaveRegistry.
 *   PRIVATE_KEY=0x.. FXRP=0x.. YT=0x.. REGISTRY=0x.. \
 *   forge script script/DeployRfq.s.sol:DeployRfq --rpc-url coston2 --broadcast
 */
contract DeployRfq is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address fxrp = vm.envAddress("FXRP");
        address yt = vm.envAddress("YT");
        address registry = vm.envAddress("REGISTRY");

        vm.startBroadcast(pk);
        ConfidentialYtRfq rfq = new ConfidentialYtRfq(IERC20(fxrp), IERC20(yt), IEnclaveRegistry(registry));
        vm.stopBroadcast();

        console2.log("ConfidentialYtRfq", address(rfq));
        console2.log("FXRP             ", fxrp);
        console2.log("YT               ", yt);
        console2.log("EnclaveRegistry  ", registry);
        console2.log("enclave signer   ", rfq.enclaveSigner());
    }
}
