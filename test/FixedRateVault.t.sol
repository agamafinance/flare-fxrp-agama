// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "forge-std/Test.sol";
import "../src/MockERC20.sol";
import "../src/MockVault.sol";
import "../src/YieldSplitter.sol";
import "../src/PtAmm.sol";
import "../src/Anchor.sol";
import {FixedRateVault, IAnchorVault} from "../src/FixedRateVault.sol";

/**
 * FIXED-RATE VAULT — the saver-facing ERC-4626 pool.
 *
 * A saver only ever does two things: deposit FXRP, and withdraw at maturity. No PT, no YT, no AMM.
 * These tests prove the wrapper keeps the fixed-rate guarantees of the underlying primitive:
 *   - a deposit locks a rate at entry (par-denominated shares == PT held),
 *   - the rate is independent of what the vault actually yields,
 *   - each cohort keeps its own locked rate (no blending by a later deposit),
 *   - the ERC-4626 donation/inflation attack cannot extract value,
 *   - the term lock (deposit before maturity, withdraw after) holds.
 */
contract FixedRateVaultTest is Test {
    MockERC20 fxrp;
    MockVault vault;
    YieldSplitter splitter;
    SplitToken ptTok;
    SplitToken ytTok;
    PtAmm amm;
    Anchor anchor;
    FixedRateVault frv;

    address lp = makeAddr("lp"); // liquidity provider + YT holder (the upside taker)
    address alice = makeAddr("alice"); // saver
    address bob = makeAddr("bob"); // second saver

    uint256 constant MATURITY_DAYS = 90;
    uint256 maturity;

    function setUp() public {
        fxrp = new MockERC20("Flare XRP", "FXRP", 18);
        vault = new MockVault(fxrp); // this test contract owns the vault (can simulate yield)
        maturity = block.timestamp + MATURITY_DAYS * 1 days;
        splitter = new YieldSplitter(vault, maturity);
        ptTok = splitter.pt();
        ytTok = splitter.yt();
        vm.prank(lp);
        amm = new PtAmm(IERC20Min(address(fxrp)), IERC20Min(address(ptTok)), maturity, 1e18);

        // LP seeds a PT pool at a discount (~5% fixed APR) and keeps the YT (the variable-yield side).
        fxrp.mint(lp, 250000e18);
        vm.startPrank(lp);
        fxrp.approve(address(splitter), type(uint256).max);
        splitter.split(110000e18);
        fxrp.approve(address(amm), type(uint256).max);
        ptTok.approve(address(amm), type(uint256).max);
        amm.addLiquidity(100000e18, 105000e18);
        vm.stopPrank();

        anchor = new Anchor(splitter, amm);
        frv = new FixedRateVault(IAnchorVault(address(anchor)));

        _fund(alice, 1000e18);
        _fund(bob, 1000e18);
    }

    function _fund(address who, uint256 amt) internal {
        fxrp.mint(who, amt);
        vm.prank(who);
        fxrp.approve(address(frv), type(uint256).max);
    }

    function _pushYield(uint256 amount) internal {
        fxrp.mint(address(this), amount);
        fxrp.approve(address(vault), amount);
        vault.addYield(amount);
    }

    /// A deposit mints par-denominated shares == the PT the vault bought, and locks a rate > 0.
    function test_Deposit_MintsParShares_LocksRate() public {
        vm.prank(alice);
        uint256 shares = frv.deposit(500e18, alice);

        assertGt(shares, 500e18, "bought PT at a discount -> more shares than FXRP in");
        assertEq(frv.balanceOf(alice), shares, "alice holds her shares");
        assertEq(frv.totalSupply(), shares, "supply == shares minted");
        assertEq(ptTok.balanceOf(address(frv)), shares, "1 share == 1 PT held by the vault");
        assertEq(frv.totalAssets(), shares, "totalAssets marks PT at par == supply");
        assertEq(fxrp.balanceOf(alice), 500e18, "alice spent exactly 500 FXRP");
        emit log_named_decimal_uint("500 FXRP deposited -> arFXRP shares", shares, 18);
    }

    /// Before maturity the position is term-locked: nothing is withdrawable.
    function test_TermLocked_NoWithdrawBeforeMaturity() public {
        vm.prank(alice);
        uint256 shares = frv.deposit(500e18, alice);

        assertEq(frv.maxWithdraw(alice), 0, "maxWithdraw 0 before maturity");
        assertEq(frv.maxRedeem(alice), 0, "maxRedeem 0 before maturity");

        vm.prank(alice);
        vm.expectRevert(); // ERC4626ExceededMaxRedeem
        frv.redeem(shares, alice, alice);
    }

    /// At maturity the saver withdraws principal + the fixed gain, 1 share -> 1 FXRP.
    function test_Withdraw_AtMaturity_PrincipalPlusFixedGain() public {
        vm.prank(alice);
        uint256 shares = frv.deposit(500e18, alice);

        vm.warp(maturity + 1 days);
        assertEq(frv.maxRedeem(alice), shares, "all shares redeemable at maturity");

        vm.prank(alice);
        uint256 got = frv.redeem(shares, alice, alice);

        assertApproxEqAbs(got, shares, 1e6, "1 share redeems ~1 FXRP");
        // alice kept 500 FXRP (unspent) and withdrew ~shares back: 1000 start + the fixed gain
        assertApproxEqAbs(fxrp.balanceOf(alice), 1000e18 + (shares - 500e18), 1e6, "deposit + fixed gain back");
        assertEq(frv.balanceOf(alice), 0, "shares burned");
        emit log_named_decimal_uint("Alice withdrew (500 deposit + fixed gain)", fxrp.balanceOf(alice), 18);
    }

    /// The saver's outcome is fixed at entry, whatever the underlying vault actually earns.
    function test_RateLocked_IndependentOfYield() public {
        vm.prank(alice);
        uint256 shares = frv.deposit(500e18, alice);

        _pushYield(5000e18); // a big, surprising yield: it must NOT change the saver's outcome

        vm.warp(maturity + 1 days);
        vm.prank(alice);
        uint256 got = frv.redeem(shares, alice, alice);

        assertApproxEqAbs(got, shares, 1e6, "realized == locked, independent of yield");
        // the yield went to the YT holder (LP), not the saver
        assertGt(splitter.claimable(lp), 4000e18, "the variable yield accrued to YT, not to the saver");
    }

    /// Two savers entering at different times each keep their OWN locked rate; a later deposit
    /// cannot re-price an earlier one (this is the point of par-denominated shares).
    function test_TwoCohorts_EachKeepsOwnRate() public {
        vm.prank(alice);
        uint256 sharesA = frv.deposit(500e18, alice);

        vm.warp(block.timestamp + 30 days); // time passes, pool moved, discount shrank
        vm.prank(bob);
        uint256 sharesB = frv.deposit(500e18, bob);

        assertTrue(sharesA != sharesB, "different entry -> different locked amount");

        vm.warp(maturity + 1 days);
        vm.prank(alice);
        uint256 outA = frv.redeem(sharesA, alice, alice);
        vm.prank(bob);
        uint256 outB = frv.redeem(sharesB, bob, bob);

        // each redeems exactly what they locked; Bob's later entry did not touch Alice's payout
        assertApproxEqAbs(outA, sharesA, 1e6, "Alice keeps her locked rate");
        assertApproxEqAbs(outB, sharesB, 1e6, "Bob keeps his own locked rate");
        emit log_named_decimal_uint("Alice out (earlier, deeper discount)", outA, 18);
        emit log_named_decimal_uint("Bob out (later, shallower discount)", outB, 18);
    }

    /// ERC-4626 donation/inflation attack: inflating the share price by donating PT changes NOTHING
    /// a depositor gets (shares come from the AMM fill) nor what a redeemer is paid (par, per-PT).
    function test_DonationDoesNotChangeMintOrRedeem() public {
        vm.prank(alice);
        uint256 sharesA = frv.deposit(500e18, alice);

        // attacker donates PT straight into the vault, trying to inflate the share price
        vm.prank(lp);
        ptTok.transfer(address(frv), 100e18);
        // par accounting ties totalAssets to supply, so the donation moves the price by exactly nothing
        assertEq(frv.convertToAssets(1e18), 1e18, "share price stays 1:1 despite the donation");

        // a fresh deposit still mints the AMM-fill shares, NOT diluted by the inflated price
        (uint256 quote,) = anchor.previewLock(500e18);
        vm.prank(bob);
        uint256 sharesB = frv.deposit(500e18, bob);
        assertApproxEqAbs(sharesB, quote, 1e6, "deposit shares are donation-independent");

        // and at maturity each saver is paid par, per-PT, unaffected by the donation
        vm.warp(maturity + 1 days);
        vm.prank(alice);
        uint256 outA = frv.redeem(sharesA, alice, alice);
        assertApproxEqAbs(outA, sharesA, 1e6, "redemption pays par, donation gave the saver nothing extra");
    }

    /// Deposits close at maturity; mint() is disabled (savers use deposit()).
    function test_DepositsClosed_And_MintDisabled() public {
        vm.warp(maturity + 1);
        assertEq(frv.maxDeposit(alice), 0, "maxDeposit 0 after maturity");
        vm.prank(alice);
        vm.expectRevert(bytes("deposits closed at maturity"));
        frv.deposit(500e18, alice);

        vm.expectRevert(bytes("use deposit()"));
        frv.mint(1e18, alice);
    }

    /// Standard ERC-4626 surface is coherent.
    function test_4626Views() public {
        assertEq(frv.asset(), address(fxrp), "asset is FXRP");
        assertEq(frv.decimals(), 18, "shares mirror asset decimals");
        (uint256 quote,) = anchor.previewLock(500e18);
        assertEq(frv.previewDeposit(500e18), quote, "previewDeposit == live AMM quote");

        vm.prank(alice);
        uint256 shares = frv.deposit(500e18, alice);
        assertEq(frv.convertToAssets(shares), shares, "convertToAssets is par (1:1) for arFXRP");
    }

    /// Withdraw anytime: exiting right after depositing returns roughly the principal (you gave up the
    /// discount that only accretes to par at maturity), and matches the preview to the wei.
    function test_WithdrawEarly_Immediately() public {
        vm.prank(alice);
        uint256 shares = frv.deposit(500e18, alice);
        uint256 quote = frv.previewWithdrawEarly(shares);
        vm.prank(alice);
        uint256 out = frv.withdrawEarly(shares, 0);

        assertEq(out, quote, "early-withdraw pays the previewed amount");
        assertLt(out, shares, "below par: early exit trades the un-accreted discount for liquidity");
        assertApproxEqAbs(out, 500e18, 6e18, "immediate exit ~= what you deposited");
        assertEq(frv.balanceOf(alice), 0, "shares burned");
        emit log_named_decimal_uint("deposit 500 -> immediate early-withdraw", out, 18);
    }

    /// Near maturity the PT has accreted to par, so an early exit returns ~the full value.
    function test_WithdrawEarly_NearMaturity_ApproachesPar() public {
        vm.prank(alice);
        uint256 shares = frv.deposit(500e18, alice);
        vm.warp(maturity - 1);
        vm.prank(alice);
        uint256 out = frv.withdrawEarly(shares, 0);
        assertApproxEqAbs(out, shares, 2e18, "near maturity, early exit ~= par (full fixed value)");
        emit log_named_decimal_uint("near-maturity early-withdraw (~= par)", out, 18);
    }
}
