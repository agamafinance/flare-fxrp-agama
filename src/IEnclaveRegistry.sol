// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

/// The trusted enclave signing key, sourced from an attestation-gated registry (never set manually).
interface IEnclaveRegistry {
    function enclaveSigner() external view returns (address);
}
