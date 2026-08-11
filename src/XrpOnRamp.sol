// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "./fdc/IFdc.sol";

/**
 * @title XrpOnRamp
 * @notice Native-XRP on-ramp for Agama, using the Flare Data Connector (FDC).
 *
 *   A user pays XRP on the XRPL to Agama's deposit address. An FDC "Payment" attestation proves
 *   that transfer; this contract verifies the attested response against the enshrined FDC Merkle
 *   root on the Relay (protocol id 200), then records the deposit (with replay protection). In
 *   production the credited amount triggers the FAssets FXRP mint and opens the fixed-rate position.
 *
 *   The leaf is keccak256 of the exact attested response bytes (as the FDC Data Availability layer
 *   commits them); the same bytes are decoded for the business fields. Verified end to end against
 *   a real XRPL testnet payment and its live FDC attestation. POC, unaudited.
 */
contract XrpOnRamp {
    uint256 public constant FDC_PROTOCOL_ID = 200;
    bytes32 public constant ATT_PAYMENT = bytes32("Payment"); // FDC "Payment" attestation type
    uint8 public constant STATUS_SUCCESS = 0; // Payment status 0 = success

    IRelay public immutable relay;
    bytes32 public immutable treasuryAddressHash; // FDC hash of Agama's XRPL receiving address
    bytes32 public immutable expectedSourceId; // e.g. bytes32("testXRP") on Coston2, bytes32("XRP") on mainnet

    mapping(bytes32 => bool) public usedTx; // replay protection by XRPL transaction id
    mapping(address => uint256) public credited; // Flare user -> XRP drops proven in

    event XrpDeposited(address indexed user, uint256 amountDrops, bytes32 indexed xrplTxId, uint8 status);

    constructor(bytes32 _treasuryAddressHash, bytes32 _expectedSourceId) {
        relay = IRelay(IFdcRegistry(0xaD67FE66660Fb8dFE9d6b1b4240d8650e30F6019).getContractAddressByName("Relay"));
        treasuryAddressHash = _treasuryAddressHash;
        expectedSourceId = _expectedSourceId;
    }

    /// Verify attested response bytes against the finalized FDC Merkle root on the Relay.
    function verify(bytes calldata attestedResponse, bytes32[] calldata merkleProof, uint256 votingRound)
        public
        view
        returns (bool)
    {
        bytes32 root = relay.merkleRoots(FDC_PROTOCOL_ID, votingRound);
        if (root == bytes32(0)) return false;
        bytes32 node = keccak256(attestedResponse); // FDC leaf = keccak256 of the committed bytes
        for (uint256 i = 0; i < merkleProof.length; i++) {
            bytes32 s = merkleProof[i];
            node = node <= s ? keccak256(abi.encodePacked(node, s)) : keccak256(abi.encodePacked(s, node));
        }
        return node == root;
    }

    /// Prove a native-XRP payment to Agama's address and credit `to` with the received drops.
    /// `attestedResponse` is the FDC Payment response bytes; `merkleProof` from the DA layer.
    function depositWithXrpProof(bytes calldata attestedResponse, bytes32[] calldata merkleProof, address to)
        external
        returns (uint256 amountDrops)
    {
        Payment.Response memory data = abi.decode(attestedResponse, (Payment.Response));
        require(verify(attestedResponse, merkleProof, data.votingRound), "invalid FDC payment proof");
        // bind the attestation to the right type, source chain and a successful payment
        require(data.attestationType == ATT_PAYMENT, "not a Payment attestation");
        require(data.sourceId == expectedSourceId, "wrong source chain");
        require(data.responseBody.status == STATUS_SUCCESS, "payment not successful");
        require(data.responseBody.receivingAddressHash == treasuryAddressHash, "wrong receiver");

        bytes32 txId = data.requestBody.transactionId;
        require(!usedTx[txId], "already claimed");
        usedTx[txId] = true;

        int256 received = data.responseBody.receivedAmount;
        require(received > 0, "no amount");
        amountDrops = uint256(received); // XRP drops are 6 decimals, same as FXRP

        credited[to] += amountDrops;
        emit XrpDeposited(to, amountDrops, txId, data.responseBody.status);
        // production: mint FXRP (FAssets) for `amountDrops` and open the fixed-rate position for `to`
    }
}
