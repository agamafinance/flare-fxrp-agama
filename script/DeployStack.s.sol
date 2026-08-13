// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "forge-std/Script.sol";
import "../src/MockERC20.sol";
import "../src/MockVault.sol";
import "../src/YieldSplitter.sol";
import "../src/PtAmm.sol";
import "../src/Anchor.sol";
import {FixedRateVault, IAnchorVault} from "../src/FixedRateVault.sol";

/// Deploy one full fixed-rate stack (its own maturity) over the existing demo FXRP, and seed a deep
/// AMM pool. Params via env:
///   TERM_SECONDS  maturity horizon from now
///   FXRP          existing demo FXRP token (shared faucet)
///   POOL_FXRP     FXRP side of the seeded pool (raw 6-dec)
///   POOL_PT       PT side of the seeded pool  (raw 6-dec); ratio sets the fixed rate
contract DeployStack is Script {
    function run() external {
        uint256 term = vm.envUint("TERM_SECONDS");
        MockERC20 fxrp = MockERC20(vm.envAddress("FXRP"));
        uint256 poolFxrp = vm.envUint("POOL_FXRP");
        uint256 poolPt = vm.envUint("POOL_PT");
        uint256 maturity = block.timestamp + term;

        vm.startBroadcast();

        MockVault vault = new MockVault(fxrp);
        YieldSplitter splitter = new YieldSplitter(vault, maturity);
        SplitToken pt = splitter.pt();
        PtAmm amm = new PtAmm(IERC20Min(address(fxrp)), IERC20Min(address(pt)), maturity, 1e18);
        Anchor anchor = new Anchor(splitter, amm);
        FixedRateVault frv = new FixedRateVault(IAnchorVault(address(anchor)));

        // seed a deep pool so the rate is stable across deposit sizes
        fxrp.mint(msg.sender, poolFxrp + poolPt + 1_000_000);
        fxrp.approve(address(splitter), type(uint256).max);
        splitter.split(poolPt); // deployer gets poolPt PT (+ YT)
        fxrp.approve(address(amm), type(uint256).max);
        pt.approve(address(amm), type(uint256).max);
        amm.addLiquidity(poolFxrp, poolPt);

        vm.stopBroadcast();

        console.log("== fixed-rate stack (term seconds) ==", term);
        console.log("FixedRateVault (arFXRP):", address(frv));
        console.log("Anchor  :", address(anchor));
        console.log("PtAmm   :", address(amm));
        console.log("Splitter:", address(splitter));
        console.log("PT      :", address(pt));
        console.log("YT      :", address(splitter.yt()));
        console.log("MockVault:", address(vault));
        console.log("maturity:", maturity);
    }
}
