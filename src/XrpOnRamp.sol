// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "./fdc/IFdc.sol";

/**
 * @title XrpOnRamp
 * @notice Native-XRP on-ramp for Agama, using the Flare Data Connector (FDC).
 *
 *   A user pays XRP on the XRPL to Agama's deposit address (encoding their Flare address in the
 *   payment reference). An FDC "Payment" attestation proves that transfer, and this contract
 *   verifies the proof against the enshrined FdcVerification, then records the deposit (with
 *   replay protection). In production the credited amount triggers the FAssets FXRP mint and opens
 *   the user's fixed-rate position; here the verified deposit is recorded and emitted.
 *
 *   This is the deep "interoperable asset" path: real XRP from the XRPL, proven on Flare, no bridge
 *   trust. POC, unaudited.
 */
contract XrpOnRamp {
    IFdcVerification public immutable fdc;
    bytes32 public immutable treasuryAddressHash; // hash of Agama's XRPL receiving address

    mapping(bytes32 => bool) public usedTx; // replay protection by XRPL transaction id
    mapping(address => uint256) public credited; // Flare user -> XRP drops proven in

    event XrpDeposited(address indexed user, uint256 amountDrops, bytes32 indexed xrplTxId);

    bytes32 constant PAYMENT_SUCCESS = 0; // status 0 = success in the Payment attestation

    constructor(bytes32 _treasuryAddressHash) {
        // resolve the enshrined FdcVerification via the canonical registry (same on all Flare nets)
        address v = IFdcRegistry(0xaD67FE66660Fb8dFE9d6b1b4240d8650e30F6019).getContractAddressByName("FdcVerification");
        require(v != address(0), "no FdcVerification");
        fdc = IFdcVerification(v);
        treasuryAddressHash = _treasuryAddressHash;
    }

    /// Prove a native-XRP payment to Agama's address and credit the sender. `to` is the Flare
    /// recipient (encoded in the XRPL payment reference off chain; passed here for the POC).
    function depositWithXrpProof(Payment.Proof calldata proof, address to) external returns (uint256 amountDrops) {
        require(fdc.verifyPayment(proof), "invalid FDC payment proof");
        require(proof.data.responseBody.status == uint8(uint256(PAYMENT_SUCCESS)), "payment not successful");
        require(proof.data.responseBody.receivingAddressHash == treasuryAddressHash, "wrong receiver");

        bytes32 txId = proof.data.requestBody.transactionId;
        require(!usedTx[txId], "already claimed");
        usedTx[txId] = true;

        int256 received = proof.data.responseBody.receivedAmount;
        require(received > 0, "no amount");
        amountDrops = uint256(received); // XRP drops are 6 decimals, same as FXRP

        credited[to] += amountDrops;
        emit XrpDeposited(to, amountDrops, txId);
        // production: mint FXRP (FAssets) for `amountDrops` and open the fixed-rate position for `to`
    }
}
