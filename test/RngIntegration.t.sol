// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "forge-std/Test.sol";

interface IRegistry { function getContractAddressByName(string calldata) external view returns (address); }
interface IRandomV2 { function getRandomNumber() external view returns (uint256, bool, uint256); }

/**
 * Reads Flare's enshrined Secure Random Number generator on a Coston2 fork. The confidential
 * enclave uses this exact source to break ties fairly when market makers quote the same best price
 * (see script/Enclave.s.sol :: _pickWinner).
 */
contract RngIntegrationTest is Test {
    IRegistry constant REGISTRY = IRegistry(0xaD67FE66660Fb8dFE9d6b1b4240d8650e30F6019);

    function setUp() public {
        vm.createSelectFork(vm.envOr("COSTON2_RPC", string("https://coston2-api.flare.network/ext/C/rpc")));
    }

    function test_Rng_SecureRandomLive() public {
        IRandomV2 rng = IRandomV2(REGISTRY.getContractAddressByName("RandomNumberV2"));
        (uint256 rnd, bool isSecure, uint256 ts) = rng.getRandomNumber();
        emit log_named_uint("random % 1000 (tie-break example)", rnd % 1000);
        assertTrue(isSecure, "random is secure");
        assertGt(rnd, 0, "non-zero random");
        assertGt(ts, 0, "has a timestamp");
    }
}
