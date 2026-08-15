// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import "forge-std/Test.sol";
import { AgamaRfqInstructionSender, IERC20 } from "../contracts/InstructionSender.sol";
import { ITeeExtensionRegistry } from "../contracts/interfaces/ITeeExtensionRegistry.sol";
import { ITeeMachineRegistry } from "../contracts/interfaces/ITeeMachineRegistry.sol";

/// Minimal mintable ERC20 for the escrow and the premium.
contract MockERC20 is IERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "balance");
        require(allowance[from][msg.sender] >= amount, "allowance");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// Stand-in for FTSOv2. `decimals` is signed, as in the real feed.
contract MockFtso {
    uint256 public value;
    int8 public dec;
    uint64 public ts;

    constructor(uint256 _value, int8 _dec, uint64 _ts) {
        value = _value;
        dec = _dec;
        ts = _ts;
    }

    function set(uint256 _value, uint64 _ts) external {
        value = _value;
        ts = _ts;
    }

    function getFeedById(bytes21) external payable returns (uint256, int8, uint64) {
        return (value, dec, ts);
    }
}

/// Stand-in for the FlareTeeManager diamond: records what was routed to the TEE.
contract MockTeeManager is ITeeExtensionRegistry, ITeeMachineRegistry {
    address public instructionSender;
    uint256 public constant EXTENSION_ID = 0x10000;
    bytes public lastMessage;
    bytes32 public lastOpType;
    bytes32 public lastOpCommand;
    uint256 public feePaid;

    function register(address _sender) external {
        instructionSender = _sender;
    }

    function nextPublicExtensionId() external pure returns (uint256) {
        return EXTENSION_ID + 1;
    }

    function getTeeExtensionInstructionsSender(uint256 _extensionId) external view returns (address) {
        return _extensionId == EXTENSION_ID ? instructionSender : address(0);
    }

    function getRandomTeeIds(uint256, uint256 _count) external pure returns (address[] memory ids) {
        ids = new address[](_count);
        for (uint256 i = 0; i < _count; ++i) {
            ids[i] = address(uint160(0x7EE0 + i));
        }
    }

    function sendInstructions(address[] calldata, TeeInstructionParams calldata _params)
        external
        payable
        returns (bytes32)
    {
        lastOpType = _params.opType;
        lastOpCommand = _params.opCommand;
        lastMessage = _params.message;
        feePaid = msg.value;
        return keccak256(abi.encode(_params.message, block.timestamp));
    }
}

