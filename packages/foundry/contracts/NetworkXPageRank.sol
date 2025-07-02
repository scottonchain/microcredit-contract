// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/**
 * @title NetworkXPageRank
 * @dev A Solidity port of NetworkX PageRank algorithm that mirrors the library's behavior
 * NetworkX signature: nx.pagerank(G, alpha=0.85, personalization=None, max_iter=100, tol=1e-06, nstart=None, weight='weight', dangling=None)
 */
library NetworkXPageRank {
    
    uint256 public constant DEFAULT_ALPHA = 85e4; // 0.85 in basis points
    uint256 public constant DEFAULT_MAX_ITER = 100;
    uint256 public constant DEFAULT_TOL = 1; // 1e-06 * 1e6 (scaled)
    uint256 public constant SCALE = 1e6;
    
    struct Graph {
        address[] nodes;
        mapping(address => uint256) nodeIndex; // node -> index in nodes array
        mapping(address => bool) nodeExists; // node -> exists in graph
        mapping(address => mapping(address => uint256)) edges; // from -> to -> weight
        mapping(address => uint256) outDegree; // node -> total outgoing weight
        bool initialized;
    }
    
    struct PageRankResult {
        uint256 iterations;
        bool converged;
    }
    
    /**
     * @dev Initialize graph with nodes
     * @param graph The graph to initialize
     * @param nodes Array of node addresses
     */
    function initializeGraph(Graph storage graph, address[] memory nodes) internal {
        // Allow reinitialization by clearing existing data
        if (graph.initialized) {
            // Clear existing node mappings
            for (uint256 i = 0; i < graph.nodes.length; i++) {
                address oldNode = graph.nodes[i];
                graph.nodeExists[oldNode] = false;
            }
        }
        
        graph.nodes = nodes;
        for (uint256 i = 0; i < nodes.length; i++) {
            graph.nodeIndex[nodes[i]] = i;
            graph.nodeExists[nodes[i]] = true;
        }
        graph.initialized = true;
    }
    
    /**
     * @dev Add weighted edge to graph
     * @param graph The graph to add edge to
     * @param from Source node
     * @param to Target node
     * @param weight Edge weight
     */
    function addEdge(Graph storage graph, address from, address to, uint256 weight) internal {
        require(graph.initialized, "Graph not initialized");
        require(graph.nodeExists[from], "Source node not in graph");
        require(graph.nodeExists[to], "Target node not in graph");
        
        graph.edges[from][to] = weight;
        graph.outDegree[from] += weight;
    }
    
    /**
     * @dev Compute PageRank scores (mirrors NetworkX signature)
     * @param graph The graph to compute PageRank on
     * @param alpha Damping factor (0.85 default)
     * @param personalization Personalization vector (optional)
     * @param maxIter Maximum iterations
     * @param tol Convergence tolerance
     * @param scores Storage mapping to store the computed scores
     * @return result PageRank result with metadata
     */
    function pagerank(
        Graph storage graph,
        uint256 alpha,
        mapping(address => uint256) storage personalization,
        uint256 maxIter,
        uint256 tol,
        mapping(address => uint256) storage scores
    ) internal returns (PageRankResult memory result) {
        require(graph.initialized, "Graph not initialized");
        require(alpha <= SCALE, "Alpha must be <= 1.0");
        require(maxIter > 0, "Max iterations must be > 0");
        
        // Initialize scores (like NetworkX nstart=None)
        for (uint256 i = 0; i < graph.nodes.length; i++) {
            address node = graph.nodes[i];
            scores[node] = personalization[node] > 0 ? personalization[node] : SCALE;
        }
        
        // Run PageRank iterations (mirrors NetworkX algorithm)
        uint256 iteration = 0;
        bool converged = false;
        
        while (iteration < maxIter && !converged) {
            converged = _pagerankIteration(graph, scores, alpha, personalization, tol);
            iteration++;
        }
        
        result.iterations = iteration;
        result.converged = converged;
    }
    
    /**
     * @dev Single PageRank iteration (internal)
     */
    function _pagerankIteration(
        Graph storage graph,
        mapping(address => uint256) storage scores,
        uint256 alpha,
        mapping(address => uint256) storage personalization,
        uint256 tol
    ) internal returns (bool converged) {
        uint256 totalDelta = 0;
        
        // Compute new scores for each node
        for (uint256 i = 0; i < graph.nodes.length; i++) {
            address node = graph.nodes[i];
            uint256 oldScore = scores[node];
            
            // Compute incoming score (like NetworkX)
            uint256 incomingScore = 0;
            for (uint256 j = 0; j < graph.nodes.length; j++) {
                address source = graph.nodes[j];
                if (source == node) continue;
                
                uint256 edgeWeight = graph.edges[source][node];
                if (edgeWeight > 0) {
                    uint256 sourceScore = scores[source];
                    uint256 outDegree = graph.outDegree[source];
                    
                    if (outDegree > 0) {
                        // Standard PageRank: incomingScore += (sourceScore * edgeWeight) / outDegree
                        incomingScore += (sourceScore * edgeWeight) / outDegree;
                    }
                }
            }
            
            // Apply PageRank formula: score = (1-alpha)*personalization + alpha*incomingScore
            uint256 personalizationValue = personalization[node] > 0 ? personalization[node] : SCALE;
            uint256 alphaPart = (alpha * incomingScore) / SCALE;
            uint256 personalizationPart = ((SCALE - alpha) * personalizationValue) / SCALE;
            
            uint256 newScore = personalizationPart + alphaPart;
            scores[node] = newScore;
            
            // Track convergence
            uint256 delta = oldScore > newScore ? oldScore - newScore : newScore - oldScore;
            totalDelta += delta;
        }
        
        return totalDelta < tol;
    }
    
    /**
     * @dev Get PageRank score for a specific node
     */
    function getScore(mapping(address => uint256) storage scores, address node) internal view returns (uint256) {
        return scores[node];
    }
    
    /**
     * @dev Get all scores as arrays (for easier testing)
     */
    function getAllScores(mapping(address => uint256) storage scores, address[] memory nodes) internal view returns (uint256[] memory) {
        uint256[] memory resultScores = new uint256[](nodes.length);
        for (uint256 i = 0; i < nodes.length; i++) {
            resultScores[i] = scores[nodes[i]];
        }
        return resultScores;
    }
} 