// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "forge-std/Test.sol";
import "../src/MockERC20.sol";
import "../src/MockVault.sol";
import "../src/YieldSplitter.sol";
import "../src/ConfidentialYtRfq.sol";

/// Minimal registry stand-in: the attestation-gated registration is tested in EnclaveRegistry.t.sol.
contract MockEnclaveRegistry is IEnclaveRegistry {
    address public enclaveSigner;
    constructor(address s) { enclaveSigner = s; }
}

/**
 * The confidential YT RFQ: a seller who wants a fixed rate sells their YT to the best market-maker
 * quote. Two MMs quote privately to the enclave; the enclave signs only the winner. The contract
 * verifies the enclave signature and settles. The losing quote never appears on-chain.
 *
 * The enclave is simulated with vm.sign (raw-digest ECDSA), exactly what a signer running in GCP
 * Confidential Space would produce; its address is what the contract has registered.
 */
contract ConfidentialYtRfqTest is Test {
    MockERC20 fxrp;
    MockVault vault;
    YieldSplitter splitter;
    SplitToken ytTok;
    ConfidentialYtRfq rfq;

    uint256 constant ENCLAVE_PK = uint256(keccak256("anchor-confidential-space-enclave"));
    address enclave;

    address seller = makeAddr("seller"); // wants certainty: sells YT
    address mm1 = makeAddr("mm1"); // yield-seeking market makers
    address mm2 = makeAddr("mm2");

    uint256 constant ONE = 1e6; // 6-decimal FXRP
    uint256 constant RESERVE = 5 * ONE; // seller's floor price for the YT

    function setUp() public {
        enclave = vm.addr(ENCLAVE_PK);
        fxrp = new MockERC20("Flare XRP", "FXRP", 6);
        vault = new MockVault(fxrp);
        splitter = new YieldSplitter(vault, block.timestamp + 90 days);
        ytTok = splitter.yt();
        rfq = new ConfidentialYtRfq(IERC20(address(fxrp)), IERC20(address(ytTok)), new MockEnclaveRegistry(enclave));

        // seller deposits FXRP -> PT + YT, keeps PT (certainty), will sell YT
        fxrp.mint(seller, 1000 * ONE);
        vm.startPrank(seller);
        fxrp.approve(address(splitter), type(uint256).max);
        splitter.split(1000 * ONE); // seller: 1000 PT + 1000 YT
        ytTok.approve(address(rfq), type(uint256).max);
        vm.stopPrank();

        // market makers hold FXRP to pay for YT
        fxrp.mint(mm1, 100 * ONE);
        fxrp.mint(mm2, 100 * ONE);
        vm.prank(mm1);
        fxrp.approve(address(rfq), type(uint256).max);
        vm.prank(mm2);
        fxrp.approve(address(rfq), type(uint256).max);
    }

    function _sign(ConfidentialYtRfq.Settlement memory s) internal view returns (uint8 v, bytes32 r, bytes32 sg) {
        bytes32 digest = rfq.settlementDigest(s);
        (v, r, sg) = vm.sign(ENCLAVE_PK, digest);
    }

    function test_RfqSettlesBestQuoteFromEnclave() public {
        uint256 ytAmount = 1000 * ONE;
        vm.prank(seller);
        uint256 id = rfq.openRfq(ytAmount, RESERVE);
        assertEq(ytTok.balanceOf(address(rfq)), ytAmount, "YT escrowed");

        // Off-chain: mm1 privately quotes 12 FXRP, mm2 quotes 9. The enclave picks mm1 (best for
        // the seller) and signs. mm2's quote never touches the chain.
        uint256 winningPrice = 12 * ONE;
        ConfidentialYtRfq.Settlement memory s = ConfidentialYtRfq.Settlement({
            rfqId: id,
            seller: seller,
            winner: mm1,
            ytAmount: ytAmount,
            price: winningPrice,
            deadline: block.timestamp + 1 hours
        });
        (uint8 v, bytes32 r, bytes32 sg) = _sign(s);

        rfq.settle(s, v, r, sg); // anyone can relay

        // seller sold certainty: got the premium now, still holds PT that redeems 1:1 at maturity
        assertEq(fxrp.balanceOf(seller), winningPrice, "seller received the FXRP premium");
        assertEq(ytTok.balanceOf(mm1), ytAmount, "winning MM received the YT");
        assertEq(fxrp.balanceOf(mm1), 100 * ONE - winningPrice, "winning MM paid the premium");
        assertEq(ytTok.balanceOf(address(rfq)), 0, "escrow released");
        emit log_named_decimal_uint("Seller locked (FXRP premium for YT)", winningPrice, 6);
    }

    function test_ForgedSignatureReverts() public {
        vm.prank(seller);
        uint256 id = rfq.openRfq(1000 * ONE, RESERVE);
        ConfidentialYtRfq.Settlement memory s = ConfidentialYtRfq.Settlement({
            rfqId: id, seller: seller, winner: mm1, ytAmount: 1000 * ONE, price: 50 * ONE, deadline: block.timestamp + 1 hours
        });
        // signed by a NON-enclave key -> must be rejected
        bytes32 digest = rfq.settlementDigest(s);
        (uint8 v, bytes32 r, bytes32 sg) = vm.sign(uint256(keccak256("attacker")), digest);
        vm.expectRevert(bytes("bad enclave sig"));
        rfq.settle(s, v, r, sg);
    }

    /// The seller's reserve is a hard on-chain floor: even a correctly enclave-signed settlement
    /// below it is rejected. This is the guardrail that makes the open matching endpoint safe.
    function test_BelowReservePriceReverts() public {
        vm.prank(seller);
        uint256 id = rfq.openRfq(1000 * ONE, 10 * ONE);
        ConfidentialYtRfq.Settlement memory s = ConfidentialYtRfq.Settlement({
            rfqId: id, seller: seller, winner: mm1, ytAmount: 1000 * ONE, price: 8 * ONE, deadline: block.timestamp + 1 hours
        });
        (uint8 v, bytes32 r, bytes32 sg) = _sign(s); // a REAL enclave signature, still below reserve
        vm.expectRevert(bytes("below reserve"));
        rfq.settle(s, v, r, sg);
    }

    /// The exact preimage a market maker signs for a sealed quote is the contract's `quoteDigest`.
    /// The enclave authenticates a quote by recovering this and checking it equals the claimed MM,
    /// so a caller cannot fabricate a quote for an MM. This proves the two agree byte-for-byte.
    function test_QuoteDigestMatchesMmSignature() public view {
        uint256 mmPk = uint256(keccak256("mm1-signing-key"));
        address mmAddr = vm.addr(mmPk);
        bytes32 qd = rfq.quoteDigest(1, mmAddr, 1000 * ONE, 12 * ONE, block.timestamp + 1 hours);
        (uint8 v, bytes32 r, bytes32 sg) = vm.sign(mmPk, qd);
        assertEq(ecrecover(qd, v, r, sg), mmAddr, "MM quote signature recovers to the MM");
        // a different MM address over the same terms yields a different digest (no cross-MM reuse)
        assertTrue(qd != rfq.quoteDigest(1, address(0xBEEF), 1000 * ONE, 12 * ONE, block.timestamp + 1 hours));
    }

    /// A zero reserve would let an MM take the YT for nothing, so opening with minPrice == 0 reverts.
    function test_OpenWithZeroReserveReverts() public {
        vm.prank(seller);
        vm.expectRevert(bytes("reserve"));
        rfq.openRfq(1000 * ONE, 0);
    }

    function test_SellerCanCancelUnsettled() public {
        vm.prank(seller);
        uint256 id = rfq.openRfq(1000 * ONE, RESERVE);
        vm.prank(seller);
        rfq.cancel(id);
        assertEq(ytTok.balanceOf(seller), 1000 * ONE, "seller reclaimed YT");
    }
}
