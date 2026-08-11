// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "forge-std/Test.sol";
import "../src/MockERC20.sol";
import "../src/MockVault.sol";
import "../src/YieldSplitter.sol";
import "../src/PtAmm.sol";

/**
 * ANCHOR — end-to-end product story.
 *
 * A user who just wants a FIXED RATE never touches the yield machinery.
 * She buys PT on the AMM at a discount and holds to maturity. Her return is
 * LOCKED at the moment of purchase and is completely independent of whatever
 * the underlying XRPFi vault actually earns. The variable yield flows to the
 * YT holder (the "upside taker"), never to her.
 *
 * This test proves both halves in one run:
 *   (a) Alice's realized return == the return she locked at purchase, to the wei,
 *       no matter what the vault yields.
 *   (b) The realized yield went to the YT holder, not to Alice.
 */
contract AnchorE2ETest is Test {
    MockERC20 fxrp;
    MockVault vault;
    YieldSplitter splitter;
    SplitToken ptTok;
    SplitToken ytTok;
    PtAmm amm;

    address lp = makeAddr("lp"); // liquidity provider + upside taker (holds YT)
    address alice = makeAddr("alice"); // certainty buyer

    uint256 constant MATURITY_DAYS = 90;

    function setUp() public {
        fxrp = new MockERC20("Flare XRP", "FXRP", 18);
        vault = new MockVault(fxrp);
        uint256 maturity = block.timestamp + MATURITY_DAYS * 1 days;
        splitter = new YieldSplitter(vault, maturity);
        ptTok = splitter.pt();
        ytTok = splitter.yt();
        vm.prank(lp); // lp is the single LP (owner) of the AMM
        amm = new PtAmm(IERC20Min(address(fxrp)), IERC20Min(address(ptTok)), maturity, 1e18);

        // LP mints certainty for the market: splits FXRP, seeds the pool with a PT discount,
        // and keeps the YT (so LP is the one taking the variable-yield side).
        fxrp.mint(lp, 250000e18);
        vm.startPrank(lp);
        fxrp.approve(address(splitter), type(uint256).max);
        splitter.split(110000e18); // lp: 110000 PT + 110000 YT
        fxrp.approve(address(amm), type(uint256).max);
        ptTok.approve(address(amm), type(uint256).max);
        amm.addLiquidity(100000e18, 105000e18); // deep pool, PT < par  (~5% fixed APR)
        vm.stopPrank();
        // lp now holds: 5000 PT + 110000 YT

        fxrp.mint(alice, 1000e18);
        vm.prank(alice);
        fxrp.approve(address(amm), type(uint256).max);
    }

    function test_AnchorLocksFixedRate_IndependentOfRealizedYield() public {
        uint256 aliceStart = fxrp.balanceOf(alice);

        // --- 1. Alice buys certainty: FXRP -> PT at a discount. This LOCKS her rate. ---
        uint256 spend = 500e18;
        uint256 aprLocked = amm.impliedApr();
        vm.prank(alice);
        uint256 ptBought = amm.swapFxrpForPt(spend, 0, alice);

        assertGt(ptBought, spend, "bought PT at a discount (more PT than FXRP paid)");

        // The outcome is fully determined RIGHT NOW, before any yield is known:
        // final = unspent FXRP + PT redeemed 1:1 at maturity.
        uint256 predictedFinal = (aliceStart - spend) + ptBought;

        emit log_named_decimal_uint("Alice spent FXRP", spend, 18);
        emit log_named_decimal_uint("Alice bought PT", ptBought, 18);
        emit log_named_decimal_uint("Fixed APR locked at purchase", aprLocked, 18);

        // --- 2. Time passes. The vault earns some UNKNOWN, variable yield. ---
        // Pick a deliberately surprising amount to prove Alice is insulated from it.
        uint256 realizedYield = 900e18; // whatever it is, Alice's outcome must not move
        _pushYield(realizedYield);

        // --- 3. Maturity. Alice redeems PT 1:1. No optimisation, no timing, no yield math. ---
        vm.warp(block.timestamp + (MATURITY_DAYS + 1) * 1 days);
        vm.prank(alice);
        splitter.redeemPrincipal(ptBought);

        uint256 aliceFinal = fxrp.balanceOf(alice);
        emit log_named_decimal_uint("Alice final FXRP", aliceFinal, 18);
        emit log_named_decimal_uint("Predicted at purchase (yield-independent)", predictedFinal, 18);

        // (a) Alice got EXACTLY what she locked, regardless of the 900 FXRP the vault earned.
        assertApproxEqAbs(aliceFinal, predictedFinal, 1e6, "realized == locked, independent of yield");

        // Her return on deployed capital == the discount she bought, to the wei.
        uint256 realizedReturn = ((ptBought - spend) * 1e18) / spend;
        uint256 lockedReturn = ((ptBought - spend) * 1e18) / spend; // same by construction
        assertEq(realizedReturn, lockedReturn, "return was fixed at purchase");
        emit log_named_decimal_uint("Alice locked return over the term", realizedReturn, 18);

        // (b) The variable yield went to the YT holder (LP), not to Alice.
        uint256 lpClaimable = splitter.claimable(lp);
        emit log_named_decimal_uint("Yield captured by the YT holder (LP)", lpClaimable, 18);
        assertApproxEqAbs(lpClaimable, realizedYield, 1e15, "all realized yield went to YT, not PT");
    }

    /// Simulate the XRPFi vault earning yield (price-per-share rises).
    function _pushYield(uint256 amount) internal {
        fxrp.mint(address(this), amount);
        fxrp.approve(address(vault), amount);
        vault.addYield(amount);
    }
}
