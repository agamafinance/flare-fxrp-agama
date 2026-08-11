// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "forge-std/Script.sol";
import "../src/MockERC20.sol";
import "../src/MockVault.sol";
import "../src/YieldSplitter.sol";
import "../src/PtAmm.sol";
import "../src/Anchor.sol";

/**
 * Deploys the full Anchor stack (demo-mintable 6-decimal FXRP + ERC-4626 vault + splitter +
 * YieldSpace AMM + router) and seeds a deep PT pool so the front can lock a ~5% fixed rate
 * out of the box. The demo FXRP has a public mint() so the front can fund test users.
 *
 * Coston2:
 *   PRIVATE_KEY=0x... forge script script/Deploy.s.sol:Deploy --rpc-url coston2 --broadcast
 */
contract Deploy is Script {
    uint256 constant ONE = 1e6; // 6-decimal FXRP

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        uint256 term = vm.envOr("TERM_SECONDS", uint256(90 days)); // override for a short redeem demo
        address deployer = vm.addr(pk);
        vm.startBroadcast(pk);

        MockERC20 fxrp = new MockERC20("Demo FXRP", "dFXRP", 6);
        MockVault vault = new MockVault(fxrp);
        uint256 maturity = block.timestamp + term;
        YieldSplitter splitter = new YieldSplitter(vault, maturity);
        PtAmm amm = new PtAmm(IERC20Min(address(fxrp)), IERC20Min(address(splitter.pt())), maturity, 1e18);
        Anchor anchor = new Anchor(splitter, amm);

        // seed a deep PT pool (~5% fixed APR): split 110k, LP 100k FXRP + 105k PT
        fxrp.mint(deployer, 250000 * ONE);
        fxrp.approve(address(splitter), type(uint256).max);
        splitter.split(110000 * ONE);
        fxrp.approve(address(amm), type(uint256).max);
        splitter.pt().approve(address(amm), type(uint256).max);
        amm.addLiquidity(100000 * ONE, 105000 * ONE);

        vm.stopBroadcast();

        console2.log("== Anchor deployment ==");
        console2.log("FXRP     ", address(fxrp));
        console2.log("Vault    ", address(vault));
        console2.log("Splitter ", address(splitter));
        console2.log("PT       ", address(splitter.pt()));
        console2.log("YT       ", address(splitter.yt()));
        console2.log("PtAmm    ", address(amm));
        console2.log("Anchor   ", address(anchor));
        console2.log("maturity ", maturity);
    }
}
