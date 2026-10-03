// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import { DecentralizedMicrocredit } from "../contracts/DecentralizedMicrocredit.sol";
import { MicrocreditTestBase } from "./utils/MicrocreditTestBase.sol";

/**
 * @dev Checks the on-chain PageRank against NetworkX baselines produced by
 *      scripts-py/pagerank_calculator.py (alpha=0.85, max_iter=100, tol=1e-6), scaled to
 *      PR_SCALE = 100,000. If the algorithm changes, regenerate the baselines and update the
 *      constants below. See README_PageRank.md.
 */
contract PageRankVerificationTest is MicrocreditTestBase {
    uint256 internal constant PR_SCALE = 100_000;
    /// @dev Allowed absolute error per node (0.1% of PR_SCALE); integer math lands within ~20.
    uint256 internal constant TOLERANCE = 100;

    address internal constant NODE1 = address(0x1111);
    address internal constant NODE2 = address(0x2222);
    address internal constant NODE3 = address(0x3333);
    address internal constant NODE4 = address(0x4444);
    address internal constant NODE5 = address(0x5555);

    // 3 nodes: 0x1111 -> 0x2222 (80%), 0x1111 -> 0x3333 (40%)
    uint256 internal constant SIMPLE_NODE1_SCORE = 25974; // 0.259741
    uint256 internal constant SIMPLE_NODE2_SCORE = 40692; // 0.406926
    uint256 internal constant SIMPLE_NODE3_SCORE = 33333; // 0.333333

    // 5-node cycle with differing weights: uniform, since each node has one out-edge
    uint256 internal constant CYCLE_NODE_SCORE = 20000; // 0.2

    function setUp() public {
        _deploy(500, 2000, 10_000e6);
        _relaxSybilGuards();
    }

    function _attest(address from, address to, uint256 weight) internal {
        vm.prank(from);
        credit.recordAttestation(to, weight);
    }

    function _clear() internal {
        vm.prank(owner);
        credit.clearPageRankState();
    }

    function _totalScore() internal view returns (uint256 total) {
        (, uint256[] memory scores) = credit.getAllPageRankScores();
        for (uint256 i = 0; i < scores.length; i++) {
            total += scores[i];
        }
    }

    function testSimpleGraphMatchesNetworkX() public {
        _attest(NODE1, NODE2, 800_000);
        _attest(NODE1, NODE3, 400_000);

        uint256 iterations = credit.computePageRank();
        assertGt(iterations, 0);
        assertLe(iterations, 100);

        assertApproxEqAbs(credit.getPageRankScore(NODE1), SIMPLE_NODE1_SCORE, TOLERANCE, "node1");
        assertApproxEqAbs(credit.getPageRankScore(NODE2), SIMPLE_NODE2_SCORE, TOLERANCE, "node2");
        assertApproxEqAbs(credit.getPageRankScore(NODE3), SIMPLE_NODE3_SCORE, TOLERANCE, "node3");
        assertApproxEqAbs(_totalScore(), PR_SCALE, TOLERANCE, "scores sum to 1");
    }

    function testCycleMatchesNetworkX() public {
        _attest(NODE1, NODE2, 500_000);
        _attest(NODE2, NODE3, 300_000);
        _attest(NODE3, NODE4, 700_000);
        _attest(NODE4, NODE5, 400_000);
        _attest(NODE5, NODE1, 600_000);

        uint256 iterations = credit.computePageRank();
        assertGt(iterations, 0);
        assertLe(iterations, 100);

        address[5] memory nodes = [NODE1, NODE2, NODE3, NODE4, NODE5];
        for (uint256 i = 0; i < nodes.length; i++) {
            assertApproxEqAbs(credit.getPageRankScore(nodes[i]), CYCLE_NODE_SCORE, TOLERANCE);
        }
        assertApproxEqAbs(_totalScore(), PR_SCALE, TOLERANCE);
    }

    function testHeavierEdgeEarnsHigherScore() public {
        _attest(NODE1, NODE2, 800_000);
        _attest(NODE1, NODE3, 400_000);
        credit.computePageRank();

        assertGt(credit.getPageRankScore(NODE2), credit.getPageRankScore(NODE3));
        (, uint256[] memory scores) = credit.getAllPageRankScores();
        for (uint256 i = 0; i < scores.length; i++) {
            assertGt(scores[i], 0, "every node keeps teleportation mass");
        }
    }

    function testEmptyGraphRunsNoIterations() public {
        assertEq(credit.computePageRank(), 0);
    }

    function testSingleEdgeAndDisconnectedGraphs() public {
        _attest(NODE1, NODE2, 100_000);
        assertGt(credit.computePageRank(), 0);
        assertGt(credit.getPageRankScore(NODE1), 0);
        assertGt(credit.getPageRankScore(NODE2), 0);
        assertApproxEqAbs(_totalScore(), PR_SCALE, TOLERANCE);

        _clear();
        (address[] memory nodes,) = credit.getAllPageRankScores();
        assertEq(nodes.length, 0, "graph cleared");

        _attest(NODE2, NODE3, 500_000);
        _attest(NODE4, NODE5, 500_000);
        assertGt(credit.computePageRank(), 0);
        assertApproxEqAbs(_totalScore(), PR_SCALE, TOLERANCE);
    }

    function testReattestingReplacesEdgeWeight() public {
        _attest(NODE1, NODE2, 800_000);
        _attest(NODE1, NODE3, 300_000);
        _attest(NODE1, NODE2, 300_000); // lower the first edge
        uint256 updated2 = credit.getPageRankScore(NODE2);
        uint256 updated3 = credit.getPageRankScore(NODE3);
        assertApproxEqAbs(_totalScore(), PR_SCALE, TOLERANCE, "no mass leaks from stale out-degree");

        _clear();
        _attest(NODE1, NODE2, 300_000);
        _attest(NODE1, NODE3, 300_000);
        assertEq(updated2, credit.getPageRankScore(NODE2), "same as building the graph fresh");
        assertEq(updated3, credit.getPageRankScore(NODE3));
    }

    function testClearPageRankStateIsAdminOnly() public {
        _attest(NODE1, NODE2, 800_000);

        vm.prank(makeAddr("stranger"));
        vm.expectRevert(DecentralizedMicrocredit.NotOwnerOrOracle.selector);
        credit.clearPageRankState();

        vm.prank(oracle);
        credit.clearPageRankState();
        vm.prank(owner);
        credit.clearPageRankState();
    }

    function testCreditScoreCurve() public {
        vm.prank(oracle);
        credit.markKYCVerified(NODE1); // the only trust anchor
        _attest(NODE1, NODE2, 800_000);
        _attest(NODE1, NODE3, 400_000);

        uint256 maxPr = credit.getMaxPageRankScore();
        assertEq(maxPr, credit.getPageRankScore(NODE1), "the anchor holds the most trust");
        // The top node maps to x = 1000 -> SCALE * 1000 / 1100.
        assertEq(credit.getCreditScore(NODE1), (SCALE * 1000) / 1100);

        address[2] memory vouched = [NODE2, NODE3];
        for (uint256 i = 0; i < vouched.length; i++) {
            uint256 x = (credit.getPageRankScore(vouched[i]) * 1000) / maxPr;
            assertEq(credit.getCreditScore(vouched[i]), (SCALE * x) / (x + 100));
        }
        assertGt(credit.getCreditScore(NODE2), credit.getCreditScore(NODE3));
        assertEq(credit.getCreditScore(makeAddr("unknown")), 0);
    }

    /// @dev Without an anchor PageRank still matches NetworkX (uniform personalization), but a
    ///      uniform ranking is no evidence of trust, so it yields no credit score.
    function testUnanchoredGraphGivesNoCreditScore() public {
        _attest(NODE1, NODE2, 800_000);
        assertGt(credit.getPageRankScore(NODE2), 0);
        assertEq(credit.getCreditScore(NODE1), 0);
        assertEq(credit.getCreditScore(NODE2), 0);
    }
}
