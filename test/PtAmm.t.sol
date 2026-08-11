// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "forge-std/Test.sol";
import "../src/MockERC20.sol";
import "../src/MockVault.sol";
import "../src/YieldSplitter.sol";
import "../src/PtAmm.sol";

contract PtAmmTest is Test {
    MockERC20 fxrp;
    MockVault vault;
    YieldSplitter splitter;
    SplitToken ptTok;
    PtAmm amm;

    address lp = makeAddr("lp");
    address alice = makeAddr("alice");

    uint256 constant MATURITY_DAYS = 90;

    function setUp() public {
        fxrp = new MockERC20("Flare XRP", "FXRP", 18);
        vault = new MockVault(fxrp);
        uint256 maturity = block.timestamp + MATURITY_DAYS * 1 days;
        splitter = new YieldSplitter(vault, maturity);
        ptTok = splitter.pt();

        // time stretch = 1.0  -> at 90d, t = 90/365 ≈ 0.247 (exponent a ≈ 0.753). lp is the single LP (owner).
        vm.prank(lp);
        amm = new PtAmm(IERC20Min(address(fxrp)), IERC20Min(address(ptTok)), maturity, 1e18);

        // LP gets PT by splitting, then seeds a DEEP pool with more PT than FXRP (creates the discount).
        fxrp.mint(lp, 25000e18);
        vm.startPrank(lp);
        fxrp.approve(address(splitter), type(uint256).max);
        splitter.split(11000e18); // lp gets 11000 PT + 11000 YT
        fxrp.approve(address(amm), type(uint256).max);
        ptTok.approve(address(amm), type(uint256).max);
        amm.addLiquidity(10000e18, 10500e18); // 10k FXRP + 10.5k PT -> PT trades < 1 (~5% APR)
        vm.stopPrank();

        fxrp.mint(alice, 500e18);
        vm.prank(alice);
        fxrp.approve(address(amm), type(uint256).max);
    }

    function test_1_PtTradesAtDiscount_ImpliedFixedRate() public {
        uint256 price = amm.ptPrice();
        uint256 apr = amm.impliedApr();
        emit log_named_decimal_uint("PT spot price (FXRP per PT)", price, 18);
        emit log_named_decimal_uint("Implied FIXED APR", apr, 18);
        assertLt(price, 1e18, "PT should trade below par (a discount)");
        assertGt(apr, 0, "implied fixed rate > 0");
    }

    function test_2_BuyPT_LocksFixedRate() public {
        uint256 aprBefore = amm.impliedApr();

        uint256 paid = 50e18;
        vm.prank(alice);
        uint256 ptOut = amm.swapFxrpForPt(paid, 0, alice);

        emit log_named_decimal_uint("Alice paid FXRP", paid, 18);
        emit log_named_decimal_uint("Alice received PT", ptOut, 18);
        emit log_named_decimal_uint("APR she locked (~)", aprBefore, 18);

        // Discount => she gets MORE PT than the FXRP she paid; each PT redeems 1 FXRP at maturity.
        assertGt(ptOut, paid, "got more PT than FXRP paid = a positive locked yield");

        // Her locked return over the term = ptOut/paid - 1
        uint256 lockedReturn = (ptOut * 1e18) / paid - 1e18;
        emit log_named_decimal_uint("Locked return over the 90d term", lockedReturn, 18);
        assertGt(lockedReturn, 0, "positive fixed return locked at purchase");
    }

    function test_3_PtConvergesToPar_AtMaturity() public {
        uint256 priceStart = amm.ptPrice();

        vm.warp(block.timestamp + (MATURITY_DAYS - 1) * 1 days); // 1 day before maturity
        uint256 priceNear = amm.ptPrice();

        vm.warp(block.timestamp + 2 days); // past maturity
        uint256 priceAt = amm.ptPrice();

        emit log_named_decimal_uint("PT price at start (discount)", priceStart, 18);
        emit log_named_decimal_uint("PT price 1 day before maturity", priceNear, 18);
        emit log_named_decimal_uint("PT price at/after maturity", priceAt, 18);

        assertLt(priceStart, priceNear, "PT price rises toward par as maturity nears");
        assertApproxEqAbs(priceAt, 1e18, 1e12, "PT == par (1:1) at maturity");
    }

    /// The single LP (owner) can withdraw seeded liquidity, so funds are not permanently locked; a
    /// non-owner cannot add or remove.
    function test_4_OwnerCanRemoveLiquidity() public {
        uint256 fxrpBefore = fxrp.balanceOf(lp);
        vm.prank(lp);
        amm.removeLiquidity(5000e18, 5250e18); // pull half of the seeded pool
        assertEq(fxrp.balanceOf(lp) - fxrpBefore, 5000e18, "lp got FXRP back");
        assertEq(amm.fxrpReserve(), 5000e18, "reserve decreased");

        vm.prank(alice);
        vm.expectRevert(bytes("only owner"));
        amm.removeLiquidity(1, 1);
        vm.prank(alice);
        vm.expectRevert(bytes("only owner"));
        amm.addLiquidity(1, 1);
    }
}
