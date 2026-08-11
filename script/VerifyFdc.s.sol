// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "forge-std/Script.sol";
import "../src/fdc/IFdc.sol";
import "../src/XrpOnRamp.sol";

/**
 * Feeds a REAL FDC Payment attestation (of an actual XRPL testnet payment) to XrpOnRamp on a
 * Coston2 fork: it verifies against the live Relay Merkle root and credits the deposit.
 *   RESPONSE_HEX=0x.. PROOF=0x..,0x..,0x.. \
 *   forge script script/VerifyFdc.s.sol:VerifyFdc --rpc-url coston2
 */
contract VerifyFdc is Script {
    function run() external {
        bytes memory attestedResponse = vm.envBytes("RESPONSE_HEX");
        bytes32[] memory merkleProof = vm.envBytes32("PROOF", ",");
        Payment.Response memory resp = abi.decode(attestedResponse, (Payment.Response));

        XrpOnRamp ramp = new XrpOnRamp(resp.responseBody.receivingAddressHash, bytes32("testXRP"));

        console2.log("XRPL tx:");
        console2.logBytes32(resp.requestBody.transactionId);
        bool ok = ramp.verify(attestedResponse, merkleProof, resp.votingRound);
        console2.log("verify(REAL FDC attestation vs live Relay root) =", ok);

        uint256 drops = ramp.depositWithXrpProof(attestedResponse, merkleProof, address(0xBEEF));
        console2.log("credited drops           =", drops);
        console2.log("credited[recipient]      =", ramp.credited(address(0xBEEF)));
    }
}
