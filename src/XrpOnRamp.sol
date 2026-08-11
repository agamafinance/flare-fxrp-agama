// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "./fdc/IFdc.sol";

interface IAnchorLock {
    function lockFixedRate(uint256 fxrpIn, uint256 minPtOut) external returns (uint256 ptOut);
    function pt() external view returns (address);
    function fxrp() external view returns (address);
}

interface IERC20Onramp {
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

/**
 * @title XrpOnRamp
 * @notice Native-XRP on-ramp for Agama, using the Flare Data Connector (FDC).
 *
 *   A user pays XRP on the XRPL to Agama's deposit address. An FDC "Payment" attestation proves
 *   that transfer; this contract verifies the attested response against the enshrined FDC Merkle
 *   root on the Relay (protocol id 200), then releases FXRP from its liquidity and, in one call,
 *   locks the fixed rate through Anchor (`depositAndLock`) so the PT goes straight to the payer.
 *   No FXRP moves without a real, proven XRP payment: the FDC proof is the gate.
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

    IAnchorLock public immutable anchor; // fixed-rate router (optional; enables depositAndLock)
    IERC20Onramp public immutable fxrp; // FXRP liquidity released against a proven XRP payment
    IERC20Onramp public immutable pt; // PT forwarded to the payer after the lock

    mapping(bytes32 => bool) public usedTx; // replay protection by XRPL transaction id
    mapping(address => uint256) public credited; // Flare user -> XRP drops proven in

    event XrpDeposited(address indexed user, uint256 amountDrops, bytes32 indexed xrplTxId, uint8 status);
    event XrpLocked(address indexed user, uint256 amountDrops, uint256 ptOut, bytes32 indexed xrplTxId);

    constructor(bytes32 _treasuryAddressHash, bytes32 _expectedSourceId, address _anchor) {
        relay = IRelay(IFdcRegistry(0xaD67FE66660Fb8dFE9d6b1b4240d8650e30F6019).getContractAddressByName("Relay"));
        treasuryAddressHash = _treasuryAddressHash;
        expectedSourceId = _expectedSourceId;
        anchor = IAnchorLock(_anchor);
        if (_anchor != address(0)) {
            fxrp = IERC20Onramp(IAnchorLock(_anchor).fxrp());
            pt = IERC20Onramp(IAnchorLock(_anchor).pt());
        }
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

    /// Shared FDC checks: prove a successful native-XRP payment to Agama's address, once.
    function _proveXrpPayment(bytes calldata attestedResponse, bytes32[] calldata merkleProof)
        internal
        returns (uint256 amountDrops, bytes32 txId)
    {
        Payment.Response memory data = abi.decode(attestedResponse, (Payment.Response));
        require(verify(attestedResponse, merkleProof, data.votingRound), "invalid FDC payment proof");
        require(data.attestationType == ATT_PAYMENT, "not a Payment attestation");
        require(data.sourceId == expectedSourceId, "wrong source chain");
        require(data.responseBody.status == STATUS_SUCCESS, "payment not successful");
        require(data.responseBody.receivingAddressHash == treasuryAddressHash, "wrong receiver");

        txId = data.requestBody.transactionId;
        require(!usedTx[txId], "already claimed");
        usedTx[txId] = true;

        int256 received = data.responseBody.receivedAmount;
        require(received > 0, "no amount");
        amountDrops = uint256(received); // XRP drops are 6 decimals, same as FXRP
    }

    /// Prove a native-XRP payment and credit `to` (drops recorded; no FXRP released).
    function depositWithXrpProof(bytes calldata attestedResponse, bytes32[] calldata merkleProof, address to)
        external
        returns (uint256 amountDrops)
    {
        bytes32 txId;
        (amountDrops, txId) = _proveXrpPayment(attestedResponse, merkleProof);
        credited[to] += amountDrops;
        emit XrpDeposited(to, amountDrops, txId, STATUS_SUCCESS);
    }

    /// Prove a native-XRP payment, release the matching FXRP from this on-ramp's liquidity, and lock
    /// the fixed rate through Anchor in one call. The PT (certainty) goes straight to `to`.
    function depositAndLock(bytes calldata attestedResponse, bytes32[] calldata merkleProof, uint256 minPtOut, address to)
        external
        returns (uint256 ptOut)
    {
        require(address(anchor) != address(0), "no anchor");
        (uint256 amountDrops, bytes32 txId) = _proveXrpPayment(attestedResponse, merkleProof);
        require(fxrp.balanceOf(address(this)) >= amountDrops, "onramp out of FXRP");

        fxrp.approve(address(anchor), amountDrops);
        ptOut = anchor.lockFixedRate(amountDrops, minPtOut); // PT is minted to this contract
        pt.transfer(to, ptOut); // forward the locked PT to the payer
        emit XrpLocked(to, amountDrops, ptOut, txId);
    }
}
