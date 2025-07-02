#!/usr/bin/env python3
"""
NetworkX Mock for Testing PageRank Port
This module provides a mock of NetworkX PageRank functionality for testing against our Solidity port
"""

import networkx as nx
import json
from typing import Dict, List, Any

class NetworkXPageRankInterface:
    """NetworkX PageRank interface for testing against Solidity implementation"""
    
    def __init__(self, scale: int = 1_000_000):
        """
        Initialize NetworkX mock
        
        Args:
            scale: Scaling factor for weights (default 1e6 to match Solidity)
        """
        self.scale = scale
        self.graph = nx.DiGraph()
        
    def add_edge(self, from_node: str, to_node: str, weight: int):
        """
        Add weighted edge to graph (mirrors Solidity addEdge)
        
        Args:
            from_node: Source node address
            to_node: Target node address
            weight: Edge weight (0 to scale)
        """
        # Normalize weight to 0-1 range for NetworkX
        normalized_weight = weight / self.scale
        
        # Add edge with weight
        self.graph.add_edge(from_node, to_node, weight=normalized_weight)
        
    def pagerank(self, alpha: float = 0.85, personalization: Dict[str, float] = None, 
                 max_iter: int = 100, tol: float = 1e-6) -> Dict[str, float]:
        """
        Compute PageRank scores (mirrors NetworkX signature)
        
        Args:
            alpha: Damping factor (default 0.85)
            personalization: Personalization vector (optional)
            max_iter: Maximum iterations
            tol: Convergence tolerance
            
        Returns:
            Dictionary mapping node addresses to PageRank scores
        """
        if len(self.graph.nodes()) == 0:
            return {}
            
        # Normalize personalization to 0-1 range if provided
        normalized_personalization = None
        if personalization:
            normalized_personalization = {
                node: weight / self.scale 
                for node, weight in personalization.items()
            }
            
        # Compute PageRank using NetworkX
        pagerank_scores = nx.pagerank(
            self.graph,
            alpha=alpha,
            personalization=normalized_personalization,
            max_iter=max_iter,
            tol=tol,
            weight='weight'
        )
        
        # Scale scores back to match Solidity scale
        scaled_scores = {
            node: int(score * self.scale) 
            for node, score in pagerank_scores.items()
        }
        
        return scaled_scores
        
    def get_graph_info(self) -> Dict[str, Any]:
        """
        Get information about the current graph
        
        Returns:
            Dictionary with graph statistics
        """
        return {
            'nodes': list(self.graph.nodes()),
            'edges': list(self.graph.edges(data=True)),
            'node_count': self.graph.number_of_nodes(),
            'edge_count': self.graph.number_of_edges(),
        }

def create_test_graph() -> NetworkXPageRankInterface:
    """
    Create a test graph for comparison testing
    
    Returns:
        NetworkXPageRankInterface instance with test data
    """
    mock = NetworkXPageRankInterface()
    
    # Add test nodes
    nodes = ["0x1111", "0x2222", "0x3333"]
    
    # Add test edges (attestations)
    mock.add_edge("0x1111", "0x2222", 800_000)  # 80% weight
    mock.add_edge("0x1111", "0x3333", 400_000)  # 40% weight
    
    return mock

def compare_pagerank_implementations(solidity_scores: Dict[str, int], 
                                   networkx_scores: Dict[str, int]) -> Dict[str, Any]:
    """
    Compare Solidity and NetworkX PageRank implementations
    
    Args:
        solidity_scores: Scores from Solidity implementation
        networkx_scores: Scores from NetworkX implementation
        
    Returns:
        Dictionary with comparison results
    """
    comparison = {
        'nodes_match': set(solidity_scores.keys()) == set(networkx_scores.keys()),
        'score_differences': {},
        'max_difference': 0,
        'average_difference': 0,
        'implementations_match': True
    }
    
    if not comparison['nodes_match']:
        comparison['implementations_match'] = False
        return comparison
    
    total_difference = 0
    node_count = 0
    
    for node in solidity_scores.keys():
        solidity_score = solidity_scores[node]
        networkx_score = networkx_scores[node]
        difference = abs(solidity_score - networkx_score)
        
        comparison['score_differences'][node] = {
            'solidity': solidity_score,
            'networkx': networkx_score,
            'difference': difference
        }
        
        total_difference += difference
        node_count += 1
        
        if difference > comparison['max_difference']:
            comparison['max_difference'] = difference
    
    if node_count > 0:
        comparison['average_difference'] = total_difference / node_count
        
        # Consider implementations matching if average difference is small
        # (allowing for floating point precision differences)
        tolerance = 1000  # 0.1% of scale
        comparison['implementations_match'] = comparison['average_difference'] < tolerance
    
    return comparison

def main():
    """Test NetworkX PageRank interface functionality"""
    print("Testing NetworkX PageRank Interface...")
    
    # Create test graph
    interface = create_test_graph()
    
    # Compute PageRank
    scores = interface.pagerank(alpha=0.85, max_iter=100, tol=1e-6)
    
    print("Test results:")
    print(f"Graph info: {interface.get_graph_info()}")
    print(f"PageRank scores: {scores}")
    
    # Test weight sensitivity
    print("\nTesting weight sensitivity...")
    
    # High weight
    interface_high = NetworkXPageRankInterface()
    interface_high.add_edge("0x1111", "0x2222", 800_000)  # 80% weight
    scores_high = interface_high.pagerank()
    
    # Low weight
    interface_low = NetworkXPageRankInterface()
    interface_low.add_edge("0x1111", "0x2222", 400_000)  # 40% weight
    scores_low = interface_low.pagerank()
    
    print(f"Score with 80% weight: {scores_high.get('0x2222', 0)}")
    print(f"Score with 40% weight: {scores_low.get('0x2222', 0)}")
    print(f"Scores are different: {scores_high.get('0x2222', 0) != scores_low.get('0x2222', 0)}")
    
    # Save test data for Solidity comparison
    test_data = {
        'graph': interface.get_graph_info(),
        'scores': scores,
        'weight_sensitivity': {
            'high_weight_score': scores_high.get('0x2222', 0),
            'low_weight_score': scores_low.get('0x2222', 0),
            'scores_different': scores_high.get('0x2222', 0) != scores_low.get('0x2222', 0)
        }
    }
    
    with open("networkx_test_data.json", "w") as f:
        json.dump(test_data, f, indent=2)
    
    print(f"\nTest data saved to networkx_test_data.json")

if __name__ == "__main__":
    main() 