// SPDX-License-Identifier: MIT
// Vendored from https://github.com/smartcontractkit/chainlink/blob/v2.22.0/contracts/src/v0.8/keystone/interfaces/IReceiver.sol
pragma solidity ^0.8.0;

import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/// @title IReceiver
/// @notice Keystone report sink. Implementations advertise themselves via ERC165.
interface IReceiver is IERC165 {
    /// @notice Handle a signed keystone report delivered by the CRE forwarder.
    /// @param metadata Workflow id / owner / name carried alongside the report.
    /// @param report Workflow-defined payload.
    function onReport(bytes calldata metadata, bytes calldata report) external;
}
