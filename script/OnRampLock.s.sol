// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "forge-std/Script.sol";
import "../src/fdc/IFdc.sol";
import "../src/XrpOnRamp.sol";
import "../src/MockERC20.sol";

/**
 * FDC on-ramp wired into the product: a REAL XRPL payment, proven on chain via the Flare Data
 * Connector, releases FXRP from the on-ramp and locks the fixed rate through Anchor in one call.
 * No FXRP moves without the FDC proof. Run after fdc-onramp/run.py produced a fresh proof:
 *   RESPONSE_HEX=0x.. PROOF=0x..,0x.. ANCHOR=0x.. TO=0x.. PRIVATE_KEY=0x.. \
 *   forge script script/OnRampLock.s.sol:OnRampLock --rpc-url coston2 --broadcast
 */
contract OnRampLock is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address anchor = vm.envAddress("ANCHOR");
        address to = vm.envAddress("TO");
        bytes memory resp = vm.envBytes("RESPONSE_HEX");
        bytes32[] memory proof = vm.envBytes32("PROOF", ",");
        Payment.Response memory d = abi.decode(resp, (Payment.Response));
        uint256 drops = uint256(d.responseBody.receivedAmount);

        vm.startBroadcast(pk);
        XrpOnRamp ramp = new XrpOnRamp(d.responseBody.receivingAddressHash, bytes32("testXRP"), anchor);
        MockERC20(address(ramp.fxrp())).mint(address(ramp), drops); // seed the on-ramp FXRP inventory
        uint256 before = ramp.pt().balanceOf(to);
        uint256 ptOut = ramp.depositAndLock(resp, proof, 0, to);
        vm.stopBroadcast();

        console2.log("onramp                 ", address(ramp));
        console2.log("XRP drops proven in    =", drops);
        console2.log("PT locked to recipient =", ptOut);
        console2.log("recipient PT delta     =", ramp.pt().balanceOf(to) - before);
    }
}
