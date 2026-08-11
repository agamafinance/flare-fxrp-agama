// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "forge-std/Script.sol";

/**
 * Enclave: simulates the Confidential Compute enclave that runs the YT RFQ matching.
 *
 * It receives the sealed market-maker quotes (here via env), picks best execution (highest price
 * for the seller), and signs the winning settlement with the enclave key. In production this exact
 * logic runs inside GCP Confidential Space (Intel TDX); the losing quotes never leave the enclave,
 * and the enclave key is sealed to the attested code. The signature it prints is what a relayer
 * submits to ConfidentialYtRfq.settle(...).
 *
 * Run (chainId comes from the RPC so the digest matches the target deployment):
 *   ENCLAVE_PK=0x.. RFQ=0x.. RFQ_ID=1 SELLER=0x.. YT_AMOUNT=1000000000 DEADLINE=<unix> \
 *   QUOTE_MMS=0xmm1,0xmm2 QUOTE_PRICES=12000000,9000000 \
 *   forge script script/Enclave.s.sol:Enclave --rpc-url coston2
 */
contract Enclave is Script {
    function run() external view {
        uint256 pk = vm.envUint("ENCLAVE_PK");
        address rfq = vm.envAddress("RFQ");
        uint256 rfqId = vm.envUint("RFQ_ID");
        address seller = vm.envAddress("SELLER");
        uint256 ytAmount = vm.envUint("YT_AMOUNT");
        uint256 deadline = vm.envUint("DEADLINE");
        address[] memory mms = vm.envAddress("QUOTE_MMS", ",");
        uint256[] memory prices = vm.envUint("QUOTE_PRICES", ",");

        // best execution: highest price wins (the losing quotes stay inside the enclave)
        uint256 best;
        address winner;
        for (uint256 i; i < prices.length; i++) {
            if (prices[i] > best) {
                best = prices[i];
                winner = mms[i];
            }
        }

        bytes32 digest =
            keccak256(abi.encode("AnchorRFQ", block.chainid, rfq, rfqId, seller, winner, ytAmount, best, deadline));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);

        console2.log("== enclave signed the winning settlement ==");
        console2.log("winner (best MM)", winner);
        console2.log("price          ", best);
        // single parseable line for a relayer/front to consume
        console2.log(
            string.concat(
                "RESULT winner=",
                vm.toString(winner),
                " price=",
                vm.toString(best),
                " v=",
                vm.toString(uint256(v)),
                " r=",
                vm.toString(r),
                " s=",
                vm.toString(s)
            )
        );
    }
}
