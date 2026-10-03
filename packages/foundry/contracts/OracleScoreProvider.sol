// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { Ownable, Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { IReceiver } from "./interfaces/IReceiver.sol";
import { IScoreProvider } from "./interfaces/IScoreProvider.sol";

/// @dev What the provider needs from the lending pool to know a line is no longer in use.
interface ICreditUsage {
    function activeLoanCount(address account) external view returns (uint256);
    function creditCommitted(address account) external view returns (uint256);
}

/**
 * @title OracleScoreProvider
 * @notice Credit lines issued by an off-chain issuer and published here in batches. A score is
 *         the share of DecentralizedMicrocredit.maxLoanAmount the account may borrow on its own
 *         credit. Reports arrive from a Chainlink CRE workflow through its forwarder
 *         ({onReport}) or, where no forwarder is configured, from a trusted reporter account
 *         ({publishScores}).
 * @dev Every published score is new unsecured credit, so the lending pool's worst-case loss
 *      grows with the lines issued (docs/CREDIT_MODEL.md, Theorem 2). Issuance is therefore
 *      budgeted, and the budget is charged for a line while the line may be in use: lowering a
 *      score cuts the account's credit at once but keeps its budget held until {releaseBudget}
 *      sees the account with no open loans and no backing commitments in the lending pool.
 *      Otherwise a compromised workflow could rotate one budget through many accounts, each
 *      borrowing before its line moves on. The sum of held budget may not exceed
 *      `maxTotalScore`, and one report may raise it by at most `maxIncreasePerReport`. A
 *      compromised or gamed workflow can misallocate its budget but cannot have more than the
 *      budget lent against its lines at any time. The issuer's policy must not derive scores from the
 *      backing graph or from repayment counts alone: both can be produced by fresh accounts at no
 *      cost (Theorem 3); history is information for an issuer that answers for its lines.
 *
 *      A report is `abi.encode(uint64 epoch, address[] users, uint256[] scores)`. Epochs must
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
    uint256 public maxTotalScore; // issuance budget: cap on the sum of current scores
    uint256 public maxIncreasePerReport; // cap on how much one report may raise that sum
    uint256 public totalScore; // sum of current scores
    uint256 public totalHeld; // sum of budget held, what maxTotalScore bounds
    mapping(address => uint256) public budgetHeld; // highest score since the account's line was last unused
    ICreditUsage public lending; // the pool the lines are issued into

    uint64 public epoch;
    uint256 public lastReportAt;
    mapping(address => uint256) private _scores;
    address[] private _scoredUsers;
    mapping(address => bool) private _isScored;

    event ScoresPublished(uint64 indexed epoch, uint256 count);
    event ForwarderUpdated(address forwarder, address workflowOwner, bytes32 workflowId);
    event ReporterUpdated(address reporter);
    event MaxScoreAgeUpdated(uint256 maxScoreAge);
    event IssuanceLimitsUpdated(uint256 maxTotalScore, uint256 maxIncreasePerReport);
    event LendingUpdated(address lending);
    event BudgetReleased(address indexed user, uint256 amount);

    error NotForwarder();
    error NotReporter();
    error UnexpectedWorkflow();
    error StaleEpoch();
    error BatchTooLarge();
    error LengthMismatch();
    error ScoreTooHigh();
    error InvalidMaxScoreAge();
    error IssuanceBudgetExceeded();
    error LendingNotSet();

    /// @param initialMaxTotalScore Issuance budget in score units: N x SCALE allows N full lines.
    constructor(address initialOwner, address initialReporter, uint256 initialMaxScoreAge, uint256 initialMaxTotalScore)
        Ownable(initialOwner)
    {
        reporter = initialReporter;
        _setMaxScoreAge(initialMaxScoreAge);
        _setIssuanceLimits(initialMaxTotalScore, initialMaxTotalScore);
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

    /**
     * @notice Release the budget held above each account's current score once its line is no
     *         longer in use: no open loans and nothing committed to backing others. Anyone may
     *         call it; accounts still using their line are skipped.
     */
    function releaseBudget(address[] calldata users) external {
        if (address(lending) == address(0)) revert LendingNotSet();
        if (users.length > MAX_BATCH) revert BatchTooLarge();
        for (uint256 i = 0; i < users.length; i++) {
            address user = users[i];
            uint256 held = budgetHeld[user];
            uint256 score = _scores[user];
            if (held <= score || lending.activeLoanCount(user) != 0 || lending.creditCommitted(user) != 0) continue;
            budgetHeld[user] = score;
            totalHeld -= held - score;
            emit BudgetReleased(user, held - score);
        }
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

    /// @notice The lending pool these lines are issued into; {releaseBudget} reads usage from it.
    function setLending(ICreditUsage newLending) external onlyOwner {
        lending = newLending;
        emit LendingUpdated(address(newLending));
    }

    /// @notice Set the issuance budget and the most one report may add to held budget. Lowering
    ///         the budget below `totalHeld` blocks reports that raise any score until it is back under.
    function setIssuanceLimits(uint256 newMaxTotalScore, uint256 newMaxIncreasePerReport) external onlyOwner {
        _setIssuanceLimits(newMaxTotalScore, newMaxIncreasePerReport);
    }

    // ───────────────────────────── internals ─────────────────────────────

    function _applyReport(bytes calldata report) internal {
        (uint64 reportEpoch, address[] memory users, uint256[] memory scores) =
            abi.decode(report, (uint64, address[], uint256[]));
        if (reportEpoch <= epoch) revert StaleEpoch();
        if (users.length != scores.length) revert LengthMismatch();
        if (users.length > MAX_BATCH) revert BatchTooLarge();

        uint256 total = totalScore;
        uint256 held = totalHeld;
        uint256 increase = 0;
        for (uint256 i = 0; i < users.length; i++) {
            if (scores[i] > SCALE) revert ScoreTooHigh();
            total = total + scores[i] - _scores[users[i]];
            uint256 userHeld = budgetHeld[users[i]];
            if (scores[i] > userHeld) {
                increase += scores[i] - userHeld;
                held += scores[i] - userHeld;
                budgetHeld[users[i]] = scores[i];
            }
            _scores[users[i]] = scores[i];
            if (!_isScored[users[i]]) {
                _isScored[users[i]] = true;
                _scoredUsers.push(users[i]);
            }
        }
        if (increase > 0 && (held > maxTotalScore || increase > maxIncreasePerReport)) {
            revert IssuanceBudgetExceeded();
        }
        totalScore = total;
        totalHeld = held;
        epoch = reportEpoch;
        lastReportAt = block.timestamp;
        emit ScoresPublished(reportEpoch, users.length);
    }

    function _setIssuanceLimits(uint256 newMaxTotalScore, uint256 newMaxIncreasePerReport) internal {
        maxTotalScore = newMaxTotalScore;
        maxIncreasePerReport = newMaxIncreasePerReport;
        emit IssuanceLimitsUpdated(newMaxTotalScore, newMaxIncreasePerReport);
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
