// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "forge-std/Test.sol";
import "../src/MockERC20.sol";
import "../src/MockVault.sol";
import "../src/YieldSplitter.sol";
import "../src/PtAmm.sol";
import "../src/Anchor.sol";

/**
 * The unified Anchor router, exercised end-to-end at BOTH 18 decimals and the real
 * FXRP 6 decimals — proving the YieldSpace math normalizes decimals correctly.
 * Flow: LP seeds a deep pool -> user locks a fixed rate in ONE call -> redeems 1:1 at maturity.
 */
contract AnchorTest is Test {
    address lp = makeAddr("lp");
    address user = makeAddr("user");

    function _run(uint8 dec) internal {
        uint256 ONE = 10 ** dec;
        MockERC20 fxrp = new MockERC20("Flare XRP", "FXRP", dec);
        MockVault vault = new MockVault(fxrp);
        uint256 maturity = block.timestamp + 90 days;
        YieldSplitter splitter = new YieldSplitter(vault, maturity);
        SplitToken pt = splitter.pt();
        vm.prank(lp); // lp is the single LP (owner) of the AMM
        PtAmm amm = new PtAmm(IERC20Min(address(fxrp)), IERC20Min(address(pt)), maturity, 1e18);
        Anchor anchor = new Anchor(splitter, amm);

        // PT/YT inherit the underlying's decimals
        assertEq(pt.decimals(), dec, "PT decimals match FXRP");

        // LP seeds a deep pool (more PT than FXRP -> ~5% fixed APR)
        fxrp.mint(lp, 250000 * ONE);
        vm.startPrank(lp);
        fxrp.approve(address(splitter), type(uint256).max);
        splitter.split(110000 * ONE);
        fxrp.approve(address(amm), type(uint256).max);
        pt.approve(address(amm), type(uint256).max);
        amm.addLiquidity(100000 * ONE, 105000 * ONE);
        vm.stopPrank();

        // --- USER: lock a fixed rate in ONE call ---
        fxrp.mint(user, 1000 * ONE);
        (uint256 previewPt, uint256 aprE18) = anchor.previewLock(500 * ONE);

        vm.startPrank(user);
        fxrp.approve(address(anchor), type(uint256).max);
        uint256 ptOut = anchor.lockFixedRate(500 * ONE, 0);
        vm.stopPrank();

        emit log_named_decimal_uint("Fixed APR locked", aprE18, 18);
        emit log_named_decimal_uint("FXRP spent", 500 * ONE, dec);
        emit log_named_decimal_uint("PT received", ptOut, dec);

        assertEq(ptOut, previewPt, "preview == execution (fresh pool)");
        assertGt(ptOut, 500 * ONE, "bought PT at a discount");
        assertApproxEqAbs(aprE18, 0.045e18, 0.005e18, "locked ~4.5% realized APR (from the actual fill, not spot)");

        // --- Redeem 1:1 at maturity ---
        vm.warp(block.timestamp + 91 days);
        vm.startPrank(user);
        pt.approve(address(anchor), type(uint256).max);
        uint256 got = anchor.redeem(ptOut);
        vm.stopPrank();

        emit log_named_decimal_uint("Redeemed at maturity", got, dec);
        assertApproxEqAbs(got, ptOut, 10, "PT redeems 1:1 for principal");
        assertGt(fxrp.balanceOf(user), 1000 * ONE, "user ends above principal = a positive fixed yield");
    }

    function test_Anchor_18dec() public {
        _run(18);
    }

    function test_Anchor_6dec_realFXRP() public {
        _run(6);
    }
}
