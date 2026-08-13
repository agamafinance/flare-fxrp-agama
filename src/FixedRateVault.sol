// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// Anchor fixed-rate router surface the vault drives (token getters typed as address to avoid
/// clashing with OpenZeppelin's IERC20).
interface IAnchorVault {
    function fxrp() external view returns (address);
    function pt() external view returns (address);
    function amm() external view returns (address);
    function maturity() external view returns (uint256);
    function lockFixedRate(uint256 fxrpIn, uint256 minPtOut) external returns (uint256 ptOut);
    function previewLock(uint256 fxrpIn) external view returns (uint256 ptOut, uint256 aprE18);
    function redeem(uint256 ptAmount) external returns (uint256 fxrpOut);
}

/// The YieldSpace AMM, used for early exit (sell PT back to FXRP at the current market price).
interface IPtAmmVault {
    function swapPtForFxrp(uint256 dyIn, uint256 minFxrpOut, address to) external returns (uint256 dxOut);
    function previewPtForFxrp(uint256 dyIn) external view returns (uint256 dxOut);
}

/**
 * @title FixedRateVault  (Agama savings pool — ERC-4626 over the fixed-rate router)
 * @notice The saver-facing wrapper. Deposit FXRP, receive `arFXRP` shares, withdraw more at
 *         maturity. No PT, no YT, no AMM, no "buy/sell" in the UX: one deposit, one fixed rate,
 *         one withdrawal. It hides the whole PT/YT machinery behind a standard vault interface.
 *
 *         DESIGN: shares are PAR-DENOMINATED. One arFXRP share is one PT held by the vault, i.e.
 *         one FXRP redeemable 1:1 at maturity. A 500-FXRP deposit that buys 507 PT mints 507
 *         shares, and each share redeems for 1 FXRP at maturity. The fixed gain is realized as
 *         *extra shares at entry*, so every saver's rate is LOCKED AT ENTRY and no later deposit
 *         can dilute or re-price an earlier one. This is deliberately NOT a blended rising-NAV
 *         pool (where a single share price would average everyone's entry rate together and break
 *         the "fixed" promise).
 *
 *         Built on OpenZeppelin's audited ERC4626 / ERC20 / SafeERC20 / ReentrancyGuard. deposit()
 *         routes FXRP -> PT through Anchor; withdraw()/redeem() at maturity route PT -> FXRP back.
 *         Because shares are minted from the AMM's realized fill (not from a totalAssets/supply
 *         ratio), the vault is immune BY CONSTRUCTION to the ERC-4626 donation / inflation attack:
 *         no donation can change how many shares a deposit mints or how much a redemption pays.
 *
 *         Term-locked: deposits close at maturity, withdrawals open at maturity, both enforced
 *         through the standard max* guards. POC, not audited.
 */
