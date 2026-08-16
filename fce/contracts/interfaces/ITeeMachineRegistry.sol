// SPDX-License-Identifier: MIT
pragma solidity >=0.7.6 <0.9;

// TODO: Replace this minimal interface with the full import once flare-smart-contracts-v2
// is published as a package:
//   import { ITeeMachineRegistry } from "flare-smart-contracts-v2/contracts/userInterfaces/tee/ITeeMachineRegistry.sol";
interface ITeeMachineRegistry {
    function getRandomTeeIds(uint256 _extensionId, uint256 _count)
        external view returns (address[] memory);

    // The machines currently at PRODUCTION status for an extension, with their
    // URLs. `settle` uses this to check that a settlement was signed by a genuine
    // active machine for this extension, not merely by whatever address the owner
    // last pinned.
    function getActiveTeeMachines(uint256 _extensionId)
        external view returns (address[] memory teeIds, string[] memory urls);
}
