// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "@prb/math/src/UD60x18.sol";

interface IERC20Min {
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
    function decimals() external view returns (uint8);
}

/**
 * @title PtAmm — a real YieldSpace AMM for  PT <-> FXRP
 * @notice Invariant:  x^(1-t) + y^(1-t) = k   with  x = FXRP reserve, y = PT reserve,
 *         t = (years-to-maturity) * timeStretch  (clamped to [0, 0.95]).
 *         As maturity approaches, t -> 0 and the invariant collapses to constant-sum
 *         (x + y = k), so PT mechanically converges to par (1:1). This is the AMM used
 *         by Yield Protocol / Sense / Element for principal tokens.
 *
 *         Buying PT with FXRP hands you PT at a DISCOUNT -> a fixed rate locked at purchase.
 *
 *         Token amounts are in each token's native decimals (real FXRP = 6). Internally the
 *         curve math runs in 18-decimal fixed point (PRBMath UD60x18): reserves are scaled
 *         up by SCALE_X/SCALE_Y before every pow(), and outputs scaled back down.
 *         POC — unaudited, no fees, single LP position for clarity.
 */
contract PtAmm {
    IERC20Min public immutable fxrp;
    IERC20Min public immutable pt;
    uint256 public immutable maturity;
    UD60x18 public immutable ts; // value of t at 1 year to maturity

    uint256 public immutable SCALE_X; // 10^(18 - fxrpDecimals)  -> normalize FXRP to 1e18
    uint256 public immutable SCALE_Y; // 10^(18 - ptDecimals)    -> normalize PT to 1e18

    uint256 public fxrpReserve; // in FXRP token units
    uint256 public ptReserve; // in PT token units

    uint256 public constant SECONDS_PER_YEAR = 365 days;

    event Swap(address indexed who, bool fxrpIn, uint256 amountIn, uint256 amountOut);
    event Liquidity(uint256 fxrp, uint256 pt);

    constructor(IERC20Min _fxrp, IERC20Min _pt, uint256 _maturity, uint256 _timeStretchE18) {
        fxrp = _fxrp;
        pt = _pt;
        maturity = _maturity;
        ts = ud(_timeStretchE18);
        SCALE_X = 10 ** (18 - _fxrp.decimals());
        SCALE_Y = 10 ** (18 - _pt.decimals());
    }

    /* ------------------------------ curve helpers ---------------------------- */

    function yearsToMaturity() public view returns (UD60x18) {
        if (block.timestamp >= maturity) return ud(0);
        return ud(((maturity - block.timestamp) * 1e18) / SECONDS_PER_YEAR);
    }

    /// exponent a = 1 - t, with t = yearsToMaturity * ts, clamped so a in [0.05, 1].
    function _a() internal view returns (UD60x18) {
        UD60x18 t = yearsToMaturity().mul(ts);
        if (t.unwrap() > 0.95e18) t = ud(0.95e18);
        return ud(1e18).sub(t);
    }

    // normalized (1e18) reserves for the curve math
    function _xN() internal view returns (UD60x18) {
        return ud(fxrpReserve * SCALE_X);
    }

    function _yN() internal view returns (UD60x18) {
        return ud(ptReserve * SCALE_Y);
    }

    /* -------------------------------- liquidity ------------------------------ */

    /// Pull `amt` of a token in, checking the transfer succeeded and crediting the MEASURED delta.
    /// Fee-on-transfer tokens (which would under-collateralize the pool) are rejected.
    function _pull(IERC20Min t, address from, uint256 amt) internal returns (uint256 got) {
        uint256 b0 = t.balanceOf(address(this));
        require(t.transferFrom(from, address(this), amt), "transfer in");
        got = t.balanceOf(address(this)) - b0;
        require(got == amt, "fee-on-transfer unsupported");
    }

    function addLiquidity(uint256 dxFxrp, uint256 dyPt) external {
        fxrpReserve += _pull(fxrp, msg.sender, dxFxrp);
        ptReserve += _pull(pt, msg.sender, dyPt);
        emit Liquidity(dxFxrp, dyPt);
    }

    /* --------------------------------- swaps --------------------------------- */

    /// Read-only quote: PT received for `dxIn` FXRP at the current state (for front-ends). Rounds the
    /// output DOWN (reserve retained rounded up), matching swapFxrpForPt so the quote is not optimistic.
    function previewFxrpForPt(uint256 dxIn) public view returns (uint256 dyOut) {
        UD60x18 a = _a();
        UD60x18 rhs = _xN().pow(a).add(_yN().pow(a)).sub(_xN().add(ud(dxIn * SCALE_X)).pow(a));
        uint256 yNewTokens = (rhs.pow(ud(1e18).div(a)).unwrap() + SCALE_Y - 1) / SCALE_Y; // ceil -> output rounds down
        dyOut = ptReserve - yNewTokens;
    }

    /// Swap exact FXRP in for PT out. This is how a user LOCKS a fixed rate.
    function swapFxrpForPt(uint256 dxIn, uint256 minPtOut, address to) external returns (uint256 dyOut) {
        UD60x18 a = _a();
        // solve (x+dx)^a + (y-dy)^a = x^a + y^a  ->  (y-dy) = ( x^a + y^a - (x+dx)^a )^(1/a)
        UD60x18 rhs = _xN().pow(a).add(_yN().pow(a)).sub(_xN().add(ud(dxIn * SCALE_X)).pow(a));
        uint256 yNewTokens = (rhs.pow(ud(1e18).div(a)).unwrap() + SCALE_Y - 1) / SCALE_Y; // retain rounded UP (pool favor)
        dyOut = ptReserve - yNewTokens;
        require(dyOut >= minPtOut, "slippage");
        require(dyOut < ptReserve, "insufficient liquidity");
        _pull(fxrp, msg.sender, dxIn);
        fxrpReserve += dxIn;
        ptReserve -= dyOut;
        require(pt.transfer(to, dyOut), "pt out");
        emit Swap(msg.sender, true, dxIn, dyOut);
    }

    /// Swap exact PT in for FXRP out.
    function swapPtForFxrp(uint256 dyIn, uint256 minFxrpOut, address to) external returns (uint256 dxOut) {
        UD60x18 a = _a();
        UD60x18 rhs = _xN().pow(a).add(_yN().pow(a)).sub(_yN().add(ud(dyIn * SCALE_Y)).pow(a));
        uint256 xNewTokens = (rhs.pow(ud(1e18).div(a)).unwrap() + SCALE_X - 1) / SCALE_X; // retain rounded UP (pool favor)
        dxOut = fxrpReserve - xNewTokens;
        require(dxOut >= minFxrpOut, "slippage");
        require(dxOut < fxrpReserve, "insufficient liquidity");
        _pull(pt, msg.sender, dyIn);
        ptReserve += dyIn;
        fxrpReserve -= dxOut;
        require(fxrp.transfer(to, dxOut), "fxrp out");
        emit Swap(msg.sender, false, dyIn, dxOut);
    }

    /* -------------------------------- pricing -------------------------------- */

    /// Marginal spot price of 1 PT in FXRP (1e18-scaled): P = (x/y)^t.  < 1 = discount.
    function ptPrice() public view returns (uint256) {
        UD60x18 t = ud(1e18).sub(_a());
        return _xN().div(_yN()).pow(t).unwrap();
    }

    /// Fixed APR (1e18) locked when buying PT at the current spot price:  r = (1/P)^(1/T) - 1.
    function impliedApr() external view returns (uint256) {
        UD60x18 T = yearsToMaturity();
        if (T.unwrap() == 0) return 0;
        uint256 P = ptPrice();
        if (P >= 1e18) return 0; // PT at/above par (premium): implied rate <= 0, clamp instead of reverting
        return ud(1e18).div(ud(P)).pow(ud(1e18).div(T)).sub(ud(1e18)).unwrap();
    }
}
