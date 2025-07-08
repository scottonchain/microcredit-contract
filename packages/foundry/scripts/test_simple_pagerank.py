#!/usr/bin/env python3
"""
Simple PageRank Test
Test basic functionality to verify our implementation works
"""

import networkx as nx

def test_single_node():
    """Test single node case"""
    print("=== Testing Single Node ===")
    
    G = nx.DiGraph()
    G.add_node("0x1111")
    
    pagerank_scores = nx.pagerank(G, alpha=0.85, max_iter=100, tol=1e-6)
    
    print("Single node result:", pagerank_scores)
    score = pagerank_scores["0x1111"]
    print(f"Score: {score:.6f}")
    print(f"Scaled score (100k): {int(score * 100_000):,}")
    
    return score

def test_two_nodes_one_edge():
    """Test two nodes with one edge"""
    print("\n=== Testing Two Nodes, One Edge ===")
    
    G = nx.DiGraph()
    G.add_edge("0x1111", "0x2222", weight=0.5)
    
    pagerank_scores = nx.pagerank(G, alpha=0.85, max_iter=100, tol=1e-6, weight='weight')
    
    print("Two nodes result:")
    for node, score in pagerank_scores.items():
        print(f"  {node}: {score:.6f} ({int(score * 100_000):,})")
    
    total = sum(pagerank_scores.values())
    print(f"Total: {total:.6f} ({int(total * 100_000):,})")
    
    return pagerank_scores

def test_three_nodes():
    """Test three nodes with two edges (our simple test case)"""
    print("\n=== Testing Three Nodes (Simple Test Case) ===")
    
    G = nx.DiGraph()
    G.add_edge("0x1111", "0x2222", weight=0.8)  # 80% weight
    G.add_edge("0x1111", "0x3333", weight=0.4)  # 40% weight
    
    pagerank_scores = nx.pagerank(G, alpha=0.85, max_iter=100, tol=1e-6, weight='weight')
    
    print("Three nodes result:")
    for node, score in pagerank_scores.items():
        print(f"  {node}: {score:.6f} ({int(score * 100_000):,})")
    
    total = sum(pagerank_scores.values())
    print(f"Total: {total:.6f} ({int(total * 100_000):,})")
    
    return pagerank_scores

def main():
    """Main test function"""
    print("🔍 Testing Simple PageRank Cases")
    print("=" * 50)
    
    single_score = test_single_node()
    two_scores = test_two_nodes_one_edge()
    three_scores = test_three_nodes()
    
    print("\n" + "=" * 50)
    print("📋 Expected Solidity Results (scaled to 100,000):")
    print(f"Single node: {int(single_score * 100_000):,}")
    print(f"Two nodes: {int(sum(two_scores.values()) * 100_000):,}")
    print(f"Three nodes: {int(sum(three_scores.values()) * 100_000):,}")
    
    print("\n💡 These should match our Solidity implementation!")

if __name__ == "__main__":
    main() 