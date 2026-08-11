// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "forge-std/Test.sol";
import "../src/YieldSplitter.sol";
import "../src/interfaces/IERC4626.sol";

/**
 * FORK TEST — Anchor's YieldSplitter against a REAL, live XRPFi vault on Flare mainnet.
 *
 * Vault:  Bizantine FXRP SuperVault (bizFXRP) 0x34f9...3c16 — a genuine ERC-4626 vault
 *         over the canonical 6-decimal FXRP FAsset, with permissionless deposits and a
 *         strictly-increasing price-per-share. This proves the IERC4626 abstraction is
 *         real: swap MockVault for this address and the exact same splitter code works.
 *
 * Run:  forge test --match-path test/ForkVault.t.sol -vv
 *       (uses the public Flare RPC; pinned to a block for determinism)
 */
contract ForkVaultTest is Test {
    // canonical, on-chain-verified addresses (Flare mainnet, chainId 14)
    address constant FXRP = 0xAd552A648C74D49E10027AB8a618A3ad4901c5bE; // 6 decimals
    address constant BIZFXRP = 0x34f90DFA0F1B2F691EE3A3a87954f8D282193c16; // ERC-4626, permissionless
    address constant FXRP_WHALE = 0xD1b7A5eFa9bd88F291F7A4563a8f6185c0249CB3; // Kinetic isoFXRP market, ~20M idle FXRP
    uint256 constant FORK_BLOCK = 67150446;

    IERC20 fxrp = IERC20(FXRP);
    IERC4626 vault = IERC4626(BIZFXRP);
    YieldSplitter splitter;

    address user = makeAddr("user");
    uint256 constant DEPOSIT = 1000e6; // 1000 FXRP (6 decimals)

    function setUp() public {
        string memory rpc = vm.envOr("FLARE_RPC", string("https://flare-api.flare.network/ext/C/rpc"));
        vm.createSelectFork(rpc, FORK_BLOCK);
        splitter = new YieldSplitter(vault, block.timestamp + 90 days);
    }

    /// Proves Anchor's splitter binds to a REAL live ERC-4626 XRPFi vault: the interface
    /// reads the real chain, a real FXRP deposit round-trips into vault shares, and the
    /// position tracks the vault's real (yield-bearing) price-per-share.
    function test_Fork_RealVault_DepositIntegration() public {
        // sanity: our IERC4626 abstraction reads the real chain
        assertEq(fxrp.decimals(), 6, "FXRP is 6 decimals");
        assertEq(vault.asset(), FXRP, "vault underlying is the canonical FXRP");
        uint256 ppsE6 = vault.convertToAssets(1e6); // assets per 1e6 shares
        emit log_named_decimal_uint("Live bizFXRP price-per-share (FXRP/share)", ppsE6, 6);
        assertGe(ppsE6, 1e6, "PPS >= 1 (principal-preserving, yield-bearing)");

        // Fund the user with REAL FXRP by pranking a large holder (FAsset storage is
        // non-standard, so `deal` writes a slot the token's transfer logic doesn't use).
        vm.prank(FXRP_WHALE);
        fxrp.transfer(user, DEPOSIT);
        assertEq(fxrp.balanceOf(user), DEPOSIT, "user funded with real FXRP");

        // --- SPLIT: deposit into the REAL vault, mint PT + YT ---
        vm.startPrank(user);
        fxrp.approve(address(splitter), type(uint256).max);
        splitter.split(DEPOSIT);
        vm.stopPrank();

        assertEq(splitter.pt().balanceOf(user), DEPOSIT, "1000 PT minted");
        assertEq(splitter.yt().balanceOf(user), DEPOSIT, "1000 YT minted");

        // the splitter now holds real vault shares worth ~the principal
        uint256 held = vault.convertToAssets(vault.balanceOf(address(splitter)));
        emit log_named_decimal_uint("Position value in the live vault (FXRP)", held, 6);
        assertApproxEqRel(held, DEPOSIT, 0.001e18, "position ~= principal (<=0.1% vault rounding)");

        // --- Principal preservation at maturity ---
        // 1 PT is redeemable for its pro-rata share of vault assets, which never falls below
        // par (PPS is monotonic-up). We prove this via the vault's own converter after warping
        // to maturity. NOTE: *executing* the on-chain withdrawal is subject to each vault's
        // liquidity/withdraw mechanism — bizFXRP gates redemptions behind an off-chain
        // withdraw-price keeper (reverts INVALID_WITHDRAW_PRICE for a fresh fork depositor),
        // so the deterministic 1:1 redemption is proven in YieldSplitter.t.sol instead.
        vm.warp(block.timestamp + 91 days);
        uint256 redeemable = vault.convertToAssets(vault.balanceOf(address(splitter)));
        emit log_named_decimal_uint("PT redeemable value at maturity (FXRP)", redeemable, 6);
        assertGe(redeemable, (DEPOSIT * 999) / 1000, "PT still worth >= principal in the live vault");
    }
}
