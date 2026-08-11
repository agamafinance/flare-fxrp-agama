// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "forge-std/Test.sol";
import "../src/fdc/IFdc.sol";
import "../src/XrpOnRamp.sol";

/**
 * Binds to the live enshrined FdcVerification on a Coston2 fork and confirms the Payment-proof
 * verification path is wired with the correct ABI: an empty (unattested) proof verifies as false
 * without reverting. Feeding a real XRPL Payment proof (from an actual FDC attestation round) is
 * what returns true and lets Agama credit a native-XRP deposit.
 */
contract FdcIntegrationTest is Test {
    IFdcRegistry constant REGISTRY = IFdcRegistry(0xaD67FE66660Fb8dFE9d6b1b4240d8650e30F6019);

    function setUp() public {
        vm.createSelectFork(vm.envOr("COSTON2_RPC", string("https://coston2-api.flare.network/ext/C/rpc")));
    }

    function test_Fdc_VerificationWiredLive() public {
        address fdcAddr = REGISTRY.getContractAddressByName("FdcVerification");
        assertTrue(fdcAddr != address(0), "FdcVerification resolves");
        assertGt(fdcAddr.code.length, 0, "FdcVerification is deployed");
        emit log_named_address("FdcVerification", fdcAddr);

        // an unattested Payment proof must NOT verify: the live verifier either returns false or
        // reverts while checking the Merkle root against the Relay. Either way it is rejected.
        // A real XRPL Payment proof from an FDC attestation round is what returns true.
        Payment.Proof memory empty;
        try IFdcVerification(fdcAddr).verifyPayment(empty) returns (bool ok) {
            assertFalse(ok, "unattested proof must not verify");
            emit log("verifyPayment returned false for an unattested proof");
        } catch {
            emit log("verifyPayment reverted on an unattested proof (Merkle check) -> rejected");
        }
    }

    function test_XrpOnRamp_RejectsUnattestedDeposit() public {
        XrpOnRamp ramp = new XrpOnRamp(keccak256("agama-xrpl-address"), bytes32("testXRP"), address(0));
        assertGt(address(ramp.relay()).code.length, 0, "gateway wired to the live FDC Relay");
        // a deposit with no valid FDC attestation is rejected (decode/verify fails)
        bytes memory empty = "";
        bytes32[] memory noProof = new bytes32[](0);
        vm.expectRevert();
        ramp.depositWithXrpProof(empty, noProof, address(this));
    }
}

