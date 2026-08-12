// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "./interfaces/IERC4626.sol";
import "./SplitToken.sol";

/**
 * @title YieldSplitter  (Anchor's core primitive — a mini Pendle/Spectra, self-contained)
 * @notice Deposit FXRP into a yield-bearing XRPFi vault and split the position into:
 *           - PT (Principal Token): redeemable 1:1 for your principal at maturity  -> CERTAINTY
 *           - YT (Yield Token): captures ALL the yield until maturity               -> UPSIDE
 *         Hold PT to lock certainty (sell your YT to fix a return), or hold YT to ride the yield.
 *         No AMM, no external protocol, no undocumented dependency. FXRP + a vault + this contract.
 *         POC — not audited.
 */
contract YieldSplitter is ISplitterHook {
    IERC4626 public immutable vault;
    IERC20 public immutable fxrp;
    SplitToken public immutable pt;
    SplitToken public immutable yt;
    uint256 public immutable maturity;

    uint256 public totalPrincipal; // == PT supply == YT supply
    uint256 public totalYieldClaimed; // FXRP paid out to YT holders

    // MasterChef-style yield accounting
    uint256 public accYieldPerYT; // scaled 1e18
    uint256 public lastYieldTotal; // total yield ever generated (monotonic)
    uint256 public yieldFinal; // yield total frozen at maturity (YT stops accruing after)
    bool public yieldFinalized;
    mapping(address => uint256) public yieldDebt;
    mapping(address => uint256) public pendingClaim;

    event Split(address indexed user, uint256 principal);
    event YieldClaimed(address indexed user, uint256 amount);
    event PrincipalRedeemed(address indexed user, uint256 amount);

    constructor(IERC4626 _vault, uint256 _maturity) {
        vault = _vault;
        fxrp = IERC20(_vault.asset());
        maturity = _maturity;
        uint8 dec = IERC20(_vault.asset()).decimals();
        pt = new SplitToken("Anchor Principal FXRP", "PT-FXRP", dec, address(this), false);
        yt = new SplitToken("Anchor Yield FXRP", "YT-FXRP", dec, address(this), true);
    }

    /* --------------------------- yield accounting ---------------------------- */

    function _currentYieldTotal() internal view returns (uint256) {
        uint256 held = vault.convertToAssets(vault.balanceOf(address(this)));
        uint256 gross = held + totalYieldClaimed;
        return gross <= totalPrincipal ? totalYieldClaimed : gross - totalPrincipal;
    }

    function _updateGlobal() internal {
        uint256 cur = _currentYieldTotal();
        if (block.timestamp >= maturity) {
            if (!yieldFinalized) { yieldFinalized = true; yieldFinal = cur; } // YT stops accruing at maturity
            cur = yieldFinal;
        }
        if (cur <= lastYieldTotal) return; // never ratchet down: a share-price dip must not re-count on recovery
        uint256 supply = yt.totalSupply();
        if (supply == 0) return; // no YT holders yet: defer this band instead of advancing past it (not stranded)
        accYieldPerYT += ((cur - lastYieldTotal) * 1e18) / supply;
        lastYieldTotal = cur; // advance only once the band is actually distributed
    }

    function _accrue(address user) internal {
        _updateGlobal();
        uint256 acc = (yt.balanceOf(user) * accYieldPerYT) / 1e18;
        pendingClaim[user] += acc - yieldDebt[user];
        yieldDebt[user] = acc;
    }

    function _setDebt(address user) internal {
        yieldDebt[user] = (yt.balanceOf(user) * accYieldPerYT) / 1e18;
    }

    // hooks called by the YT token on every transfer (settle both parties)
    function ytSettle(address user) external {
        require(msg.sender == address(yt), "only yt");
        _accrue(user);
    }

    function ytResetDebt(address user) external {
        require(msg.sender == address(yt), "only yt");
        _setDebt(user);
    }

    /* ------------------------------- actions --------------------------------- */

    /// Deposit FXRP -> get equal PT + YT (principal = amount deposited).
    function split(uint256 fxrpAmount) external {
        _accrue(msg.sender);
        require(fxrp.transferFrom(msg.sender, address(this), fxrpAmount), "fxrp in");
        fxrp.approve(address(vault), fxrpAmount);
        require(vault.deposit(fxrpAmount, address(this)) > 0, "no shares"); // reject a 0-share inflation deposit
        pt.mint(msg.sender, fxrpAmount);
        yt.mint(msg.sender, fxrpAmount);
        totalPrincipal += fxrpAmount;
        _setDebt(msg.sender);
        emit Split(msg.sender, fxrpAmount);
    }

    /// YT holder claims accrued yield in FXRP.
    function claimYield() external returns (uint256 got) {
        _accrue(msg.sender);
        // principal is senior: never pay out yield that would leave the vault below outstanding
        // principal (a reversed share-price mark must not let YT drain PT's backing).
        uint256 held = vault.convertToAssets(vault.balanceOf(address(this)));
        uint256 surplus = held > totalPrincipal ? held - totalPrincipal : 0;
        uint256 amt = pendingClaim[msg.sender];
        if (amt > surplus) amt = surplus;
        pendingClaim[msg.sender] -= amt;
        if (amt > 0) {
            uint256 shares = vault.convertToShares(amt);
            got = vault.redeem(shares, msg.sender, address(this));
            totalYieldClaimed += got;
            emit YieldClaimed(msg.sender, got);
        }
    }

    /// After maturity: PT holder redeems principal 1:1 in FXRP.
    function redeemPrincipal(uint256 ptAmount) external returns (uint256 got) {
        require(block.timestamp >= maturity, "not matured");
        _updateGlobal();
        // pro-rata haircut: if the vault is impaired below principal, losses are socialized pari passu
        // instead of first-come-first-served. PT is capped at par (any surplus above principal is YT's).
        uint256 held = vault.convertToAssets(vault.balanceOf(address(this)));
        uint256 backing = held < totalPrincipal ? held : totalPrincipal;
        uint256 assetsOut = totalPrincipal == 0 ? 0 : (ptAmount * backing) / totalPrincipal;
        pt.burn(msg.sender, ptAmount);
        totalPrincipal -= ptAmount;
        got = vault.redeem(vault.convertToShares(assetsOut), msg.sender, address(this));
        emit PrincipalRedeemed(msg.sender, got);
    }

    /// Before maturity: recombine equal PT+YT back into FXRP (exit early).
    function recombine(uint256 amount) external returns (uint256 got) {
        _accrue(msg.sender);
        uint256 held = vault.convertToAssets(vault.balanceOf(address(this)));
        uint256 backing = held < totalPrincipal ? held : totalPrincipal; // same pro-rata haircut as redeem
        uint256 assetsOut = totalPrincipal == 0 ? 0 : (amount * backing) / totalPrincipal;
        pt.burn(msg.sender, amount);
        yt.burn(msg.sender, amount);
        totalPrincipal -= amount;
        _setDebt(msg.sender);
        got = vault.redeem(vault.convertToShares(assetsOut), msg.sender, address(this));
    }

    /* -------------------------------- views ---------------------------------- */

    /// Yield currently claimable by a YT holder (view).
    function claimable(address user) external view returns (uint256) {
        uint256 held = vault.convertToAssets(vault.balanceOf(address(this)));
        uint256 gross = held + totalYieldClaimed;
        uint256 cur = gross <= totalPrincipal ? totalYieldClaimed : gross - totalPrincipal;
        if (yieldFinalized) cur = yieldFinal; // yield frozen at maturity
        uint256 acc = accYieldPerYT;
        uint256 supply = yt.totalSupply();
        if (supply > 0 && cur > lastYieldTotal) acc += ((cur - lastYieldTotal) * 1e18) / supply;
        uint256 owed = (yt.balanceOf(user) * acc) / 1e18;
        return pendingClaim[user] + (owed - yieldDebt[user]);
    }
}
