#!/usr/bin/env python3
"""
Test PageRank Match
Verify that our expected values match NetworkX exactly
"""

import networkx as nx

def test_simple_pagerank():
    """Test the simple 3-node case"""
    print("=== Testing Simple PageRank (3 nodes, 2 edges) ===")
    
    # Create the same graph as Solidity test
    G = nx.DiGraph()
    G.add_edge("0x1111", "0x2222", weight=0.8)  # 80% weight
    G.add_edge("0x1111", "0x3333", weight=0.4)  # 40% weight
    
    print("Graph edges:")
    for edge in G.edges(data=True):
        print(f"  {edge[0]} -> {edge[1]} (weight: {edge[2]['weight']})")
    
    print("\nOut-degrees:")
    for node in G.nodes():
        out_degree = G.out_degree(node, weight='weight')
        print(f"  {node}: {out_degree}")
    
    # Compute PageRank with NetworkX (exact same parameters as Solidity)
    pagerank_scores = nx.pagerank(
        G,
        alpha=0.85,
        max_iter=100,
        tol=1e-6,
        weight='weight'
    )
    
    print("\nNetworkX PageRank Results:")
    for node, score in pagerank_scores.items():
        scaled_score = int(score * 1_000_000)
        print(f"  {node}: {score:.6f} ({scaled_score:,})")
    
    total = sum(pagerank_scores.values())
    print(f"Total: {total:.6f} ({int(total * 1_000_000):,})")
    
    # Expected values from our test
    expected = {
        "0x1111": 259740,
        "0x2222": 406926,
        "0x3333": 333333
    }
    
    print("\nVerification:")
    for node, expected_score in expected.items():
        actual_score = int(pagerank_scores[node] * 1_000_000)
        match = actual_score == expected_score
        print(f"  {node}: {actual_score:,} == {expected_score:,} ✓" if match else f"  {node}: {actual_score:,} != {expected_score:,} ✗")
    
    return pagerank_scores

def test_complex_pagerank():
    """Test the complex 5-node case"""
    print("\n=== Testing Complex PageRank (5 nodes, 5 edges) ===")
    
    # Create the same graph as Solidity test
    G = nx.DiGraph()
    edges = [
        ("0x1111", "0x2222", 0.5),
        ("0x2222", "0x3333", 0.3),
        ("0x3333", "0x4444", 0.7),
        ("0x4444", "0x5555", 0.4),
        ("0x5555", "0x1111", 0.6),
    ]
    
    for from_node, to_node, weight in edges:
        G.add_edge(from_node, to_node, weight=weight)
    
    print("Graph edges:")
    for edge in G.edges(data=True):
        print(f"  {edge[0]} -> {edge[1]} (weight: {edge[2]['weight']})")
    
    print("\nOut-degrees:")
    for node in G.nodes():
        out_degree = G.out_degree(node, weight='weight')
        print(f"  {node}: {out_degree}")
    
    # Compute PageRank with NetworkX
    pagerank_scores = nx.pagerank(
        G,
        alpha=0.85,
        max_iter=100,
        tol=1e-6,
        weight='weight'
    )
    
    print("\nNetworkX PageRank Results:")
    for node, score in pagerank_scores.items():
        scaled_score = int(score * 1_000_000)
        print(f"  {node}: {score:.6f} ({scaled_score:,})")
    
    total = sum(pagerank_scores.values())
    print(f"Total: {total:.6f} ({int(total * 1_000_000):,})")
    
    # Expected values from our test
    expected = {
        "0x1111": 200000,
        "0x2222": 200000,
        "0x3333": 200000,
        "0x4444": 200000,
        "0x5555": 200000
    }
    
    print("\nVerification:")
    for node, expected_score in expected.items():
        actual_score = int(pagerank_scores[node] * 1_000_000)
        match = actual_score == expected_score
        print(f"  {node}: {actual_score:,} == {expected_score:,} ✓" if match else f"  {node}: {actual_score:,} != {expected_score:,} ✗")
    
    return pagerank_scores

def main():
    """Main test function"""
    print("🔍 Testing PageRank Implementation Match")
    print("=" * 60)
    
    # Test simple case
    simple_scores = test_simple_pagerank()
    
    # Test complex case
    complex_scores = test_complex_pagerank()
    
    print("\n" + "=" * 60)
    print("📋 Summary:")
    print("If all verifications show ✓, our Solidity implementation should match NetworkX")
    print("If any show ✗, we need to adjust our expected values or implementation")

if __name__ == "__main__":
    main() 