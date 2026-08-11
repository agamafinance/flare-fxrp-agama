// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "forge-std/Script.sol";
import "../src/fdc/IFdc.sol";

interface IAssetManager {
    function executeMinting(Payment.Proof calldata _payment, uint256 _collateralReservationId) external;
}

/**
 * Completes a FAssets mint: presents the FDC Payment proof of the XRP paid to the agent, minting
 * real FTestXRP to the minter.
 *   PRIVATE_KEY=0x.. ASSET_MANAGER=0x.. CRT_ID=.. RESPONSE_HEX=0x.. PROOF=0x..,0x..,0x.. \
 *   forge script script/ExecuteMinting.s.sol:ExecuteMinting --rpc-url coston2 --broadcast
 */
contract ExecuteMinting is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address am = vm.envAddress("ASSET_MANAGER");
        uint256 crtId = vm.envUint("CRT_ID");
        bytes memory responseHex = vm.envBytes("RESPONSE_HEX");
        bytes32[] memory merkleProof = vm.envBytes32("PROOF", ",");

        Payment.Response memory resp = abi.decode(responseHex, (Payment.Response));
        Payment.Proof memory p = Payment.Proof(merkleProof, resp);

        vm.startBroadcast(pk);
        IAssetManager(am).executeMinting(p, crtId);
        vm.stopBroadcast();

        console2.log("executeMinting done, crtId", crtId);
        console2.log("received drops", uint256(resp.responseBody.receivedAmount));
        console2.log("payment status", resp.responseBody.status);
    }
}
