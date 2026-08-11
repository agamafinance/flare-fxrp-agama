// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "forge-std/Test.sol";
import "../src/tee/ConfidentialSpaceRegistry.sol";

/**
 * Verifies a Confidential Space attestation JWT on chain and registers the enclave key only if the
 * token is a valid RS256 Google-signed OIDC token carrying the approved code image digest and the
 * presented enclave key as its eat_nonce. The vector (test/vectors/cs_attestation_jwt.json) is a
 * JWT in the exact Confidential Space format, signed by a test RSA key (production uses Google's
 * JWKS key). Also checks Base64URL decoding of a real JWT payload.
 */
contract ConfidentialSpaceRegistryTest is Test {
    ConfidentialSpaceRegistry reg;
    bytes header;
    bytes payload;
    bytes sig;
    bytes n;
    bytes e = hex"010001";
    bytes imageDigest;
    address enclave;

    function setUp() public {
        string memory j = vm.readFile("test/vectors/cs_attestation_jwt.json");
        header = bytes(vm.parseJsonString(j, ".headerB64"));
        payload = bytes(vm.parseJsonString(j, ".payloadB64"));
        sig = vm.parseJsonBytes(j, ".sig");
        n = vm.parseJsonBytes(j, ".n");
        imageDigest = bytes(vm.parseJsonString(j, ".imageDigest"));
        enclave = vm.parseJsonAddress(j, ".enclave");
        reg = new ConfidentialSpaceRegistry(n, e, imageDigest);
    }

    function test_Base64UrlDecodesJwtPayload() public view {
        bytes memory decoded = Base64URL.decode(payload);
        // the decoded payload is JSON that contains the Confidential Space issuer
        assertGt(decoded.length, 0, "payload decodes");
    }

    function test_RegistersEnclaveFromConfidentialSpaceToken() public {
        assertEq(reg.enclaveSigner(), address(0));
        reg.registerEnclave(header, payload, sig, enclave);
        assertEq(reg.enclaveSigner(), enclave, "enclave key registered from a verified CS attestation");
    }

    function test_RejectsTamperedSignature() public {
        bytes memory bad = sig;
        bad[20] = bytes1(uint8(bad[20]) ^ 0xff);
        vm.expectRevert(bytes("bad attestation signature"));
        reg.registerEnclave(header, payload, bad, enclave);
    }

    function test_RejectsForgedEnclaveKey() public {
        // valid token, but a different claimed key that is not the token's eat_nonce
        vm.expectRevert(bytes("enclave key not the eat_nonce"));
        reg.registerEnclave(header, payload, sig, address(0xBEEF));
    }

    function test_RejectsUnapprovedImage() public {
        ConfidentialSpaceRegistry other = new ConfidentialSpaceRegistry(n, e, bytes("sha256:deadbeef"));
        vm.expectRevert(bytes("unexpected enclave image"));
        other.registerEnclave(header, payload, sig, enclave);
    }

    function _load(string memory path)
        internal
        returns (ConfidentialSpaceRegistry r, bytes memory h, bytes memory p, bytes memory sg, address enc)
    {
        string memory j = vm.readFile(path);
        h = bytes(vm.parseJsonString(j, ".headerB64"));
        p = bytes(vm.parseJsonString(j, ".payloadB64"));
        sg = vm.parseJsonBytes(j, ".sig");
        enc = vm.parseJsonAddress(j, ".enclave");
        r = new ConfidentialSpaceRegistry(vm.parseJsonBytes(j, ".n"), e, bytes(vm.parseJsonString(j, ".imageDigest")));
    }

    /// A debug Confidential Space enclave (operator can read/forge) must not be trusted.
    function test_RejectsDebugEnclave() public {
        (ConfidentialSpaceRegistry r, bytes memory h, bytes memory p, bytes memory sg, address enc) =
            _load("test/vectors/cs_attestation_debug.json");
        vm.expectRevert(bytes("debug enclave not allowed"));
        r.registerEnclave(h, p, sg, enc);
    }

    /// A non-Intel-TDX platform (e.g. AMD SEV) must not be trusted when we require TDX.
    function test_RejectsNonTdxEnclave() public {
        (ConfidentialSpaceRegistry r, bytes memory h, bytes memory p, bytes memory sg, address enc) =
            _load("test/vectors/cs_attestation_nontdx.json");
        vm.expectRevert(bytes("not Intel TDX"));
        r.registerEnclave(h, p, sg, enc);
    }

    /// The headline critical: a debug + non-TDX + wrong-image enclave that injects the approved claim
    /// strings as `submods.container.env` keys would pass a raw substring scan. The exact-path parser
    /// reads the real top-level claims and rejects it.
    function test_RejectsSubstringInjection() public {
        (ConfidentialSpaceRegistry r, bytes memory h, bytes memory p, bytes memory sg, address enc) =
            _load("test/vectors/cs_attestation_injection.json");
        vm.expectRevert(bytes("not Intel TDX")); // real top-level hwmodel is AMD SEV, not the injected env value
        r.registerEnclave(h, p, sg, enc);
    }

    /// Only the owner may register, so a leaked/stale token cannot be replayed to roll the key.
    function test_RejectsNonOwnerRegistration() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert(bytes("only owner"));
        reg.registerEnclave(header, payload, sig, enclave);
    }

    /// The same token cannot be replayed (one-time), preventing key rollback.
    function test_RejectsTokenReplay() public {
        reg.registerEnclave(header, payload, sig, enclave);
        vm.expectRevert(bytes("token replayed"));
        reg.registerEnclave(header, payload, sig, enclave);
    }
}
