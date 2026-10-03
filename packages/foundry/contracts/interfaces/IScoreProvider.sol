// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title IScoreProvider
/// @notice Source of borrower credit scores for DecentralizedMicrocredit. Scores are computed
///         off-chain (trust ranking over the attestation graph) and delivered by an oracle, so
///         the provider can be swapped without touching the lending contract.
interface IScoreProvider {
    /// @notice Credit score of `user` in SCALE units (1e6 = 100%); 0 when unknown or stale.
    function creditScore(address user) external view returns (uint256);
}
