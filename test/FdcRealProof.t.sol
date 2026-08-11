// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "forge-std/Test.sol";
import "../src/XrpOnRamp.sol";
import "../src/fdc/IFdc.sol";

/**
 * End-to-end proof of the native-XRP on-ramp with REAL Flare Data Connector infrastructure.
 * The vector (test/vectors/fdc_payment_proof.json) is a real FDC Payment attestation of a real
 * XRPL testnet payment (tx ADE8D7C7...), with its Merkle proof from the Coston2 DA layer. On a
 * Coston2 fork, XrpOnRamp verifies it against the live Relay Merkle root and credits the deposit.
 *
 * Note: depends on the Relay still retaining that voting round's root; pin a fork block if it ages out.
 */
contract FdcRealProofTest is Test {
    bytes response;
    bytes32[] proof;

    function setUp() public {
        vm.createSelectFork(vm.envOr("COSTON2_RPC", string("https://coston2-api.flare.network/ext/C/rpc")));
        string memory j = vm.readFile("test/vectors/fdc_payment_proof.json");
        response = vm.parseJsonBytes(j, ".response_hex");
        proof = vm.parseJsonBytes32Array(j, ".proof");
    }

    function test_RealXrplPayment_VerifiesAndCredits() public {
        Payment.Response memory r = abi.decode(response, (Payment.Response));
        XrpOnRamp ramp = new XrpOnRamp(r.responseBody.receivingAddressHash);

        assertTrue(ramp.verify(response, proof, r.votingRound), "real FDC attestation verifies vs live Relay root");

        uint256 drops = ramp.depositWithXrpProof(response, proof, address(0xBEEF));
        emit log_named_uint("credited drops (real XRPL payment)", drops);
        assertEq(drops, uint256(r.responseBody.receivedAmount), "credited the attested amount");
        assertEq(ramp.credited(address(0xBEEF)), drops, "recipient credited");

        // replay protection: the same XRPL tx cannot be claimed twice
        vm.expectRevert(bytes("already claimed"));
        ramp.depositWithXrpProof(response, proof, address(0xBEEF));
    }
}
