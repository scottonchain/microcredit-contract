#!/usr/bin/env python3
"""
Verify PageRank Implementation
This script generates NetworkX PageRank results to compare with our Solidity implementation
"""

import networkx as nx
import json

def create_test_graph():
    """Create the same test graph as used in Solidity tests"""
    G = nx.DiGraph()
    
    # Add nodes
    nodes = ["0x1111", "0x2222", "0x3333"]
    G.add_nodes_from(nodes)
    
    # Add edges with weights (scaled to 0-1 range)
    G.add_edge("0x1111", "0x2222", weight=0.8)  # 80% weight
    G.add_edge("0x1111", "0x3333", weight=0.4)  # 40% weight
    
    return G

def compute_networkx_pagerank():
    """Compute PageRank using NetworkX with same parameters as Solidity"""
    G = create_test_graph()
    
    # Compute PageRank with NetworkX defaults (matching Solidity constants)
    pagerank_scores = nx.pagerank(
        G,
        alpha=0.85,  # PAGERANK_ALPHA = 85e4 / 1e6
        max_iter=100,  # PAGERANK_MAX_ITER
        tol=1e-6,  # PAGERANK_TOL / 1e6
        weight='weight'
    )
    
    # Scale scores to match Solidity scale (1e6)
    scaled_scores = {
        node: int(score * 1_000_000) 
        for node, score in pagerank_scores.items()
    }
    
    return scaled_scores

def create_complex_test_graph():
    """Create a more complex test graph for convergence testing"""
    G = nx.DiGraph()
    
    # Add nodes
    nodes = ["0x1111", "0x2222", "0x3333", "0x4444", "0x5555"]
    G.add_nodes_from(nodes)
    
    # Add edges with weights
    edges = [
        ("0x1111", "0x2222", 0.5),
        ("0x2222", "0x3333", 0.3),
        ("0x3333", "0x4444", 0.7),
        ("0x4444", "0x5555", 0.4),
        ("0x5555", "0x1111", 0.6),
    ]
    
    for from_node, to_node, weight in edges:
        G.add_edge(from_node, to_node, weight=weight)
    
    return G

def compute_complex_networkx_pagerank():
    """Compute PageRank on complex graph"""
    G = create_complex_test_graph()
    
    pagerank_scores = nx.pagerank(
        G,
        alpha=0.85,
        max_iter=100,
        tol=1e-6,
        weight='weight'
    )
    
    scaled_scores = {
        node: int(score * 1_000_000) 
        for node, score in pagerank_scores.items()
    }
    
    return scaled_scores

def main():
    """Generate and save expected NetworkX results"""
    print("Computing NetworkX PageRank results...")
    
    # Simple test case
    simple_scores = compute_networkx_pagerank()
    print("Simple test case scores:")
    for node, score in simple_scores.items():
        print(f"  {node}: {score}")
    
    # Complex test case
    complex_scores = compute_complex_networkx_pagerank()
    print("\nComplex test case scores:")
    for node, score in complex_scores.items():
        print(f"  {node}: {score}")
    
    # Save results for comparison
    results = {
        "simple_test": simple_scores,
        "complex_test": complex_scores,
        "parameters": {
            "alpha": 0.85,
            "max_iter": 100,
            "tol": 1e-6,
            "scale": 1_000_000
        }
    }
    
    with open("networkx_pagerank_results.json", "w") as f:
        json.dump(results, f, indent=2)
    
    print(f"\nResults saved to networkx_pagerank_results.json")
    
    # Print key verification points
    print("\nKey verification points:")
    print(f"Simple test - Node2 > Node3: {simple_scores['0x2222'] > simple_scores['0x3333']}")
    print(f"Simple test - Total score: {sum(simple_scores.values())}")
    print(f"Complex test - All scores positive: {all(score > 0 for score in complex_scores.values())}")

if __name__ == "__main__":
    main() 