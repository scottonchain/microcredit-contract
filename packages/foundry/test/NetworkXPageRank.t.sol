// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import "forge-std/Test.sol";
import "../contracts/NetworkXPageRank.sol";

contract NetworkXPageRankTest is Test {
    using NetworkXPageRank for NetworkXPageRank.Graph;
    
    NetworkXPageRank.Graph graph;
    mapping(address => uint256) personalization;
    mapping(address => uint256) scores;

    function setUp() public {
        console2.log("=== SETTING UP NETWORKX PAGERANK TEST ===");
        
        // Initialize personalization vector
        personalization[address(0x1111)] = 1_000_000; // 1.0
        personalization[address(0x2222)] = 1_000_000; // 1.0
        personalization[address(0x3333)] = 1_000_000; // 1.0
    }

    function testNetworkXPageRankBasic() public {
        console2.log("=== TESTING BASIC NETWORKX PAGERANK ===");
        
        // Initialize graph with nodes
        address[] memory nodes = new address[](3);
        nodes[0] = address(0x1111);
        nodes[1] = address(0x2222);
        nodes[2] = address(0x3333);
        
        graph.initializeGraph(nodes);
        
        // Add edges (attestations)
        graph.addEdge(address(0x1111), address(0x2222), 800_000); // 80% weight
        graph.addEdge(address(0x1111), address(0x3333), 400_000); // 40% weight
        
        console2.log("Graph initialized with:");
        console2.log("  - Nodes:", nodes[0], nodes[1], nodes[2]);
        console2.log("  - Edge 0x1111 -> 0x2222: 800,000 weight");
        console2.log("  - Edge 0x1111 -> 0x3333: 400,000 weight");
        
        // Compute PageRank
        NetworkXPageRank.PageRankResult memory result = graph.pagerank(
            NetworkXPageRank.DEFAULT_ALPHA, // 0.85
            personalization,
            NetworkXPageRank.DEFAULT_MAX_ITER, // 100
            NetworkXPageRank.DEFAULT_TOL, // 1e-06
            scores
        );
        
        console2.log("PageRank results:");
        console2.log("  - Iterations:", result.iterations);
        console2.log("  - Converged:", result.converged);
        
        uint256[] memory scoreArray = NetworkXPageRank.getAllScores(scores, nodes);
        for (uint256 i = 0; i < nodes.length; i++) {
            console2.log("  -", nodes[i], "score:", scoreArray[i]);
        }
        
        // Verify all nodes have scores
        assertTrue(scoreArray[0] > 0, "Node 0x1111 should have positive score");
        assertTrue(scoreArray[1] > 0, "Node 0x2222 should have positive score");
        assertTrue(scoreArray[2] > 0, "Node 0x3333 should have positive score");
        
        console2.log("Basic PageRank test passed\n");
    }

    function testNetworkXPageRankWeightSensitivity() public {
        console2.log("=== TESTING NETWORKX PAGERANK WEIGHT SENSITIVITY ===");
        
        // Test 1: High weight attestation
        console2.log("Test 1: High weight attestation (80%)");
        address[] memory nodes = new address[](2);
        nodes[0] = address(0x1111);
        nodes[1] = address(0x2222);
        
        graph.initializeGraph(nodes);
        graph.addEdge(address(0x1111), address(0x2222), 800_000); // 80% weight
        
        NetworkXPageRank.PageRankResult memory resultHigh = graph.pagerank(
            NetworkXPageRank.DEFAULT_ALPHA,
            personalization,
            NetworkXPageRank.DEFAULT_MAX_ITER,
            NetworkXPageRank.DEFAULT_TOL,
            scores
        );
        
        uint256 scoreHigh = NetworkXPageRank.getScore(scores, address(0x2222));
        console2.log("  - Score with 80% weight:", scoreHigh);
        
        // Test 2: Low weight attestation
        console2.log("Test 2: Low weight attestation (40%)");
        // Clear graph and rebuild
        graph.initializeGraph(nodes);
        graph.addEdge(address(0x1111), address(0x2222), 400_000); // 40% weight
        
        NetworkXPageRank.PageRankResult memory resultLow = graph.pagerank(
            NetworkXPageRank.DEFAULT_ALPHA,
            personalization,
            NetworkXPageRank.DEFAULT_MAX_ITER,
            NetworkXPageRank.DEFAULT_TOL,
            scores
        );
        
        uint256 scoreLow = NetworkXPageRank.getScore(scores, address(0x2222));
        console2.log("  - Score with 40% weight:", scoreLow);
        
        // Compare results
        console2.log("Comparison:");
        console2.log("  - High weight score:", scoreHigh);
        console2.log("  - Low weight score:", scoreLow);
        console2.log("  - Score difference:", scoreHigh - scoreLow);
        console2.log("  - Higher weight produces higher score:", scoreHigh > scoreLow);
        
        // This should pass if our implementation is correct
        assertTrue(scoreHigh > scoreLow, "Higher attestation weight should produce higher score");
        
        console2.log("Weight sensitivity test passed\n");
    }

    function testNetworkXPageRankConvergence() public {
        console2.log("=== TESTING NETWORKX PAGERANK CONVERGENCE ===");
        
        // Create a more complex graph
        address[] memory nodes = new address[](4);
        nodes[0] = address(0x1111);
        nodes[1] = address(0x2222);
        nodes[2] = address(0x3333);
        nodes[3] = address(0x4444);
        
        graph.initializeGraph(nodes);
        
        // Add edges to create a cycle
        graph.addEdge(address(0x1111), address(0x2222), 500_000);
        graph.addEdge(address(0x2222), address(0x3333), 500_000);
        graph.addEdge(address(0x3333), address(0x4444), 500_000);
        graph.addEdge(address(0x4444), address(0x1111), 500_000);
        
        console2.log("Testing convergence with cyclic graph");
        
        NetworkXPageRank.PageRankResult memory result = graph.pagerank(
            NetworkXPageRank.DEFAULT_ALPHA,
            personalization,
            NetworkXPageRank.DEFAULT_MAX_ITER,
            NetworkXPageRank.DEFAULT_TOL,
            scores
        );
        
        console2.log("Convergence results:");
        console2.log("  - Iterations:", result.iterations);
        console2.log("  - Converged:", result.converged);
        
        // Should converge within max iterations
        assertTrue(result.iterations <= NetworkXPageRank.DEFAULT_MAX_ITER, "Should not exceed max iterations");
        
        // All nodes should have positive scores
        uint256[] memory scoreArray = NetworkXPageRank.getAllScores(scores, nodes);
        for (uint256 i = 0; i < nodes.length; i++) {
            assertTrue(scoreArray[i] > 0, "All nodes should have positive scores");
            console2.log("  -", nodes[i], "score:", scoreArray[i]);
        }
        
        console2.log("Convergence test passed\n");
    }

    function testNetworkXPageRankParameters() public {
        console2.log("=== TESTING NETWORKX PAGERANK PARAMETERS ===");
        
        address[] memory nodes = new address[](2);
        nodes[0] = address(0x1111);
        nodes[1] = address(0x2222);
        
        graph.initializeGraph(nodes);
        graph.addEdge(address(0x1111), address(0x2222), 500_000);
        
        // Test different alpha values
        uint256 alpha1 = 70e4; // 0.7
        uint256 alpha2 = 90e4; // 0.9
        
        NetworkXPageRank.PageRankResult memory result1 = graph.pagerank(
            alpha1,
            personalization,
            NetworkXPageRank.DEFAULT_MAX_ITER,
            NetworkXPageRank.DEFAULT_TOL,
            scores
        );
        
        uint256 score1 = NetworkXPageRank.getScore(scores, address(0x2222));
        
        NetworkXPageRank.PageRankResult memory result2 = graph.pagerank(
            alpha2,
            personalization,
            NetworkXPageRank.DEFAULT_MAX_ITER,
            NetworkXPageRank.DEFAULT_TOL,
            scores
        );
        
        uint256 score2 = NetworkXPageRank.getScore(scores, address(0x2222));
        
        console2.log("Parameter sensitivity:");
        console2.log("  - Alpha 0.7 score:", score1);
        console2.log("  - Alpha 0.9 score:", score2);
        console2.log("  - Scores are different:", score1 != score2);
        
        // Different alpha values should produce different scores
        assertTrue(score1 != score2, "Different alpha values should produce different scores");
        
        console2.log("Parameter test passed\n");
    }
} 