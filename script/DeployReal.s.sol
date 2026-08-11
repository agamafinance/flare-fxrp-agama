// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "forge-std/Script.sol";
import "../src/interfaces/IERC4626.sol"; // IERC20
import "../src/MockVault.sol";
import "../src/YieldSplitter.sol";
import "../src/PtAmm.sol";
import "../src/Anchor.sol";

/**
 * Deploy the fixed-rate stack over the REAL FAsset FXRP (FTestXRP, minted from native XRP), not a
 * mock. Seeds a small PT pool from the deployer's existing FXRP balance so previewLock and the
 * confidential RFQ run on the actual interoperable asset. No public mint here: liquidity is bounded
 * by the real FXRP held. No real single-asset FXRP yield vault exists on Coston2 yet, so the vault is
 * still a mock ERC-4626 wrapper (the real-vault path is proven separately by ForkVault on mainnet).
 *
 *   FXRP_ADDR=0x0b6A3645... PRIVATE_KEY=0x... forge script script/DeployReal.s.sol:DeployReal --rpc-url coston2 --broadcast
 */
contract DeployReal is Script {
    uint256 constant ONE = 1e6;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        IERC20 fxrp = IERC20(vm.envAddress("FXRP_ADDR"));
        uint256 term = vm.envOr("TERM_SECONDS", uint256(90 days));
        vm.startBroadcast(pk);

        MockVault vault = new MockVault(fxrp);
        uint256 maturity = block.timestamp + term;
        YieldSplitter splitter = new YieldSplitter(vault, maturity);
        PtAmm amm = new PtAmm(IERC20Min(address(fxrp)), IERC20Min(address(splitter.pt())), maturity, 1e18);
        Anchor anchor = new Anchor(splitter, amm);

        // seed a modest real-FXRP pool (~5% APR): split 50, LP 12 FXRP + 12.6 PT
        fxrp.approve(address(splitter), type(uint256).max);
        splitter.split(50 * ONE);
        fxrp.approve(address(amm), type(uint256).max);
        splitter.pt().approve(address(amm), type(uint256).max);
        amm.addLiquidity(12 * ONE, 12_600_000); // 12.6 PT

        vm.stopBroadcast();

        console2.log("== Real-FXRP deployment ==");
        console2.log("FXRP     ", address(fxrp));
        console2.log("Vault    ", address(vault));
        console2.log("Splitter ", address(splitter));
        console2.log("PT       ", address(splitter.pt()));
        console2.log("YT       ", address(splitter.yt()));
        console2.log("PtAmm    ", address(amm));
        console2.log("Anchor   ", address(anchor));
    }
}
