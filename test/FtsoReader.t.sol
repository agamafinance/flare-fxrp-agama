// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "forge-std/Test.sol";
import "../src/FtsoReader.sol";

/**
 * Reads the live enshrined FTSOv2 oracle on a Coston2 fork: resolves FtsoV2 through the registry
 * and reads XRP/USD, then denominates an FXRP amount in USD.
 *   forge test --match-path test/FtsoReader.t.sol -vv
 */
contract FtsoReaderTest is Test {
    FtsoReader reader;

    function setUp() public {
        vm.createSelectFork(vm.envOr("COSTON2_RPC", string("https://coston2-api.flare.network/ext/C/rpc")));
        reader = new FtsoReader();
    }

    function test_Ftso_ReadsXrpUsdLive() public {
        (uint256 value, int8 decimals, uint64 ts) = reader.xrpUsd();
        emit log_named_uint("XRP/USD raw value", value);
        emit log_named_int("decimals", decimals);
        assertGt(value, 0, "feed has a value");
        assertGt(ts, 0, "feed has a timestamp");

        uint256 px = reader.xrpUsd1e18();
        emit log_named_decimal_uint("XRP/USD (1e18)", px, 18);
        // sane band for XRP: between $0.10 and $10
        assertGt(px, 0.1e18, "XRP > $0.10");
        assertLt(px, 10e18, "XRP < $10");

        // 1000 FXRP (6-dec) in USD
        uint256 usd = reader.usdValue(1000e6);
        emit log_named_decimal_uint("USD value of 1000 FXRP", usd, 18);
        assertApproxEqRel(usd, px * 1000, 1e12, "1000 FXRP == 1000 * XRP/USD");
    }
}
