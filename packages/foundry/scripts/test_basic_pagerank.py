#!/usr/bin/env python3
"""
Basic PageRank Test
Test simple cases to verify our implementation works
"""

import networkx as nx

def test_single_node():
    """Test single node case"""
    print("=== Testing Single Node ===")
    
    G = nx.DiGraph()
    G.add_node("0x1111")
    
    pagerank_scores = nx.pagerank(G, alpha=0.85, max_iter=100, tol=1e-6)
    
    print("Single node result:", pagerank_scores)
    print("Score:", pagerank_scores["0x1111"])
    print("Scaled score:", int(pagerank_scores["0x1111"] * 1_000_000))
    
    return pagerank_scores

def test_two_nodes():
    """Test two nodes with one edge"""
    print("\n=== Testing Two Nodes ===")
    
    G = nx.DiGraph()
    G.add_edge("0x1111", "0x2222", weight=0.5)
    
    pagerank_scores = nx.pagerank(G, alpha=0.85, max_iter=100, tol=1e-6, weight='weight')
    
    print("Two nodes result:", pagerank_scores)
    for node, score in pagerank_scores.items():
        print(f"{node}: {score:.6f} ({int(score * 1_000_000):,})")
    
    total = sum(pagerank_scores.values())
    print(f"Total: {total:.6f} ({int(total * 1_000_000):,})")
    
    return pagerank_scores

def main():
    """Main test function"""
    print("🔍 Testing Basic PageRank Cases")
    print("=" * 40)
    
    single_scores = test_single_node()
    two_scores = test_two_nodes()
    
    print("\n" + "=" * 40)
    print("📋 Expected Solidity Results:")
    print("Single node: ~1,000,000")
    print("Two nodes: should sum to ~1,000,000")

if __name__ == "__main__":
    main() 