// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "./fdc/IFdc.sol";

interface IAnchorLock {
    function lockFixedRate(uint256 fxrpIn, uint256 minPtOut) external returns (uint256 ptOut);
    function previewLock(uint256 fxrpIn) external view returns (uint256 ptOut, uint256 aprE18);
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
 *   A user pays XRP on the XRPL to Agama's deposit address, with a 32-byte memo carrying the Flare
 *   recipient. An FDC "Payment" attestation proves that transfer; this contract verifies it against
 *   the enshrined FDC Merkle root on the Relay (protocol id 200), then `depositAndLock` releases the
 *   matching FXRP and locks the fixed rate through Anchor in one call, sending the PT to the recipient
 *   named in the memo (standardPaymentReference). There is a single, recipient-bound, one-time
 *   settlement path: no FXRP moves without a real proof, the PT can only go to the payer, and the
 *   relayer cannot pick the slippage bound (the contract enforces a floor) or burn the deposit.
 *
 *   The leaf is keccak256 of the exact attested response bytes; the same bytes are decoded for the
 *   business fields. Verified end to end against a real XRPL testnet payment. POC, unaudited.
 */
contract XrpOnRamp {
    uint256 public constant FDC_PROTOCOL_ID = 200;
    bytes32 public constant ATT_PAYMENT = bytes32("Payment"); // FDC "Payment" attestation type
    uint8 public constant STATUS_SUCCESS = 0; // Payment status 0 = success
    uint256 public constant SLIP_TOL_BPS = 100; // PT out floor = 99% of the AMM fair quote (anti-slippage)

    IRelay public immutable relay;
    bytes32 public immutable treasuryAddressHash; // FDC hash of Agama's XRPL receiving address (pinned)
    bytes32 public immutable expectedSourceId; // e.g. bytes32("testXRP") on Coston2, bytes32("XRP") on mainnet

    IAnchorLock public immutable anchor; // fixed-rate router
    IERC20Onramp public immutable fxrp; // FXRP liquidity released against a proven XRP payment
    IERC20Onramp public immutable pt; // PT forwarded to the payer after the lock

    mapping(bytes32 => bool) public usedTx; // replay protection by XRPL transaction id

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

    /// Verify attested response bytes against the finalized FDC Merkle root on the Relay (view, so
    /// relayers and tests can check a proof without consuming it).
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

    /// Prove a native-XRP payment to Agama's treasury, release the matching FXRP, and lock the fixed
    /// rate through Anchor. The PT goes to the recipient named in the XRP memo, not the caller, so a
    /// relayer that front-runs a public proof can neither steal nor grief the deposit.
    function depositAndLock(bytes calldata attestedResponse, bytes32[] calldata merkleProof)
        external
        returns (uint256 ptOut)
    {
        require(address(anchor) != address(0), "no anchor");
        Payment.Response memory data = abi.decode(attestedResponse, (Payment.Response));
        require(verify(attestedResponse, merkleProof, data.votingRound), "invalid FDC payment proof");
        require(data.attestationType == ATT_PAYMENT, "not a Payment attestation");
        require(data.sourceId == expectedSourceId, "wrong source chain");
        require(data.responseBody.status == STATUS_SUCCESS, "payment not successful");
        require(data.responseBody.receivingAddressHash == treasuryAddressHash, "wrong receiver");

        // the recipient is the payer's Flare address, carried in the XRP memo (standardPaymentReference)
        address to = address(uint160(uint256(data.responseBody.standardPaymentReference)));
        require(to != address(0), "no recipient in memo");

        bytes32 txId = data.requestBody.transactionId;
        require(!usedTx[txId], "already claimed");
        usedTx[txId] = true;

        int256 received = data.responseBody.receivedAmount;
        require(received > 0, "no amount");
        uint256 amountDrops = uint256(received); // XRP drops are 6 decimals, same as FXRP
        require(fxrp.balanceOf(address(this)) >= amountDrops, "onramp out of FXRP");

        // the contract sets the slippage floor from the AMM's fair quote (not par), so a relayer
        // cannot pass minPtOut=0. Residual same-block sandwich MEV needs a TWAP / private orderflow.
        (uint256 fairPtOut,) = anchor.previewLock(amountDrops);
        uint256 minPtOut = fairPtOut * (10000 - SLIP_TOL_BPS) / 10000;
        fxrp.approve(address(anchor), amountDrops);
        ptOut = anchor.lockFixedRate(amountDrops, minPtOut); // PT is minted to this contract
        require(pt.transfer(to, ptOut), "pt out"); // forward the locked PT to the payer
        emit XrpLocked(to, amountDrops, ptOut, txId);
    }
}
