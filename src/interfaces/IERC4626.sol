// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

/// Minimal ERC20 surface Anchor needs from the underlying asset (FXRP) and vault shares.
interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function decimals() external view returns (uint8);
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/**
 * @notice The standard ERC-4626 surface Anchor's YieldSplitter depends on.
 *         By coding against this (not a concrete MockVault), plugging a REAL XRPFi
 *         vault becomes a single constructor-arg swap. If a target vault is not
 *         standard ERC-4626, a thin adapter that implements this interface wraps it.
 *         Signatures match EIP-4626 exactly (redeem/withdraw carry the `owner` arg).
 */
interface IERC4626 is IERC20 {
    function asset() external view returns (address);
    function totalAssets() external view returns (uint256);
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);
    function convertToAssets(uint256 shares) external view returns (uint256 assets);
    function convertToShares(uint256 assets) external view returns (uint256 shares);
}