contract AgamaRfqTest is Test {
    AgamaRfqInstructionSender internal rfq;
    MockTeeManager internal manager;
    MockERC20 internal fxrp;
    MockERC20 internal yt;

    uint256 internal teeKey = 0x7EE5EC;
    address internal tee;

    address internal seller = address(0x5E11E4);
    address internal winner = address(0x3117E);

    uint256 internal constant YT_AMOUNT = 100_000_000; // 100 YT at 6dp
    uint256 internal constant RESERVE = 2_000_000; // 2 FXRP
    uint256 internal constant PRICE = 6_000_000; // 6 FXRP

    string internal constant TAG = "submit";

    MockFtso internal ftso;
    address internal constant REGISTRY = 0xaD67FE66660Fb8dFE9d6b1b4240d8650e30F6019;

    /// XRP at $0.50, published now. 6 FXRP is then $3 — inside the band.
    function _mockOracle() internal {
        ftso = new MockFtso(50_000_000, 8, uint64(block.timestamp)); // 0.5 with 8 decimals
        vm.mockCall(
            REGISTRY,
            abi.encodeWithSignature("getContractAddressByName(string)", "FtsoV2"),
            abi.encode(address(ftso))
        );
    }

    function setUp() public {
        _mockOracle();
        tee = vm.addr(teeKey);
        manager = new MockTeeManager();
        fxrp = new MockERC20();
        yt = new MockERC20();
        rfq = new AgamaRfqInstructionSender(
            ITeeExtensionRegistry(address(manager)),
            ITeeMachineRegistry(address(manager)),
            IERC20(address(fxrp)),
            IERC20(address(yt))
        );
        manager.register(address(rfq));
        rfq.setExtensionId();
        rfq.setTeeAddress(tee);

        yt.mint(seller, YT_AMOUNT);
        vm.prank(seller);
        yt.approve(address(rfq), YT_AMOUNT);

        fxrp.mint(winner, 100_000_000);
        vm.prank(winner);
        fxrp.approve(address(rfq), 100_000_000);
    }

    // --- helpers -------------------------------------------------------------

    function _openRfq() internal returns (uint256 id) {
        vm.prank(seller);
        id = rfq.openRfq(YT_AMOUNT, RESERVE);
    }

    function _resultData(uint256 rfqId, address who, uint256 price, uint256 deadline)
        internal
        view
        returns (bytes memory)
    {
        return abi.encode(address(rfq), rfqId, seller, who, YT_AMOUNT, price, deadline);
    }

    /// Signs a result the way tee-node does: EIP-191 over the domain-separated ActionResult hash.
    function _sign(uint256 key, bytes memory data, bytes32 actionId, uint8 status)
        internal
        view
        returns (bytes memory)
    {
        bytes32 resultHash =
            keccak256(abi.encodePacked(keccak256(data), actionId, keccak256(bytes(TAG)), status));
        bytes32 payloadHash = keccak256(abi.encode(bytes32("TEE_ACTION_RESULT"), block.chainid, resultHash));
        bytes32 digest = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", payloadHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }

    // --- the RFQ lifecycle ---------------------------------------------------

    function test_OpenEscrowsTheYt() public {
        uint256 id = _openRfq();
        assertEq(id, 1);
        assertEq(yt.balanceOf(address(rfq)), YT_AMOUNT, "escrowed");
        (address s,,,, bool open) = rfq.rfqs(id);
        assertEq(s, seller);
        assertTrue(open);
    }

    function test_OpenRequiresAReserve() public {
        vm.prank(seller);
        vm.expectRevert("reserve");
        rfq.openRfq(YT_AMOUNT, 0);
    }

    function test_RequestSettlementRoutesAnRfqSettleInstruction() public {
        uint256 id = _openRfq();
        rfq.requestSettlement{value: 1_000_000}(id);

        assertEq(manager.lastOpType(), bytes32("RFQ"));
        assertEq(manager.lastOpCommand(), bytes32("SETTLE"));
        assertEq(manager.feePaid(), 1_000_000, "instruction fee forwarded");
        (uint256 sentId, address sentContract) = abi.decode(manager.lastMessage(), (uint256, address));
        assertEq(sentId, id);
        assertEq(sentContract, address(rfq), "the extension reads terms from this contract");
    }

    function test_SignedSettlementExecutesAtomically() public {
        uint256 id = _openRfq();
        bytes32 actionId = keccak256("action");
        bytes memory data = _resultData(id, winner, PRICE, block.timestamp + 600);

        rfq.settle(data, actionId, TAG, 1, _sign(teeKey, data, actionId, 1));

        assertEq(fxrp.balanceOf(seller), PRICE, "seller got the premium");
        assertEq(yt.balanceOf(winner), YT_AMOUNT, "winner got the YT");
        (,,,, bool open) = rfq.rfqs(id);
        assertFalse(open, "rfq closed");
    }

    // --- what the contract refuses to take on trust ---------------------------

    function test_ForgedSignatureIsRejected() public {
        uint256 id = _openRfq();
        bytes32 actionId = keccak256("action");
        bytes memory data = _resultData(id, winner, PRICE, block.timestamp + 600);

        vm.expectRevert("bad TEE signature");
        rfq.settle(data, actionId, TAG, 1, _sign(0xBADBAD, data, actionId, 1));
    }

    function test_ATamperedResultIsRejected() public {
        uint256 id = _openRfq();
        bytes32 actionId = keccak256("action");
        bytes memory signed = _resultData(id, winner, PRICE, block.timestamp + 600);
        bytes memory signature = _sign(teeKey, signed, actionId, 1);

        // the relayer tries to redirect the YT to itself
        bytes memory tampered = _resultData(id, address(0xBEEF), PRICE, block.timestamp + 600);
        vm.expectRevert("bad TEE signature");
        rfq.settle(tampered, actionId, TAG, 1, signature);
    }

    function test_ABelowReserveSettlementIsRejectedEvenWhenSigned() public {
        // The seller's floor is enforced here, not only inside the enclave.
        uint256 id = _openRfq();
        bytes32 actionId = keccak256("action");
        bytes memory data = _resultData(id, winner, RESERVE - 1, block.timestamp + 600);

        vm.expectRevert("below reserve");
        rfq.settle(data, actionId, TAG, 1, _sign(teeKey, data, actionId, 1));
    }

    function test_ASettlementForAnotherContractIsRejected() public {
        uint256 id = _openRfq();
        bytes32 actionId = keccak256("action");
        bytes memory data =
            abi.encode(address(0xDEAD), id, seller, winner, YT_AMOUNT, PRICE, block.timestamp + 600);

        vm.expectRevert("settlement not for this contract");
        rfq.settle(data, actionId, TAG, 1, _sign(teeKey, data, actionId, 1));
    }

    function test_AFailedTeeResultIsRejected() public {
        uint256 id = _openRfq();
        bytes32 actionId = keccak256("action");
        bytes memory data = _resultData(id, winner, PRICE, block.timestamp + 600);

        vm.expectRevert("TEE reported failure");
        rfq.settle(data, actionId, TAG, 0, _sign(teeKey, data, actionId, 0));
    }

    function test_ASettlementCannotBeReplayed() public {
        uint256 id = _openRfq();
        bytes32 actionId = keccak256("action");
        bytes memory data = _resultData(id, winner, PRICE, block.timestamp + 600);
        bytes memory signature = _sign(teeKey, data, actionId, 1);

        rfq.settle(data, actionId, TAG, 1, signature);
        vm.expectRevert("closed");
        rfq.settle(data, actionId, TAG, 1, signature);
    }

    function test_SettlementAfterTheWindowIsRejected() public {
        uint256 id = _openRfq();
        bytes32 actionId = keccak256("action");
        bytes memory data = _resultData(id, winner, PRICE, block.timestamp + 10_000);
        bytes memory signature = _sign(teeKey, data, actionId, 1);

        vm.warp(block.timestamp + rfq.SETTLE_WINDOW() + 1);
        vm.expectRevert("settle window closed");
        rfq.settle(data, actionId, TAG, 1, signature);
    }

    // --- the oracle bounds the enclave, not the other way round ----------------

    function test_APremiumAboveTheUsdCapIsRejectedEvenWhenSigned() public {
        // 60 FXRP at $0.50 is $30, over the $10 per-settlement cap. The enclave would
        // never pick it — this proves the contract refuses it anyway.
        uint256 id = _openRfq();
        bytes32 actionId = keccak256("action");
        bytes memory data = _resultData(id, winner, 60_000_000, block.timestamp + 600);

        vm.expectRevert("premium above the USD cap");
        rfq.settle(data, actionId, TAG, 1, _sign(teeKey, data, actionId, 1));
    }

    function test_APremiumBelowTheUsdFloorIsRejected() public {
        // The seller's reserve is in tokens; the floor is in USD. A 2 FXRP reserve is
        // $1 here, but drop the oracle to $0.05 and the same trade is worth $0.10.
        uint256 id = _openRfq();
        ftso.set(5_000_000, uint64(block.timestamp)); // $0.05
        bytes32 actionId = keccak256("action");
        bytes memory data = _resultData(id, winner, RESERVE, block.timestamp + 600);

        vm.expectRevert("premium below the USD floor");
        rfq.settle(data, actionId, TAG, 1, _sign(teeKey, data, actionId, 1));
    }

    function test_AStaleOracleFailsClosed() public {
        uint256 id = _openRfq();
        bytes32 actionId = keccak256("action");
        bytes memory data = _resultData(id, winner, PRICE, block.timestamp + 3000);
        bytes memory signature = _sign(teeKey, data, actionId, 1);

        vm.warp(block.timestamp + 11 minutes); // feed older than MAX_FEED_AGE
        vm.expectRevert("stale xrp/usd feed");
        rfq.settle(data, actionId, TAG, 1, signature);
    }

    function test_TheUsdCapNeverBindsBelowTheSellersOwnReserve() public {
        // A seller asking 100 FXRP ($50) must not be locked out by a $10 global cap.
        yt.mint(seller, YT_AMOUNT);
        vm.prank(seller);
        yt.approve(address(rfq), YT_AMOUNT);
        vm.prank(seller);
        uint256 id = rfq.openRfq(YT_AMOUNT, 40_000_000); // reserve 40 FXRP = $20

        bytes32 actionId = keccak256("bigticket");
        bytes memory data = _resultData(id, winner, 45_000_000, block.timestamp + 600); // $22.50
        rfq.settle(data, actionId, TAG, 1, _sign(teeKey, data, actionId, 1));

        assertEq(fxrp.balanceOf(seller), 45_000_000, "the seller's own floor sets the cap");
    }

    // --- cancel and settle never race ----------------------------------------

    function test_CancelOnlyOpensAfterTheSettleWindow() public {
        uint256 id = _openRfq();

        vm.prank(seller);
        vm.expectRevert("settle window open");
        rfq.cancel(id);

        vm.warp(block.timestamp + rfq.SETTLE_WINDOW() + 1);
        vm.prank(seller);
        rfq.cancel(id);
        assertEq(yt.balanceOf(seller), YT_AMOUNT, "seller reclaimed the YT");
    }

    // --- the quote digest is a cross-language contract -------------------------

    function test_QuoteDigestMatchesTheExtension() public {
        // The extension (python/app/quotes.py) recovers the market maker against this
        // exact preimage. A mismatch would silently reject every authentic quote, so the
        // vector is generated by the Python side and replayed here.
        string memory json = vm.readFile("test/vectors/quote_digest.json");
        address vectorRfq = vm.parseJsonAddress(json, ".rfq");
        uint256 chainId = vm.parseJsonUint(json, ".chainId");
        uint256 rfqId = vm.parseJsonUint(json, ".rfqId");
        address mm = vm.parseJsonAddress(json, ".mm");
        uint256 ytAmount = vm.parseJsonUint(json, ".ytAmount");
        uint256 price = vm.parseJsonUint(json, ".price");
        uint256 deadline = vm.parseJsonUint(json, ".deadline");
        bytes32 expected = vm.parseJsonBytes32(json, ".digest");

        // quoteDigest binds the contract address and chain id, so reproduce both.
        vm.chainId(chainId);
        vm.etch(vectorRfq, address(rfq).code);

        assertEq(
            AgamaRfqInstructionSender(vectorRfq).quoteDigest(rfqId, mm, ytAmount, price, deadline),
            expected,
            "Solidity and the extension disagree on the quote digest"
        );
    }
}
