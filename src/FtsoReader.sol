// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

interface IFlareContractRegistry {
    function getContractAddressByName(string calldata _name) external view returns (address);
}

interface IFtsoV2 {
    function getFeedById(bytes21 _feedId) external view returns (uint256 _value, int8 _decimals, uint64 _timestamp);
}

/**
 * @title FtsoReader
 * @notice Reads Flare's enshrined FTSOv2 price oracle. Used to denominate FXRP positions in USD
 *         (front-end and the confidential enclave), so Agama's fixed rate can be shown and reasoned
 *         about in dollars, not just XRP. The registry address is the same on every Flare network.
 */
contract FtsoReader {
    IFlareContractRegistry public constant REGISTRY = IFlareContractRegistry(0xaD67FE66660Fb8dFE9d6b1b4240d8650e30F6019);
    bytes21 public constant XRP_USD = 0x015852502f55534400000000000000000000000000;

    function ftso() public view returns (IFtsoV2) {
        return IFtsoV2(REGISTRY.getContractAddressByName("FtsoV2"));
    }

    /// Raw XRP/USD feed: value in `decimals` fixed point, with the feed timestamp.
    function xrpUsd() public view returns (uint256 value, int8 decimals, uint64 timestamp) {
        return ftso().getFeedById(XRP_USD);
    }

    /// XRP/USD normalized to 1e18 (e.g. 1.006e18 for $1.006).
    function xrpUsd1e18() public view returns (uint256) {
        (uint256 v, int8 d,) = xrpUsd();
        return v * 1e18 / (10 ** uint256(uint8(d)));
    }

    /// USD value (1e18) of an FXRP amount given in 6 decimals.
    function usdValue(uint256 fxrpAmount6) external view returns (uint256 usd1e18) {
        usd1e18 = fxrpAmount6 * xrpUsd1e18() / 1e6;
    }
}
