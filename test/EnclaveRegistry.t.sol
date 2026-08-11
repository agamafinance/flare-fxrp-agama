// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "forge-std/Test.sol";
import "../src/EnclaveRegistry.sol";

/**
 * Attestation-gated enclave registration. The vector (test/vectors/rsa_attestation.json) is a real
 * RS256 signature (openssl RSA-2048, the same primitive GCP Confidential Space uses) over the
 * attestation statement abi.encode(enclaveKey, imageDigest, nonce). The registry accepts the key
 * only if that signature verifies on chain against the attester modulus and the code image matches.
 */
contract EnclaveRegistryTest is Test {
    EnclaveRegistry reg;
    bytes n;
    bytes e = hex"010001";
    address enclave;
    bytes32 imageDigest;
    uint256 nonce;
    bytes sig;

    function setUp() public {
        string memory j = vm.readFile("test/vectors/rsa_attestation.json");
        n = vm.parseJsonBytes(j, ".n");
        enclave = vm.parseJsonAddress(j, ".enclave");
        imageDigest = vm.parseJsonBytes32(j, ".imageDigest");
        nonce = vm.parseJsonUint(j, ".nonce");
        sig = vm.parseJsonBytes(j, ".sig");
        reg = new EnclaveRegistry(n, e, imageDigest);
    }

    function test_RegistersEnclaveFromValidAttestation() public {
        assertEq(reg.enclaveSigner(), address(0), "no key before attestation");
        reg.registerEnclave(enclave, imageDigest, nonce, sig);
        assertEq(reg.enclaveSigner(), enclave, "enclave key registered from a verified attestation");
    }

    function test_RejectsTamperedSignature() public {
        bytes memory bad = sig;
        bad[10] = bytes1(uint8(bad[10]) ^ 0xff);
        vm.expectRevert(bytes("bad attestation signature"));
        reg.registerEnclave(enclave, imageDigest, nonce, bad);
    }

    function test_RejectsForgedEnclaveKey() public {
        // a valid signature but a different claimed key -> statement mismatch -> verification fails
        vm.expectRevert(bytes("bad attestation signature"));
        reg.registerEnclave(address(0xdead), imageDigest, nonce, sig);
    }

    function test_RejectsUnapprovedImage() public {
        vm.expectRevert(bytes("unexpected enclave image"));
        reg.registerEnclave(enclave, bytes32(uint256(1)), nonce, sig);
    }
}
