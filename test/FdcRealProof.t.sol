// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "forge-std/Test.sol";
import "../src/XrpOnRamp.sol";
import "../src/fdc/IFdc.sol";
import "../src/MockERC20.sol";
import "../src/MockVault.sol";
import "../src/YieldSplitter.sol";
import "../src/PtAmm.sol";
import "../src/Anchor.sol";

/**
 * End-to-end proof of the native-XRP on-ramp with REAL Flare Data Connector infrastructure.
 * The vector (test/vectors/fdc_payment_proof.json) is a real FDC Payment attestation of a real
 * XRPL testnet payment, with its Merkle proof from the Coston2 DA layer. On a Coston2 fork, the
 * on-ramp verifies it against the live Relay Merkle root and, via depositAndLock, releases FXRP and
 * locks the fixed rate through Anchor, sending the PT to the recipient named in the XRP memo.
 *
 * Note: depends on the Relay still retaining that voting round's root; regenerate with run.py if aged.
 */
contract FdcRealProofTest is Test {
    uint256 constant ONE = 1e6;
    bytes response;
    bytes32[] proof;

    function setUp() public {
        vm.createSelectFork(vm.envOr("COSTON2_RPC", string("https://coston2-api.flare.network/ext/C/rpc")));
        string memory j = vm.readFile("test/vectors/fdc_payment_proof.json");
        response = vm.parseJsonBytes(j, ".response_hex");
        proof = vm.parseJsonBytes32Array(j, ".proof");
    }

    function test_RealXrplPayment_VerifiesAndLocks() public {
        Payment.Response memory r = abi.decode(response, (Payment.Response));

        // auto-skip if this voting round's root has aged out of the Relay's retention window
        IRelay relay = IRelay(IFdcRegistry(0xaD67FE66660Fb8dFE9d6b1b4240d8650e30F6019).getContractAddressByName("Relay"));
        if (relay.merkleRoots(200, r.votingRound) == bytes32(0)) {
            vm.skip(true);
            return;
        }

        // deploy the fixed-rate stack and seed a deep pool so lockFixedRate has liquidity
        MockERC20 fxrp = new MockERC20("FXRP", "FXRP", 6);
        MockVault vault = new MockVault(fxrp);
        uint256 mat = block.timestamp + 90 days;
        YieldSplitter splitter = new YieldSplitter(vault, mat);
        PtAmm amm = new PtAmm(IERC20Min(address(fxrp)), IERC20Min(address(splitter.pt())), mat, 1e18);
        Anchor anchor = new Anchor(splitter, amm);
        fxrp.mint(address(this), 250000 * ONE);
        fxrp.approve(address(splitter), type(uint256).max);
        splitter.split(110000 * ONE);
        fxrp.approve(address(amm), type(uint256).max);
        splitter.pt().approve(address(amm), type(uint256).max);
        amm.addLiquidity(100000 * ONE, 105000 * ONE);

        XrpOnRamp ramp = new XrpOnRamp(r.responseBody.receivingAddressHash, bytes32("testXRP"), address(anchor));
        assertTrue(ramp.verify(response, proof, r.votingRound), "real FDC attestation verifies vs live Relay root");

        uint256 drops = uint256(r.responseBody.receivedAmount);
        fxrp.mint(address(ramp), drops); // seed the on-ramp's FXRP inventory
        address recipient = address(uint160(uint256(r.responseBody.standardPaymentReference)));
        uint256 before = splitter.pt().balanceOf(recipient);

        uint256 ptOut = ramp.depositAndLock(response, proof);
        emit log_named_uint("PT locked from a real XRPL payment", ptOut);
        assertGt(ptOut, 0, "PT locked");
        assertEq(splitter.pt().balanceOf(recipient) - before, ptOut, "PT went to the memo recipient (the payer)");

        // replay protection: the same XRPL tx cannot be claimed twice
        vm.expectRevert(bytes("already claimed"));
        ramp.depositAndLock(response, proof);
    }
}
