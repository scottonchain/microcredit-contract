// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { Test } from "forge-std/Test.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { OracleScoreProvider } from "../contracts/OracleScoreProvider.sol";
import { IReceiver } from "../contracts/interfaces/IReceiver.sol";
import { IScoreProvider } from "../contracts/interfaces/IScoreProvider.sol";

/// @dev Off-chain scores delivered by a reporter account or a Chainlink CRE forwarder.
contract OracleScoreProviderTest is Test {
    OracleScoreProvider internal provider;
    address internal owner = makeAddr("owner");
    address internal reporter = makeAddr("reporter");
    address internal forwarder = makeAddr("forwarder");
    address internal workflowOwner = makeAddr("workflowOwner");
    bytes32 internal constant WORKFLOW_ID = keccak256("microcredit-scores");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    uint256 internal constant MAX_AGE = 1 days;
    uint256 internal constant BUDGET = 2_000_000; // two full lines

    function setUp() public {
        provider = new OracleScoreProvider(owner, reporter, MAX_AGE, BUDGET);
    }

    function _report(uint64 epoch, address[] memory users, uint256[] memory values)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(epoch, users, values);
    }

    function _report(uint64 epoch, address user, uint256 score) internal pure returns (bytes memory) {
        address[] memory users = new address[](1);
        uint256[] memory scores = new uint256[](1);
        users[0] = user;
        scores[0] = score;
        return abi.encode(epoch, users, scores);
    }

    function _emptyReport(uint64 epoch) internal pure returns (bytes memory) {
        return abi.encode(epoch, new address[](0), new uint256[](0));
    }

    /// @dev abi.encodePacked(bytes32 workflowId, bytes10 workflowName, address owner, bytes2 reportId)
    function _metadata(bytes32 workflowId, address owner_) internal pure returns (bytes memory) {
        return abi.encodePacked(workflowId, bytes10("scores"), owner_, bytes2(0));
    }

    function _publish(bytes memory report) internal {
        vm.prank(reporter);
        provider.publishScores(report);
    }

    // ───────────────────────────── reporter ─────────────────────────────

    function testNoScoresBeforeTheFirstReport() public view {
        assertFalse(provider.isFresh());
        assertEq(provider.creditScore(alice), 0);
    }

    function testReporterPublishesScores() public {
        address[] memory users = new address[](2);
        uint256[] memory values = new uint256[](2);
        (users[0], users[1]) = (alice, bob);
        (values[0], values[1]) = (800_000, 250_000);

        vm.expectEmit(address(provider));
        emit OracleScoreProvider.ScoresPublished(1, 2);
        _publish(abi.encode(uint64(1), users, values));

        assertEq(provider.creditScore(alice), 800_000);
        assertEq(provider.creditScore(bob), 250_000);
        assertEq(provider.epoch(), 1);

        _publish(_report(2, alice, 600_000)); // later reports update only the users they carry
        (address[] memory listed, uint256[] memory listedScores) = provider.getScores();
        assertEq(listed.length, 2, "each user is listed once");
        assertEq(listedScores[0], 600_000);
        assertEq(listedScores[1], 250_000);
    }

    function testOnlyTheReporterPublishes() public {
        vm.prank(alice);
        vm.expectRevert(OracleScoreProvider.NotReporter.selector);
        provider.publishScores(_report(1, alice, 1));

        vm.prank(owner);
        provider.setReporter(address(0));
        vm.prank(reporter);
        vm.expectRevert(OracleScoreProvider.NotReporter.selector);
        provider.publishScores(_report(1, alice, 1));
    }

    function testEpochsMustIncrease() public {
        vm.startPrank(reporter);
        vm.expectRevert(OracleScoreProvider.StaleEpoch.selector);
        provider.publishScores(_report(0, alice, 1));

        provider.publishScores(_report(5, alice, 1));
        vm.expectRevert(OracleScoreProvider.StaleEpoch.selector);
        provider.publishScores(_report(5, alice, 2)); // replay
        vm.expectRevert(OracleScoreProvider.StaleEpoch.selector);
        provider.publishScores(_report(4, alice, 2)); // out of order
        vm.stopPrank();
    }

    function testReportsAreValidated() public {
        vm.startPrank(reporter);
        vm.expectRevert(OracleScoreProvider.LengthMismatch.selector);
        provider.publishScores(abi.encode(uint64(1), new address[](2), new uint256[](1)));

        uint256 tooMany = provider.MAX_BATCH() + 1;
        vm.expectRevert(OracleScoreProvider.BatchTooLarge.selector);
        provider.publishScores(abi.encode(uint64(1), new address[](tooMany), new uint256[](tooMany)));

        bytes memory overScale = _report(1, alice, provider.SCALE() + 1);
        vm.expectRevert(OracleScoreProvider.ScoreTooHigh.selector);
        provider.publishScores(overScale);
        vm.stopPrank();
    }

    function testScoresGoStaleUntilTheNextHeartbeat() public {
        _publish(_report(1, alice, 700_000));
        vm.warp(vm.getBlockTimestamp() + MAX_AGE);
        assertEq(provider.creditScore(alice), 700_000, "fresh up to maxScoreAge");

        vm.warp(vm.getBlockTimestamp() + 1);
        assertFalse(provider.isFresh());
        assertEq(provider.creditScore(alice), 0, "a stalled oracle backs no new loans");

        _publish(_emptyReport(2));
        assertEq(provider.creditScore(alice), 700_000, "a heartbeat restores the last scores");
    }

    // ───────────────────────────── Chainlink CRE ─────────────────────────────

    function testForwarderDeliversReportsFromThePinnedWorkflow() public {
        vm.prank(owner);
        provider.setForwarder(forwarder, workflowOwner, WORKFLOW_ID);

        vm.prank(forwarder);
        provider.onReport(_metadata(WORKFLOW_ID, workflowOwner), _report(1, alice, 900_000));
        assertEq(provider.creditScore(alice), 900_000);
    }

    function testOnReportRejectsOtherSendersAndWorkflows() public {
        bytes memory metadata = _metadata(WORKFLOW_ID, workflowOwner);

        vm.prank(forwarder);
        vm.expectRevert(OracleScoreProvider.NotForwarder.selector); // no forwarder configured yet
        provider.onReport(metadata, _report(1, alice, 1));

        vm.prank(owner);
        provider.setForwarder(forwarder, workflowOwner, WORKFLOW_ID);

        vm.prank(reporter);
        vm.expectRevert(OracleScoreProvider.NotForwarder.selector);
        provider.onReport(metadata, _report(1, alice, 1));

        vm.startPrank(forwarder);
        vm.expectRevert(OracleScoreProvider.UnexpectedWorkflow.selector);
        provider.onReport(_metadata(WORKFLOW_ID, alice), _report(1, alice, 1));
        vm.expectRevert(OracleScoreProvider.UnexpectedWorkflow.selector);
        provider.onReport(_metadata(keccak256("other"), workflowOwner), _report(1, alice, 1));
        vm.expectRevert(OracleScoreProvider.UnexpectedWorkflow.selector);
        provider.onReport(hex"1234", _report(1, alice, 1));
        vm.stopPrank();
    }

    function testUnpinnedForwarderAcceptsAnyWorkflow() public {
        vm.prank(owner);
        provider.setForwarder(forwarder, address(0), bytes32(0));
        vm.prank(forwarder);
        provider.onReport(_metadata(keccak256("any"), alice), _report(1, alice, 1));
        assertEq(provider.creditScore(alice), 1);
    }

    function testSupportsInterfaces() public view {
        assertTrue(provider.supportsInterface(type(IReceiver).interfaceId));
        assertTrue(provider.supportsInterface(type(IERC165).interfaceId));
        assertTrue(provider.supportsInterface(type(IScoreProvider).interfaceId));
        assertFalse(provider.supportsInterface(0xffffffff));
    }

    // ───────────────────────────── admin ─────────────────────────────

    function testAdminIsOwnerOnly() public {
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        provider.setReporter(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        provider.setForwarder(alice, address(0), bytes32(0));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        provider.setMaxScoreAge(2 days);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        provider.setIssuanceLimits(type(uint256).max, type(uint256).max);
        vm.stopPrank();
    }

    // ───────────────────────────── issuance budget ─────────────────────────────

    /// @dev Every score is new unsecured credit, so the sum of scores is capped: a compromised
    ///      workflow can move credit between accounts but not create more than the budget.
    function testReportsCannotIssueBeyondTheBudget() public {
        address[] memory users = new address[](3);
        uint256[] memory values = new uint256[](3);
        (users[0], users[1], users[2]) = (alice, bob, makeAddr("carol"));
        (values[0], values[1], values[2]) = (1_000_000, 1_000_000, 1);

        vm.startPrank(reporter);
        vm.expectRevert(OracleScoreProvider.IssuanceBudgetExceeded.selector);
        provider.publishScores(_report(1, users, values));

        values[2] = 0;
        provider.publishScores(_report(1, users, values));
        assertEq(provider.totalScore(), BUDGET);

        // Reallocating within the budget is allowed; the sum is what is bounded.
        (values[0], values[1], values[2]) = (400_000, 1_000_000, 600_000);
        provider.publishScores(_report(2, users, values));
        assertEq(provider.totalScore(), BUDGET);
        assertEq(provider.creditScore(users[2]), 600_000);
        vm.stopPrank();
    }

    function testOneReportCanRaiseScoresOnlySoFar() public {
        vm.prank(owner);
        provider.setIssuanceLimits(BUDGET, 500_000);

        vm.startPrank(reporter);
        vm.expectRevert(OracleScoreProvider.IssuanceBudgetExceeded.selector);
        provider.publishScores(_report(1, alice, 500_001));
        provider.publishScores(_report(1, alice, 500_000));
        provider.publishScores(_report(2, bob, 500_000));

        // The cap counts every raise in the report, so lowering one score cannot fund a larger raise:
        // this report adds only 100,000 net but raises scores by 600,000.
        address[] memory users = new address[](3);
        uint256[] memory values = new uint256[](3);
        (users[0], users[1], users[2]) = (alice, bob, makeAddr("carol"));
        (values[0], values[1], values[2]) = (0, 1_000_000, 100_000);
        vm.expectRevert(OracleScoreProvider.IssuanceBudgetExceeded.selector);
        provider.publishScores(_report(3, users, values));
        values[2] = 0;
        provider.publishScores(_report(3, users, values));
        vm.stopPrank();
        assertEq(provider.totalScore(), 1_000_000);
    }

    /// @dev After the budget is cut below what is issued, reports that only lower scores still land.
    function testLoweringTheBudgetStillAcceptsReductions() public {
        vm.prank(reporter);
        provider.publishScores(_report(1, alice, 1_000_000));
        vm.prank(owner);
        provider.setIssuanceLimits(500_000, 500_000);

        vm.startPrank(reporter);
        provider.publishScores(_report(2, alice, 800_000));
        assertEq(provider.totalScore(), 800_000);
        vm.expectRevert(OracleScoreProvider.IssuanceBudgetExceeded.selector);
        provider.publishScores(_report(3, bob, 1));
        provider.publishScores(_report(3, alice, 400_000));
        provider.publishScores(_report(4, bob, 100_000));
        vm.stopPrank();
        assertEq(provider.totalScore(), 500_000);
    }

    function testOwnershipTransferNeedsAcceptance() public {
        vm.prank(owner);
        provider.transferOwnership(alice);
        assertEq(provider.owner(), owner, "pending until accepted");

        vm.prank(alice);
        provider.acceptOwnership();
        assertEq(provider.owner(), alice);
    }

    function testMaxScoreAgeIsBounded() public {
        uint256 min = provider.MIN_SCORE_AGE();
        uint256 max = provider.MAX_SCORE_AGE();
        vm.startPrank(owner);
        vm.expectRevert(OracleScoreProvider.InvalidMaxScoreAge.selector);
        provider.setMaxScoreAge(min - 1);
        vm.expectRevert(OracleScoreProvider.InvalidMaxScoreAge.selector);
        provider.setMaxScoreAge(max + 1);
        provider.setMaxScoreAge(max);
        vm.stopPrank();
        assertEq(provider.maxScoreAge(), max);
    }
}
