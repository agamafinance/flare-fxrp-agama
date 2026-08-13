// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "forge-std/Script.sol";
import {FixedRateVault, IAnchorVault} from "../src/FixedRateVault.sol";

/// Deploy the saver-facing ERC-4626 pool on top of an already-deployed Anchor router.
/// Usage: ANCHOR=0x... forge script script/DeployVault.s.sol --rpc-url coston2 --broadcast
contract DeployVault is Script {
    function run() external {
        address anchor = vm.envAddress("ANCHOR");
        vm.startBroadcast();
        FixedRateVault frv = new FixedRateVault(IAnchorVault(anchor));
        vm.stopBroadcast();
        console.log("FixedRateVault (arFXRP):", address(frv));
        console.log("  asset (FXRP):", frv.asset());
        console.log("  maturity:", frv.maturity());
    }
}
