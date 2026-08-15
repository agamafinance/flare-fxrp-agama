// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

// TODO: Replace local interfaces with imports from flare-smart-contracts-v2 once published as a package.
import { ITeeExtensionRegistry } from "./interfaces/ITeeExtensionRegistry.sol";
import { ITeeMachineRegistry } from "./interfaces/ITeeMachineRegistry.sol";

/// @notice Minimal ERC20 surface used for the YT escrow and the FXRP premium.
interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
}

/// @title AgamaRfqInstructionSender
/// @notice The yield-token (YT) demand side of Agama, run as a sealed-bid RFQ inside a
///         Flare Compute Extension.
///
///   Market makers will not post public quotes: an on-chain order book leaks their pricing and
///   gets them picked off. So the quotes never touch this chain. Each MM signs its quote and
///   submits it to the extension as a *direct action* (optionally ECIES-encrypted under the TEE
///   public key), so it is only ever seen inside the enclave. The seller then calls
///   `requestSettlement`, which routes an `RFQ`/`SETTLE` instruction through the Flare TEE
///   manager. The extension authenticates every quote, runs best execution (reserve-bounded,
///   FTSO-banded, ties broken by Flare Secure RNG) and returns only the winning settlement.
///   `settle` verifies the TEE node's signature over that result and executes atomically.
///
///   Trust model. Three independent guardrails:
///     1. Each quote is signed by its market maker (`quoteDigest`); the extension rejects any
///        quote whose signature does not recover to the claimed MM, so nobody can fabricate a
///        quote for an MM or replay it into another RFQ.
///     2. The seller sets a reserve `minPrice` at open time; `settle` enforces `price >= minPrice`
///        on-chain, so even a misbehaving extension cannot sell the YT below the seller's floor.
///     3. The result must be signed by the registered TEE machine, whose code hash is whitelisted
///        on-chain for this extension and whose attestation is verified by Flare's data providers.
///   The extension reads seller / ytAmount / minPrice from this contract, not from the caller, so
///   the relayer of a settlement cannot alter the RFQ terms.
///
/// DO NOT MODIFY: constructor, setExtensionId(), _getExtensionId()
contract AgamaRfqInstructionSender {
    // --- FCC operation identifiers (must match python/app/config.py) ---

    /// @notice Operation type for confidential RFQ actions.
    // forge-lint: disable-next-line(unsafe-typecast)
    bytes32 public constant OP_TYPE_RFQ = bytes32("RFQ");

    /// @notice Command for the settlement action (best execution over the sealed quotes).
    // forge-lint: disable-next-line(unsafe-typecast)
    bytes32 public constant OP_COMMAND_SETTLE = bytes32("SETTLE");

    /// @notice Domain-separation prefix the TEE node signs ActionResult hashes under:
    ///         keccak256(abi.encode(TEE_ACTION_RESULT_PREFIX, chainId, ActionResult.Hash())),
    ///         wrapped with the EIP-191 personal-sign prefix. Must match go-flare-common's
    ///         `signing.TEEActionResult`.
    // forge-lint: disable-next-line(unsafe-typecast)
    bytes32 private constant TEE_ACTION_RESULT_PREFIX = bytes32("TEE_ACTION_RESULT");

    // --- Registries (DO NOT MODIFY) ---

    /// @notice Reference to the TEE extension registry contract.
    ITeeExtensionRegistry public immutable TEE_EXTENSION_REGISTRY;
    /// @notice Reference to the TEE machine registry contract.
    ITeeMachineRegistry public immutable TEE_MACHINE_REGISTRY;

    /// @notice First public extension ID. The registry reserves IDs below this
    /// for system/reserved extensions; public extensions are assigned from here up.
    uint256 private constant FIRST_PUBLIC_EXTENSION_ID = 0x10000; // 65536

    uint256 private _extensionId;

    // --- RFQ state ---

    /// @notice The premium asset market makers pay the seller with.
    IERC20 public immutable FXRP;
    /// @notice The yield token being sold.
    IERC20 public immutable YT;

    /// @notice Settlement window. `cancel` only opens after it, so settle and cancel never race.
    uint256 public constant SETTLE_WINDOW = 15 minutes;

    /// @notice A live request for quotes. Quotes themselves never appear on chain.
    struct Rfq {
        address seller;
        uint256 ytAmount;
        uint256 minPrice; // seller's reserve: settle rejects any winning price below this
        uint256 settleBy; // settle allowed until here; cancel allowed only after
        bool open;
    }

    /// @notice ABI payload of a SETTLE instruction (decoded by the extension).
    struct SettleMessage {
        uint256 rfqId;
        address contractAddr; // this contract — echoed back so settle() can bind the result
    }

    /// @notice Next RFQ id. Ids start at 1 so 0 means "no RFQ".
    uint256 public nextId = 1;
    /// @notice Open and settled RFQs by id.
    mapping(uint256 => Rfq) public rfqs;

    /// @notice The registered TEE machine address whose results this contract accepts.
    address public teeAddress;
    /// @notice Contract owner; may set the TEE address.
    address public owner;

    event RfqOpened(uint256 indexed rfqId, address indexed seller, uint256 ytAmount, uint256 minPrice);
    event SettlementRequested(uint256 indexed rfqId, bytes32 indexed instructionId);
    event RfqSettled(uint256 indexed rfqId, address indexed seller, address indexed winner, uint256 ytAmount, uint256 price);
    event RfqCancelled(uint256 indexed rfqId);
    event TeeAddressSet(address indexed teeAddress);

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    /// @notice Initializes the contract with registry addresses and the traded assets.
    /// @param _teeExtensionRegistry Address of the TEE extension registry.
    /// @param _teeMachineRegistry Address of the TEE machine registry.
    /// @param _fxrp The premium asset (FXRP).
    /// @param _yt The yield token escrowed and sold.
    constructor(
        ITeeExtensionRegistry _teeExtensionRegistry,
        ITeeMachineRegistry _teeMachineRegistry,
        IERC20 _fxrp,
        IERC20 _yt
    ) {
        require(address(_teeExtensionRegistry) != address(0), "TeeExtensionRegistry cannot be zero address");
        require(address(_teeMachineRegistry) != address(0), "TeeMachineRegistry cannot be zero address");
        require(address(_teeExtensionRegistry).code.length > 0, "TeeExtensionRegistry has no code");
        require(address(_teeMachineRegistry).code.length > 0, "TeeMachineRegistry has no code");
        require(address(_fxrp) != address(0) && address(_yt) != address(0), "zero token");
        TEE_EXTENSION_REGISTRY = _teeExtensionRegistry;
        TEE_MACHINE_REGISTRY = _teeMachineRegistry;
        FXRP = _fxrp;
        YT = _yt;
        owner = msg.sender;
    }

    /// @notice Finds and sets this contract's extension id. Can only be set once.
    /// DO NOT MODIFY this function.
    function setExtensionId() external {
        require(_extensionId == 0, "Extension ID already set.");

        uint256 c = TEE_EXTENSION_REGISTRY.nextPublicExtensionId();
        for (uint256 i = FIRST_PUBLIC_EXTENSION_ID; i < c; ++i) {
            if (TEE_EXTENSION_REGISTRY.getTeeExtensionInstructionsSender(i) == address(this)) {
                _extensionId = i;
                return;
            }
        }
        revert("Extension ID not found.");
    }

    /// @notice Registers the TEE machine whose signed results this contract accepts.
    /// @dev The address is the `teeId` reported by the extension proxy's `/info`
    ///      (keccak256(pubkey.x ‖ pubkey.y)[12:]). Confidential Space has no durable storage, so
    ///      a relaunch mints a new one and this must be re-pointed.
    /// @param _teeAddress The registered TEE machine address.
    function setTeeAddress(address _teeAddress) external onlyOwner {
        require(_teeAddress != address(0), "zero TEE address");
        teeAddress = _teeAddress;
        emit TeeAddressSet(_teeAddress);
    }

    /// @notice Seller escrows YT and opens a confidential RFQ with a reserve price.
    /// @dev The reserve must be positive: minPrice == 0 would let an MM take the YT for nothing.
    /// @param _ytAmount Amount of YT put up for sale.
    /// @param _minPrice Reserve price in FXRP, enforced again at settlement.
    /// @return id The new RFQ id.
    function openRfq(uint256 _ytAmount, uint256 _minPrice) external returns (uint256 id) {
        require(_ytAmount > 0, "amount");
        require(_minPrice > 0, "reserve");
        require(YT.transferFrom(msg.sender, address(this), _ytAmount), "yt in");
        id = nextId++;
        rfqs[id] = Rfq(msg.sender, _ytAmount, _minPrice, block.timestamp + SETTLE_WINDOW, true);
        emit RfqOpened(id, msg.sender, _ytAmount, _minPrice);
    }

    /// @notice The digest a market maker signs for a sealed quote.
    /// @dev The extension verifies the MM's signature against this exact preimage, so a quote
    ///      cannot be forged for another MM or replayed into another RFQ or chain.
    /// @param _rfqId The RFQ being quoted.
    /// @param _mm The market maker making the quote.
    /// @param _ytAmount The YT amount, which must match the RFQ.
    /// @param _price The FXRP premium offered.
    /// @param _deadline Unix seconds after which the quote is void.
    /// @return The digest to sign.
    function quoteDigest(uint256 _rfqId, address _mm, uint256 _ytAmount, uint256 _price, uint256 _deadline)
        public
        view
        returns (bytes32)
    {
        return keccak256(
            abi.encode("AnchorQuote", block.chainid, address(this), _rfqId, _mm, _ytAmount, _price, _deadline)
        );
    }

    /// @notice Ask the extension to run best execution over the sealed quotes it holds for an RFQ.
    /// @dev Forwards `msg.value` as the registry's per-instruction fee; the unused remainder is
    ///      returned to the caller by the registry.
    /// @param _rfqId The RFQ to settle.
    function requestSettlement(uint256 _rfqId) external payable {
        Rfq storage q = rfqs[_rfqId];
        require(q.open, "closed");
        require(block.timestamp <= q.settleBy, "settle window closed");

        address[] memory teeIds = TEE_MACHINE_REGISTRY.getRandomTeeIds(_getExtensionId(), 1);
        address[] memory cosigners = new address[](0);

        ITeeExtensionRegistry.TeeInstructionParams memory params = ITeeExtensionRegistry.TeeInstructionParams({
            opType: OP_TYPE_RFQ,
            opCommand: OP_COMMAND_SETTLE,
            message: abi.encode(SettleMessage({rfqId: _rfqId, contractAddr: address(this)})),
            cosigners: cosigners,
            cosignersThreshold: 0,
            claimBackAddress: msg.sender
        });

        bytes32 instructionId = TEE_EXTENSION_REGISTRY.sendInstructions{value: msg.value}(teeIds, params);
        emit SettlementRequested(_rfqId, instructionId);
    }

    /// @notice Execute a TEE-signed winning settlement. Anyone may relay it.
    /// @dev The TEE node signs `keccak256(abi.encode(TEE_ACTION_RESULT_PREFIX, chainId,
    ///      ActionResult.Hash()))` with its registered key under the EIP-191 personal-sign prefix.
    ///      We rebuild that hash from the result fields the proxy returned and require the signer
    ///      to equal `teeAddress`. `_resultData` is the exact bytes the extension returned in
    ///      ActionResult.Data: abi.encode(address contractAddr, uint256 rfqId, address seller,
    ///      address winner, uint256 ytAmount, uint256 price, uint256 deadline).
    ///      Every field is re-checked against this contract's own storage, so a signed result can
    ///      neither change the RFQ terms nor clear the seller's reserve.
    /// @param _resultData    ActionResult.Data bytes (the settlement payload).
    /// @param _actionId      ActionResult.ID.
    /// @param _submissionTag ActionResult.SubmissionTag (e.g. "submit").
    /// @param _status        ActionResult.Status (1 = success).
    /// @param _signature     TEE node signature over the domain-separated ActionResult hash.
    function settle(
        bytes calldata _resultData,
        bytes32 _actionId,
        string calldata _submissionTag,
        uint8 _status,
        bytes calldata _signature
    ) external {
        require(teeAddress != address(0), "TEE address not set");
        require(_status == 1, "TEE reported failure");

        // Reconstruct ActionResult.Hash() = keccak256(keccak256(data) || id || keccak256(tag) || status).
        bytes32 resultHash = keccak256(
            abi.encodePacked(keccak256(_resultData), _actionId, keccak256(bytes(_submissionTag)), _status)
        );

        // The node signs a domain-separated payload over resultHash, not resultHash directly.
        bytes32 payloadHash = keccak256(abi.encode(TEE_ACTION_RESULT_PREFIX, block.chainid, resultHash));
        require(_recover(_ethSigned(payloadHash), _signature) == teeAddress, "bad TEE signature");

        (
            address contractAddr,
            uint256 rfqId,
            address seller,
            address winner,
            uint256 ytAmount,
            uint256 price,
            uint256 deadline
        ) = abi.decode(_resultData, (address, uint256, address, address, uint256, uint256, uint256));

        require(contractAddr == address(this), "settlement not for this contract");

        Rfq storage q = rfqs[rfqId];
        require(q.open, "closed");
        require(q.seller == seller && q.ytAmount == ytAmount, "mismatch");
        require(price >= q.minPrice, "below reserve");
        require(block.timestamp <= q.settleBy, "settle window closed"); // bounds the MM's exposure
        require(block.timestamp <= deadline, "expired");
        require(winner != address(0), "no winner");

        q.open = false;
        // winner pays the FXRP premium to the seller; escrowed YT goes to the winner
        require(FXRP.transferFrom(winner, seller, price), "fxrp pay");
        require(YT.transfer(winner, ytAmount), "yt xfer");
        emit RfqSettled(rfqId, seller, winner, ytAmount, price);
    }

    /// @notice Seller reclaims escrowed YT if the RFQ was never settled.
    /// @param _id The RFQ to cancel.
    function cancel(uint256 _id) external {
        Rfq storage q = rfqs[_id];
        require(q.open && q.seller == msg.sender, "no");
        require(block.timestamp > q.settleBy, "settle window open"); // cannot front-run a pending settle
        q.open = false;
        require(YT.transfer(msg.sender, q.ytAmount), "yt back");
        emit RfqCancelled(_id);
    }

    /// @notice Returns the cached extension ID, reverting if not yet set.
    /// @return The extension ID assigned to this contract.
    function _getExtensionId() internal view returns (uint256) {
        require(_extensionId != 0, "Extension ID is not set.");
        return _extensionId;
    }

    /// @dev EIP-191 personal-sign wrapper over a 32-byte hash.
    function _ethSigned(bytes32 _hash) private pure returns (bytes32) {
        return keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", _hash));
    }

    /// @dev Recovers the signer of a 65-byte (r,s,v) signature; returns address(0) on a bad shape.
    function _recover(bytes32 _digest, bytes calldata _sig) private pure returns (address) {
        if (_sig.length != 65) return address(0);
        bytes32 r = bytes32(_sig[0:32]);
        bytes32 s = bytes32(_sig[32:64]);
        uint8 v = uint8(_sig[64]);
        if (v < 27) v += 27;
        if (v != 27 && v != 28) return address(0);
        // reject the malleable upper half of the curve order
        if (uint256(s) > 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0) return address(0);
        return ecrecover(_digest, v, r, s);
    }
}
