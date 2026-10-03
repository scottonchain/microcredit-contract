// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { Ownable, Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { IReceiver } from "./interfaces/IReceiver.sol";
import { IScoreProvider } from "./interfaces/IScoreProvider.sol";

/**
 * @title OracleScoreProvider
 * @notice Credit scores computed off-chain (personalized PageRank over the attestation graph,
 *         see packages/nextjs/utils/scoring) and published here in batches. Reports arrive from
 *         a Chainlink CRE workflow through its forwarder ({onReport}) or, where no forwarder is
 *         configured, from a trusted reporter account ({publishScores}).
 * @dev A report is `abi.encode(uint64 epoch, address[] users, uint256[] scores)`. Epochs must
 *      increase, so a report cannot be replayed or applied out of order. Scores read as 0 once
 *      no report has arrived for `maxScoreAge`, so a stalled oracle stops new lending instead
 *      of lending on stale trust; the workflow sends an empty report as a heartbeat when no
 *      score changed.
 */
contract OracleScoreProvider is IScoreProvider, IReceiver, Ownable2Step {
    uint256 public constant SCALE = 1e6;
    uint256 public constant MAX_BATCH = 500;
    uint256 public constant MIN_SCORE_AGE = 1 hours;
    uint256 public constant MAX_SCORE_AGE = 30 days;

    address public forwarder; // Chainlink CRE forwarder; zero disables onReport
    address public expectedWorkflowOwner; // zero accepts any workflow owner
    bytes32 public expectedWorkflowId; // zero accepts any workflow id
    address public reporter; // direct publisher; zero disables publishScores
    uint256 public maxScoreAge;

    uint64 public epoch;
    uint256 public lastReportAt;
    mapping(address => uint256) private _scores;
    address[] private _scoredUsers;
    mapping(address => bool) private _isScored;

    event ScoresPublished(uint64 indexed epoch, uint256 count);
    event ForwarderUpdated(address forwarder, address workflowOwner, bytes32 workflowId);
    event ReporterUpdated(address reporter);
    event MaxScoreAgeUpdated(uint256 maxScoreAge);

    error NotForwarder();
    error NotReporter();
    error UnexpectedWorkflow();
    error StaleEpoch();
    error BatchTooLarge();
    error LengthMismatch();
    error ScoreTooHigh();
    error InvalidMaxScoreAge();

    constructor(address initialOwner, address initialReporter, uint256 initialMaxScoreAge) Ownable(initialOwner) {
        reporter = initialReporter;
        _setMaxScoreAge(initialMaxScoreAge);
        emit ReporterUpdated(initialReporter);
    }

    // ───────────────────────────── reports ─────────────────────────────

    /// @inheritdoc IReceiver
    function onReport(bytes calldata metadata, bytes calldata report) external {
        if (forwarder == address(0) || msg.sender != forwarder) revert NotForwarder();
        (bytes32 workflowId, address workflowOwner) = _decodeMetadata(metadata);
        if (expectedWorkflowOwner != address(0) && workflowOwner != expectedWorkflowOwner) revert UnexpectedWorkflow();
        if (expectedWorkflowId != bytes32(0) && workflowId != expectedWorkflowId) revert UnexpectedWorkflow();
        _applyReport(report);
    }

    /// @notice Publish a report directly (local development, or an oracle without CRE).
    function publishScores(bytes calldata report) external {
        if (reporter == address(0) || msg.sender != reporter) revert NotReporter();
        _applyReport(report);
    }

    // ───────────────────────────── views ─────────────────────────────

    /// @inheritdoc IScoreProvider
    function creditScore(address user) external view returns (uint256) {
        return isFresh() ? _scores[user] : 0;
    }

    /// @notice Whether a report arrived within `maxScoreAge`.
    function isFresh() public view returns (bool) {
        return lastReportAt != 0 && block.timestamp <= lastReportAt + maxScoreAge;
    }

    /// @notice Every user ever scored and their latest published score (stale or not).
    function getScores() external view returns (address[] memory users, uint256[] memory scores) {
        users = _scoredUsers;
        scores = new uint256[](users.length);
        for (uint256 i = 0; i < users.length; i++) {
            scores[i] = _scores[users[i]];
        }
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IReceiver).interfaceId || interfaceId == type(IERC165).interfaceId
            || interfaceId == type(IScoreProvider).interfaceId;
    }

    // ───────────────────────────── admin ─────────────────────────────

    /// @notice Accept CRE reports from `newForwarder`, optionally pinned to one workflow.
    function setForwarder(address newForwarder, address workflowOwner, bytes32 workflowId) external onlyOwner {
        forwarder = newForwarder;
        expectedWorkflowOwner = workflowOwner;
        expectedWorkflowId = workflowId;
        emit ForwarderUpdated(newForwarder, workflowOwner, workflowId);
    }

    function setReporter(address newReporter) external onlyOwner {
        reporter = newReporter;
        emit ReporterUpdated(newReporter);
    }

    function setMaxScoreAge(uint256 newMaxScoreAge) external onlyOwner {
        _setMaxScoreAge(newMaxScoreAge);
    }

    // ───────────────────────────── internals ─────────────────────────────

    function _applyReport(bytes calldata report) internal {
        (uint64 reportEpoch, address[] memory users, uint256[] memory scores) =
            abi.decode(report, (uint64, address[], uint256[]));
        if (reportEpoch <= epoch) revert StaleEpoch();
        if (users.length != scores.length) revert LengthMismatch();
        if (users.length > MAX_BATCH) revert BatchTooLarge();

        for (uint256 i = 0; i < users.length; i++) {
            if (scores[i] > SCALE) revert ScoreTooHigh();
            _scores[users[i]] = scores[i];
            if (!_isScored[users[i]]) {
                _isScored[users[i]] = true;
                _scoredUsers.push(users[i]);
            }
        }
        epoch = reportEpoch;
        lastReportAt = block.timestamp;
        emit ScoresPublished(reportEpoch, users.length);
    }

    function _setMaxScoreAge(uint256 newMaxScoreAge) internal {
        if (newMaxScoreAge < MIN_SCORE_AGE || newMaxScoreAge > MAX_SCORE_AGE) revert InvalidMaxScoreAge();
        maxScoreAge = newMaxScoreAge;
        emit MaxScoreAgeUpdated(newMaxScoreAge);
    }

    /// @dev CRE metadata is abi.encodePacked(bytes32 workflowId, bytes10 workflowName,
    ///      address workflowOwner, bytes2 reportId).
    function _decodeMetadata(bytes calldata metadata) internal pure returns (bytes32 workflowId, address owner_) {
        if (metadata.length < 62) revert UnexpectedWorkflow();
        workflowId = bytes32(metadata[0:32]);
        owner_ = address(bytes20(metadata[42:62]));
    }
}
