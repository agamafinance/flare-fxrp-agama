// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "./interfaces/IERC4626.sol"; // IERC20
import "./EnclaveRegistry.sol"; // IEnclaveRegistry

/**
 * @title ConfidentialYtRfq
 * @notice The yield-token (YT) demand side of Anchor, run as a confidential request-for-quote
 *         inside a Flare Confidential Compute enclave (TEE).
 *
 *   Problem: on a yield-poor chain, YT demand is thin, so the fixed-rate (PT) side struggles to
 *   find a counterparty. Market makers will not post public quotes: an on-chain order book leaks
 *   their pricing and gets them picked off.
 *
 *   Solution: MMs submit SEALED quotes to a TEE enclave. The enclave runs best execution and
 *   signs only the WINNING settlement. This contract verifies the enclave signature (the enclave
 *   key is registered on-chain from its remote attestation) and settles atomically: escrowed YT
 *   to the winning MM, FXRP premium to the seller. The losing quotes never touch the chain.
 *
 *   Trust model. Two independent guardrails make the open matching endpoint safe:
 *     1. Each quote is signed by its market maker (see `quoteDigest`); the enclave rejects any quote
 *        whose signature does not recover to the claimed MM, so no one can fabricate a quote for an
 *        MM or replay it to another RFQ.
 *     2. The seller sets a reserve `minPrice` at open time; `settle` enforces `price >= minPrice`
 *        on-chain, so even a misbehaving enclave cannot sell the YT below the seller's floor.
 *   The enclave reads seller/ytAmount/minPrice from this contract, not from the caller, so the
 *   relayer of a settlement cannot alter the RFQ terms.
 *
 *   POC note: here the enclave is a signer whose key the contract trusts. In production the same
 *   matching code runs in GCP Confidential Space (Intel TDX) and its attestation registers the key.
 */
contract ConfidentialYtRfq {
    IERC20 public immutable fxrp;
    IERC20 public immutable yt;
    IEnclaveRegistry public immutable registry; // enclave key is attestation-gated, not manually set

    uint256 public constant SETTLE_WINDOW = 15 minutes; // enclave settlement window; cancel only opens after it

    struct Rfq {
        address seller;
        uint256 ytAmount;
        uint256 minPrice; // seller's reserve: settle rejects any winning price below this
        uint256 settleBy; // settle allowed until here; cancel allowed only after, so neither front-runs the other
        bool open;
    }

    struct Settlement {
        uint256 rfqId;
        address seller;
        address winner; // winning market maker
        uint256 ytAmount;
        uint256 price; // FXRP the winner pays the seller for the YT
        uint256 deadline;
    }

    uint256 public nextId = 1;
    mapping(uint256 => Rfq) public rfqs;

    event RfqOpened(uint256 indexed rfqId, address indexed seller, uint256 ytAmount, uint256 minPrice);
    event RfqSettled(uint256 indexed rfqId, address indexed seller, address indexed winner, uint256 ytAmount, uint256 price);
    event RfqCancelled(uint256 indexed rfqId);

    constructor(IERC20 _fxrp, IERC20 _yt, IEnclaveRegistry _registry) {
        fxrp = _fxrp;
        yt = _yt;
        registry = _registry;
    }

    /// The trusted enclave key, sourced from the attestation-gated registry (no manual override).
    function enclaveSigner() public view returns (address) {
        return registry.enclaveSigner();
    }

    /// Seller escrows YT and opens a confidential RFQ with a reserve price. MMs then quote off-chain.
    /// The reserve must be positive: minPrice == 0 would let an MM take the YT for nothing.
    function openRfq(uint256 ytAmount, uint256 minPrice) external returns (uint256 id) {
        require(ytAmount > 0, "amount");
        require(minPrice > 0, "reserve");
        require(yt.transferFrom(msg.sender, address(this), ytAmount), "yt in");
        id = nextId++;
        rfqs[id] = Rfq(msg.sender, ytAmount, minPrice, block.timestamp + SETTLE_WINDOW, true);
        emit RfqOpened(id, msg.sender, ytAmount, minPrice);
    }

    /// The digest a market maker signs for a sealed quote. The enclave verifies the MM's signature
    /// against this exact preimage, so a quote cannot be forged for another MM or replayed elsewhere.
    function quoteDigest(uint256 rfqId, address mm, uint256 ytAmount, uint256 price, uint256 deadline)
        public
        view
        returns (bytes32)
    {
        return keccak256(abi.encode("AnchorQuote", block.chainid, address(this), rfqId, mm, ytAmount, price, deadline));
    }

    /// The digest the enclave signs. Bound to this contract and chain to stop replay.
    function settlementDigest(Settlement calldata s) public view returns (bytes32) {
        return keccak256(
            abi.encode("AnchorRFQ", block.chainid, address(this), s.rfqId, s.seller, s.winner, s.ytAmount, s.price, s.deadline)
        );
    }

    /// Anyone can relay the enclave-signed winning settlement. The contract verifies and executes.
    function settle(Settlement calldata s, uint8 v, bytes32 r, bytes32 sig_s) external {
        Rfq storage q = rfqs[s.rfqId];
        require(q.open, "closed");
        require(q.seller == s.seller && q.ytAmount == s.ytAmount, "mismatch");
        require(s.price >= q.minPrice, "below reserve");
        require(block.timestamp <= q.settleBy, "settle window closed"); // bounds the MM's exposure
        require(block.timestamp <= s.deadline, "expired");
        address rec = ecrecover(settlementDigest(s), v, r, sig_s);
        require(rec != address(0) && rec == enclaveSigner(), "bad enclave sig");

        q.open = false;
        // winner pays the FXRP premium to the seller; escrowed YT goes to the winner
        require(fxrp.transferFrom(s.winner, s.seller, s.price), "fxrp pay");
        require(yt.transfer(s.winner, s.ytAmount), "yt xfer");
        emit RfqSettled(s.rfqId, s.seller, s.winner, s.ytAmount, s.price);
    }

    /// Seller reclaims escrowed YT if the RFQ was never settled.
    function cancel(uint256 id) external {
        Rfq storage q = rfqs[id];
        require(q.open && q.seller == msg.sender, "no");
        require(block.timestamp > q.settleBy, "settle window open"); // cannot front-run a pending settle
        q.open = false;
        require(yt.transfer(msg.sender, q.ytAmount), "yt back");
        emit RfqCancelled(id);
    }
}