contract FixedRateVault is ERC4626, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IAnchorVault public immutable anchor;
    IPtAmmVault public immutable amm;
    IERC20 public immutable pt;
    uint256 public immutable maturity;

    uint256 public constant PAR_FLOOR_BPS = 9900; // >= 99% of 1:1 par: non-manipulable slippage floor

    event EarlyWithdraw(address indexed owner, uint256 shares, uint256 assets);

    constructor(IAnchorVault _anchor)
        ERC20("Agama Fixed-Rate FXRP", "arFXRP")
        ERC4626(IERC20(_anchor.fxrp()))
    {
        anchor = _anchor;
        amm = IPtAmmVault(_anchor.amm());
        pt = IERC20(_anchor.pt());
        maturity = _anchor.maturity();
    }

    /* ----------------------- early exit (withdraw anytime) ------------------- */

    /// Current FXRP you would get by exiting NOW (selling your PT on the AMM at market). Below the
    /// maturity value (PT trades at a discount that only fully accretes to par at maturity), so holding
    /// to maturity earns the full fixed gain; exiting early trades some of it for immediate liquidity.
    function previewWithdrawEarly(uint256 shares) external view returns (uint256) {
        return amm.previewPtForFxrp(shares);
    }

    /// Exit before maturity at the current market price: burn shares, sell the matching PT on the AMM,
    /// send the FXRP to the caller. Makes the fixed-rate position fully liquid (withdraw whenever).
    function withdrawEarly(uint256 shares, uint256 minFxrpOut) external nonReentrant returns (uint256 assets) {
        require(shares > 0, "zero shares");
        _burn(msg.sender, shares); // reverts if the caller lacks the shares
        pt.forceApprove(address(amm), shares);
        assets = amm.swapPtForFxrp(shares, minFxrpOut, msg.sender);
        emit EarlyWithdraw(msg.sender, shares, assets);
    }

    /* ----------------------------- saver actions ----------------------------- */

    /// Deposit FXRP, lock the fixed rate, receive arFXRP shares (1 share = 1 FXRP at maturity).
    /// Shares minted == the AMM's realized PT fill, so the rate is locked from the actual trade.
    function deposit(uint256 assets, address receiver) public override nonReentrant returns (uint256 shares) {
        require(block.timestamp < maturity, "deposits closed at maturity");
        require(assets > 0, "zero assets");
        IERC20 fxrp = IERC20(asset());
        fxrp.safeTransferFrom(_msgSender(), address(this), assets);
        fxrp.forceApprove(address(anchor), assets);
        // A sandwich cannot push the saver below par-1%; PT trades <= par so a healthy fill is >= par.
        // Protecting the *discount* itself (not just par) would need a TWAP; documented as residual.
        shares = anchor.lockFixedRate(assets, (assets * PAR_FLOOR_BPS) / 10000);
        _mint(receiver, shares);
        emit Deposit(_msgSender(), receiver, assets, shares);
    }

    /// Exact-share minting is impractical against an AMM fill; savers use deposit().
    function mint(uint256, address) public pure override returns (uint256) {
        revert("use deposit()");
    }

    /// Redeem the matching PT 1:1 through Anchor and forward the realized FXRP to the saver.
    function _withdraw(address caller, address receiver, address owner_, uint256 assets, uint256 shares)
        internal
        override
    {
        assets; // OZ passes the idealized par value; we forward the realized FXRP from Anchor instead.
        if (caller != owner_) _spendAllowance(owner_, caller, shares);
        _burn(owner_, shares);
        pt.forceApprove(address(anchor), shares);
        uint256 got = anchor.redeem(shares); // PT -> FXRP 1:1 (pro-rata haircut only if impaired)
        IERC20(asset()).safeTransfer(receiver, got);
        emit Withdraw(caller, receiver, owner_, got, shares);
    }

    // Reentrancy-guard the OZ withdrawal entry points (they route into _withdraw above).
    function withdraw(uint256 assets, address receiver, address owner_) public override nonReentrant returns (uint256) {
        return super.withdraw(assets, receiver, owner_);
    }

    function redeem(uint256 shares, address receiver, address owner_) public override nonReentrant returns (uint256) {
        return super.redeem(shares, receiver, owner_);
    }

    /* --------------------------- views / quotes ------------------------------ */

    /// Par accounting: 1 share == 1 PT backing == 1 FXRP redeemable 1:1 at maturity, so totalAssets is
    /// exactly the shares outstanding. Deliberately NOT `pt.balanceOf(this)`: PT donated into the vault
    /// backs no share, so counting it would inflate the share price and hand later depositors' value to
    /// the donor. Tying totalAssets to supply makes the ERC-4626 donation/inflation attack a no-op.
    /// (This is a par/maturity mark; before maturity the position is illiquid, which maxWithdraw == 0
    /// signals.)
    function totalAssets() public view override returns (uint256) {
        return totalSupply();
    }

    /// Accurate deposit quote from the live AMM fill. May exceed the idealized convertToShares (the
    /// fixed-rate discount reads as "slippage" to the ratio); ERC-4626 permits preview != convert.
    function previewDeposit(uint256 assets) public view override returns (uint256 shares) {
        (shares,) = anchor.previewLock(assets);
    }

    /* --------------------------- term-lock gating ---------------------------- */

    function maxDeposit(address) public view override returns (uint256) {
        return block.timestamp < maturity ? type(uint256).max : 0;
    }

    function maxMint(address) public pure override returns (uint256) {
        return 0; // mint() disabled: exact-share minting is impractical against an AMM
    }

    function maxWithdraw(address owner_) public view override returns (uint256) {
        return block.timestamp >= maturity ? balanceOf(owner_) : 0; // 1 share = 1 asset at par
    }

    function maxRedeem(address owner_) public view override returns (uint256) {
        return block.timestamp >= maturity ? balanceOf(owner_) : 0;
    }
}
