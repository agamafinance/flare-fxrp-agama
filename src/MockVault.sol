// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "./interfaces/IERC4626.sol";

/**
 * @title MockVault
 * @notice Standard ERC-4626-lite yield-bearing vault standing in for a real XRPFi vault
 *         (Upshift earnXRP / Kinetic kFXRP / Firelight stXRP). Implements the exact
 *         EIP-4626 surface Anchor codes against, so swapping in a real vault is a
 *         one-line constructor change. Yield is simulated by addYield(): FXRP is added
 *         without minting shares, so price-per-share grows (a test-only helper, not 4626).
 */
contract MockVault is IERC4626 {
    IERC20 public immutable underlying; // FXRP
    uint256 public totalShares;
    uint256 public totalAssetsHeld; // FXRP under management
    mapping(address => uint256) public balanceOf; // share ledger
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(IERC20 _asset) {
        underlying = _asset;
    }

    /* ------------------------------- ERC-4626 -------------------------------- */

    function asset() external view returns (address) {
        return address(underlying);
    }

    function totalAssets() external view returns (uint256) {
        return totalAssetsHeld;
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        underlying.transferFrom(msg.sender, address(this), assets);
        shares = (totalShares == 0 || totalAssetsHeld == 0) ? assets : (assets * totalShares) / totalAssetsHeld;
        totalShares += shares;
        totalAssetsHeld += assets;
        balanceOf[receiver] += shares;
    }

    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets) {
        if (owner != msg.sender) {
            uint256 al = allowance[owner][msg.sender];
            if (al != type(uint256).max) allowance[owner][msg.sender] = al - shares;
        }
        assets = convertToAssets(shares);
        balanceOf[owner] -= shares;
        totalShares -= shares;
        totalAssetsHeld -= assets;
        underlying.transfer(receiver, assets);
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        return totalShares == 0 ? shares : (shares * totalAssetsHeld) / totalShares;
    }

    function convertToShares(uint256 assets) public view returns (uint256) {
        return totalAssetsHeld == 0 ? assets : (assets * totalShares) / totalAssetsHeld;
    }

    /* ----------------------- ERC20 (vault shares) ---------------------------- */

    function totalSupply() external view returns (uint256) {
        return totalShares;
    }

    function decimals() external pure returns (uint8) {
        return 18;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 al = allowance[from][msg.sender];
        if (al != type(uint256).max) allowance[from][msg.sender] = al - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    /* ------------------------------ test helper ------------------------------ */

    /// Simulate yield: FXRP flows in, no new shares -> price-per-share rises.
    function addYield(uint256 amount) external {
        underlying.transferFrom(msg.sender, address(this), amount);
        totalAssetsHeld += amount;
    }
}
