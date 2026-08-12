// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "forge-std/Test.sol";
import "../src/MockERC20.sol";
import "../src/MockVault.sol";
import "../src/YieldSplitter.sol";

contract YieldSplitterTest is Test {
    MockERC20 fxrp;
    MockVault vault;
    YieldSplitter splitter;
    SplitToken ptTok;
    SplitToken ytTok;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address yielder = makeAddr("yielder"); // simulates the XRPFi vault earning yield

    uint256 constant PRINCIPAL = 1000e18;
    uint256 constant YIELD = 100e18; // 10% yield over the term

    function setUp() public {
        fxrp = new MockERC20("Flare XRP", "FXRP", 18);
        vm.prank(yielder); // yielder owns the vault, so it can simulate yield via addYield
        vault = new MockVault(fxrp);
        splitter = new YieldSplitter(vault, block.timestamp + 90 days);
        ptTok = splitter.pt();
        ytTok = splitter.yt();

        fxrp.mint(alice, PRINCIPAL);
        fxrp.mint(bob, PRINCIPAL);
        fxrp.mint(yielder, YIELD * 2);

        vm.prank(alice);
        fxrp.approve(address(splitter), type(uint256).max);
        vm.prank(bob);
        fxrp.approve(address(splitter), type(uint256).max);
        vm.prank(yielder);
        fxrp.approve(address(vault), type(uint256).max);
    }

    function _earn(uint256 amount) internal {
        vm.prank(yielder);
        vault.addYield(amount);
    }

    /// Deposit -> yield accrues -> YT claims the yield -> maturity -> PT redeems principal.
    function test_1_FullLifecycle() public {
        vm.prank(alice);
        splitter.split(PRINCIPAL);
        assertEq(ptTok.balanceOf(alice), PRINCIPAL, "1000 PT");
        assertEq(ytTok.balanceOf(alice), PRINCIPAL, "1000 YT");

        _earn(YIELD); // vault price-per-share rises 10%

        emit log_named_decimal_uint("Yield claimable by Alice (holds all YT)", splitter.claimable(alice), 18);
        assertApproxEqAbs(splitter.claimable(alice), YIELD, 1e6, "claimable ~= 100");

        vm.prank(alice);
        uint256 gotYield = splitter.claimYield();
        assertApproxEqAbs(gotYield, YIELD, 1e6, "claimed ~= 100 FXRP");

        vm.warp(block.timestamp + 91 days);
        vm.prank(alice);
        uint256 gotPrincipal = splitter.redeemPrincipal(PRINCIPAL);
        assertApproxEqAbs(gotPrincipal, PRINCIPAL, 1e6, "PT redeems ~= 1000 principal");

        // Alice: started 1000, deposited it, got back principal 1000 + yield 100 = 1100
        assertApproxEqAbs(fxrp.balanceOf(alice), PRINCIPAL + YIELD, 1e6, "Alice ends ~1100 FXRP");
        emit log_named_decimal_uint("Alice final FXRP (1000 principal + 100 yield)", fxrp.balanceOf(alice), 18);
    }

    /// The product story: sell your YT -> you keep PT -> you LOCKED certainty; the buyer takes the upside.
    function test_2_SellYT_LocksCertainty() public {
        vm.prank(alice);
        splitter.split(PRINCIPAL); // Alice holds 1000 PT + 1000 YT

        // Alice sells her yield: transfers all YT to Bob (the yield-seeker).
        vm.prank(alice);
        ytTok.transfer(bob, PRINCIPAL);

        _earn(YIELD);

        // Certainty side (Alice, holds PT only): no yield exposure.
        assertEq(splitter.claimable(alice), 0, "Alice locked certainty, no yield");
        // Upside side (Bob, holds YT): captures ALL the yield.
        assertApproxEqAbs(splitter.claimable(bob), YIELD, 1e6, "Bob takes the upside");

        vm.prank(bob);
        uint256 bobYield = splitter.claimYield();
        assertApproxEqAbs(bobYield, YIELD, 1e6, "Bob claims ~100");

        vm.warp(block.timestamp + 91 days);
        vm.prank(alice);
        uint256 aliceOut = splitter.redeemPrincipal(PRINCIPAL);
        assertApproxEqAbs(aliceOut, PRINCIPAL, 1e6, "Alice gets exactly her principal back");

        emit log_named_decimal_uint("Alice (certainty) out", aliceOut, 18);
        emit log_named_decimal_uint("Bob (upside) yield", bobYield, 18);
    }

    /// Yield accounting stays correct when YT changes hands mid-term.
    function test_3_YieldSplitsCorrectlyOnTransfer() public {
        vm.prank(alice);
        splitter.split(PRINCIPAL); // Alice: 1000 YT

        _earn(YIELD); // first 100 accrues entirely to Alice

        // Alice moves half her YT to Bob AFTER earning the first slug.
        vm.prank(alice);
        ytTok.transfer(bob, PRINCIPAL / 2);

        _earn(YIELD); // second 100 splits 50/50 (each holds 500 YT)

        // Alice: 100 (pre-transfer) + 50 = 150 ; Bob: 50
        assertApproxEqAbs(splitter.claimable(alice), 150e18, 1e6, "Alice ~150");
        assertApproxEqAbs(splitter.claimable(bob), 50e18, 1e6, "Bob ~50");
        emit log_named_decimal_uint("Alice claimable (100 solo + 50 shared)", splitter.claimable(alice), 18);
        emit log_named_decimal_uint("Bob claimable (50 shared)", splitter.claimable(bob), 18);
    }
}
