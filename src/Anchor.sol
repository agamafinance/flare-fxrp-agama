// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "./YieldSplitter.sol";
import "./PtAmm.sol";
import "@prb/math/src/UD60x18.sol";

/**
 * @title Anchor — the user-facing router for the fixed-rate product.
 * @notice One call locks a fixed rate: deposit FXRP, buy PT at a discount on the YieldSpace
 *         AMM, and receive the PT (certainty). At maturity, redeem PT 1:1 for principal.
 *         Wraps the YieldSplitter (PT/YT engine over a real ERC-4626 XRPFi vault) and the
 *         PtAmm (real YieldSpace AMM) behind a single, front-end-friendly surface.
 *         POC — not audited.
 */
contract Anchor {
    YieldSplitter public immutable splitter;
    PtAmm public immutable amm;
    IERC20 public immutable fxrp;
    SplitToken public immutable pt;
    uint256 public immutable maturity;

    event RateLocked(address indexed user, uint256 fxrpIn, uint256 ptOut, uint256 impliedAprE18);
    event Redeemed(address indexed user, uint256 ptIn, uint256 fxrpOut);

    constructor(YieldSplitter _splitter, PtAmm _amm) {
        splitter = _splitter;
        amm = _amm;
        fxrp = _splitter.fxrp();
        pt = _splitter.pt();
        maturity = _splitter.maturity();
        require(address(_amm.pt()) == address(pt), "pt mismatch");
        require(address(_amm.fxrp()) == address(fxrp), "fxrp mismatch");
    }

    /// Quote for the front-end: PT received and the fixed APR (1e18) locked at the current price.
    function previewLock(uint256 fxrpIn) external view returns (uint256 ptOut, uint256 impliedAprE18) {
        ptOut = amm.previewFxrpForPt(fxrpIn);
        impliedAprE18 = _realizedApr(fxrpIn, ptOut); // rate from the actual fill, not the pre-trade spot
    }

    /// One call: deposit FXRP, buy PT at a discount, lock a fixed rate. PT goes to the user.
    function lockFixedRate(uint256 fxrpIn, uint256 minPtOut) external returns (uint256 ptOut) {
        require(fxrp.transferFrom(msg.sender, address(this), fxrpIn), "fxrp in");
        fxrp.approve(address(amm), fxrpIn);
        ptOut = amm.swapFxrpForPt(fxrpIn, minPtOut, msg.sender);
        // report the REALIZED rate from the actual fill, not the pre-trade spot (which overstates it)
        emit RateLocked(msg.sender, fxrpIn, ptOut, _realizedApr(fxrpIn, ptOut));
    }

    /// APR actually locked: PT redeems 1:1 at maturity, so return = (ptOut/fxrpIn)^(1/T) - 1.
    function _realizedApr(uint256 fxrpIn, uint256 ptOut) internal view returns (uint256) {
        UD60x18 T = amm.yearsToMaturity();
        if (T.unwrap() == 0 || ptOut <= fxrpIn || fxrpIn == 0) return 0;
        UD60x18 ratio = ud(ptOut * 1e18 / fxrpIn);
        return ratio.pow(ud(1e18).div(T)).sub(ud(1e18)).unwrap();
    }

    /// After maturity: redeem PT 1:1 for FXRP principal. User must approve PT to Anchor first.
    function redeem(uint256 ptAmount) external returns (uint256 fxrpOut) {
        pt.transferFrom(msg.sender, address(this), ptAmount);
        fxrpOut = splitter.redeemPrincipal(ptAmount);
        fxrp.transfer(msg.sender, fxrpOut);
        emit Redeemed(msg.sender, ptAmount, fxrpOut);
    }
}
