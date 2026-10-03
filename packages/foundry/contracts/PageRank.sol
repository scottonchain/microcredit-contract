// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

/**
 * @title PageRank
 * @notice Personalized, weighted PageRank over a directed attestation graph, computed on-chain.
 * @dev Fixed-point port of `networkx.pagerank(G, alpha=0.85, max_iter=100, weight="weight")`;
 *      scores are scaled so that 1.0 == PR_SCALE. Inheriting contracts supply each node's
 *      teleportation weight through {_personalizationWeight}.
 *
 *      Gas grows with O(n^2) per iteration, so this is only suitable for demo-sized graphs.
 *      In production the computation is meant to move off-chain to an oracle.
 */
abstract contract PageRank {
    /// @dev 1.0 in PageRank fixed point.
    uint256 internal constant PR_SCALE = 100_000;
    /// @dev Damping factor 0.85.
    uint256 internal constant PR_ALPHA = 85_000;
    /// @dev Per-node L1 convergence threshold (100 / PR_SCALE = 1e-3; integer math cannot
    ///      resolve NetworkX's 1e-6).
    uint256 internal constant PR_TOL = 100;
    uint256 internal constant PR_MAX_ITER = 100;

    address[] private pagerankNodes;
    mapping(address => bool) private pagerankNodeExists;
    mapping(address => mapping(address => uint256)) private pagerankEdges;
    mapping(address => uint256) private pagerankOutDegree;
    /// @notice Latest PageRank score per node, scaled to PR_SCALE.
    mapping(address => uint256) public pagerankScores;
    mapping(address => mapping(address => uint256)) private pagerankStochasticEdges;
    /// @dev Whether the last run had any node with positive personalization weight. Without one
    ///      the vector falls back to uniform (as NetworkX does), which ranks every node alike.
    bool internal pagerankPersonalized;

    /// @dev Raw (unnormalized) teleportation weight for `node`.
    function _personalizationWeight(address node) internal view virtual returns (uint256);

    // ───────────────────────────── views ─────────────────────────────

    function getPageRankScore(address node) external view returns (uint256) {
        return pagerankScores[node];
    }

    function getMaxPageRankScore() public view returns (uint256 maxScore) {
        for (uint256 i = 0; i < pagerankNodes.length; i++) {
            uint256 score = pagerankScores[pagerankNodes[i]];
            if (score > maxScore) {
                maxScore = score;
            }
        }
    }

    function getAllPageRankScores() external view returns (address[] memory nodes, uint256[] memory scores) {
        nodes = pagerankNodes;
        scores = new uint256[](nodes.length);
        for (uint256 i = 0; i < nodes.length; i++) {
            scores[i] = pagerankScores[nodes[i]];
        }
    }

    function _pagerankNodes() internal view returns (address[] storage) {
        return pagerankNodes;
    }

    // ───────────────────────────── graph mutation ─────────────────────────────

    function _addPagerankNode(address node) internal {
        if (!pagerankNodeExists[node]) {
            pagerankNodes.push(node);
            pagerankNodeExists[node] = true;
        }
    }

    /// @dev Sets (or replaces) the weight of the edge `from -> to`.
    function _setPagerankEdge(address from, address to, uint256 weight) internal {
        pagerankOutDegree[from] = pagerankOutDegree[from] - pagerankEdges[from][to] + weight;
        pagerankEdges[from][to] = weight;
    }

    /// @dev Removes every node, edge and score.
    function _clearPageRankState() internal {
        for (uint256 i = 0; i < pagerankNodes.length; i++) {
            address node = pagerankNodes[i];
            pagerankNodeExists[node] = false;
            pagerankScores[node] = 0;
            pagerankOutDegree[node] = 0;

            for (uint256 j = 0; j < pagerankNodes.length; j++) {
                address target = pagerankNodes[j];
                pagerankEdges[node][target] = 0;
                pagerankStochasticEdges[node][target] = 0;
            }
        }
        delete pagerankNodes;
        pagerankPersonalized = false;
    }

    // ───────────────────────────── computation ─────────────────────────────

    function _computePageRank() internal returns (uint256 iterations) {
        uint256 n = pagerankNodes.length;
        if (n == 0) return 0;

        uint256[] memory personalization;
        (personalization, pagerankPersonalized) = _buildPersonalizationVector();

        // Start from the personalization vector rather than NetworkX's uniform start: the fixed
        // point is the same, and nodes that no trust reaches stay at exactly zero instead of
        // decaying towards it until the coarse tolerance stops the iteration.
        for (uint256 i = 0; i < n; i++) {
            pagerankScores[pagerankNodes[i]] = personalization[i];
        }

        _createStochasticGraph();

        bool converged = false;
        while (iterations < PR_MAX_ITER && !converged) {
            converged = _pagerankIteration(personalization);
            iterations++;
        }
    }

    /// @dev Normalizes each node's outgoing edge weights by its out-degree.
    function _createStochasticGraph() private {
        uint256 n = pagerankNodes.length;
        for (uint256 i = 0; i < n; i++) {
            address node = pagerankNodes[i];
            uint256 outDegree = pagerankOutDegree[node];

            for (uint256 j = 0; j < n; j++) {
                address target = pagerankNodes[j];
                uint256 weight = pagerankEdges[node][target];
                pagerankStochasticEdges[node][target] =
                    (outDegree > 0 && weight > 0) ? (weight * PR_SCALE) / outDegree : 0;
            }
        }
    }

    /**
     * @dev Each node's weight is {_personalizationWeight}, normalized so the vector sums to
     *      PR_SCALE. Falls back to uniform when every weight is zero (`personalized` false).
     */
    function _buildPersonalizationVector() private view returns (uint256[] memory vector, bool personalized) {
        uint256 n = pagerankNodes.length;
        vector = new uint256[](n);

        uint256 totalWeight = 0;
        for (uint256 i = 0; i < n; i++) {
            vector[i] = _personalizationWeight(pagerankNodes[i]);
            totalWeight += vector[i];
        }

        personalized = totalWeight > 0;
        for (uint256 i = 0; i < n; i++) {
            vector[i] = personalized ? (vector[i] * PR_SCALE) / totalWeight : PR_SCALE / n;
        }
    }

    /// @dev One power-iteration step. Returns true once the L1 change is below PR_TOL * n.
    function _pagerankIteration(uint256[] memory personalization) private returns (bool converged) {
        uint256 n = pagerankNodes.length;

        // Snapshot previous scores and total mass held by dangling nodes (no out-edges).
        uint256[] memory oldScores = new uint256[](n);
        uint256 danglingSum = 0;
        for (uint256 i = 0; i < n; i++) {
            address node = pagerankNodes[i];
            oldScores[i] = pagerankScores[node];
            if (pagerankOutDegree[node] == 0) {
                danglingSum += oldScores[i];
            }
        }

        uint256 totalDelta = 0;
        for (uint256 i = 0; i < n; i++) {
            address node = pagerankNodes[i];

            // NetworkX: x[nbr] += alpha * xlast[n] * wt
            uint256 incoming = 0;
            for (uint256 j = 0; j < n; j++) {
                uint256 weight = pagerankStochasticEdges[pagerankNodes[j]][node];
                if (weight > 0) {
                    incoming += (PR_ALPHA * oldScores[j] * weight) / (PR_SCALE * PR_SCALE);
                }
            }

            // Dangling mass is redistributed according to the personalization vector.
            uint256 dangling = (PR_ALPHA * danglingSum * personalization[i]) / (PR_SCALE * PR_SCALE);
            // Teleportation: (1 - alpha) * p[node]
            uint256 teleport = ((PR_SCALE - PR_ALPHA) * personalization[i]) / PR_SCALE;

            uint256 newScore = incoming + dangling + teleport;
            pagerankScores[node] = newScore;
            totalDelta += oldScores[i] > newScore ? oldScores[i] - newScore : newScore - oldScores[i];
        }

        return totalDelta < PR_TOL * n;
    }
}
