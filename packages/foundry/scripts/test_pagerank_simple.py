#!/usr/bin/env python3
"""
Simple PageRank Test Script
This script tests the PageRank implementation and shows expected vs actual results
"""

import networkx as nx

def test_simple_pagerank():
    """Test the simple 3-node case"""
    print("=== Simple PageRank Test (3 nodes, 2 edges) ===")
    
    # Create the same graph as Solidity test
    G = nx.DiGraph()
    G.add_edge("0x1111", "0x2222", weight=0.8)  # 80% weight
    G.add_edge("0x1111", "0x3333", weight=0.4)  # 40% weight
    
    # Compute PageRank with NetworkX
    pagerank_scores = nx.pagerank(
        G,
        alpha=0.85,
        max_iter=100,
        tol=1e-6,
        weight='weight'
    )
    
    # Scale to match Solidity (1e6)
    scaled_scores = {
        node: int(score * 1_000_000) 
        for node, score in pagerank_scores.items()
    }
    
    print("NetworkX Results (scaled to 1e6):")
    for node, score in scaled_scores.items():
        print(f"  {node}: {score}")
    
    print(f"Total: {sum(scaled_scores.values())}")
    
    # Expected results from test
    expected = {
        "0x1111": 333333,
        "0x2222": 400000,
        "0x3333": 266667
    }
    
    print("\nExpected Results:")
    for node, score in expected.items():
        print(f"  {node}: {score}")
    
    print(f"Total: {sum(expected.values())}")
    
    # Check if results match
    tolerance = 2000  # 0.2% tolerance
    all_match = True
    
    print("\nVerification:")
    for node in scaled_scores:
        actual = scaled_scores[node]
        expected_val = expected[node]
        diff = abs(actual - expected_val)
        percent_diff = (diff / expected_val) * 100
        
        status = "✅" if diff <= tolerance else "❌"
        print(f"  {node}: {status} Actual={actual}, Expected={expected_val}, Diff={diff} ({percent_diff:.2f}%)")
        
        if diff > tolerance:
            all_match = False
    
    print(f"\nOverall Result: {'✅ PASS' if all_match else '❌ FAIL'}")
    return all_match

def test_complex_pagerank():
    """Test the complex 5-node case"""
    print("\n=== Complex PageRank Test (5 nodes, 5 edges) ===")
    
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
    
    # Compute PageRank with NetworkX
    pagerank_scores = nx.pagerank(
        G,
        alpha=0.85,
        max_iter=100,
        tol=1e-6,
        weight='weight'
    )
    
    # Scale to match Solidity (1e6)
    scaled_scores = {
        node: int(score * 1_000_000) 
        for node, score in pagerank_scores.items()
    }
    
    print("NetworkX Results (scaled to 1e6):")
    for node, score in scaled_scores.items():
        print(f"  {node}: {score}")
    
    print(f"Total: {sum(scaled_scores.values())}")
    
    # Expected results from test
    expected = {
        "0x1111": 200000,
        "0x2222": 180000,
        "0x3333": 220000,
        "0x4444": 240000,
        "0x5555": 160000
    }
    
    print("\nExpected Results:")
    for node, score in expected.items():
        print(f"  {node}: {score}")
    
    print(f"Total: {sum(expected.values())}")
    
    # Check if results match
    tolerance = 2000  # 0.2% tolerance
    all_match = True
    
    print("\nVerification:")
    for node in scaled_scores:
        actual = scaled_scores[node]
        expected_val = expected[node]
        diff = abs(actual - expected_val)
        percent_diff = (diff / expected_val) * 100
        
        status = "✅" if diff <= tolerance else "❌"
        print(f"  {node}: {status} Actual={actual}, Expected={expected_val}, Diff={diff} ({percent_diff:.2f}%)")
        
        if diff > tolerance:
            all_match = False
    
    print(f"\nOverall Result: {'✅ PASS' if all_match else '❌ FAIL'}")
    return all_match

def main():
    """Run all tests"""
    print("🚀 PageRank Verification Tests")
    print("=" * 50)
    
    # Test simple case
    simple_pass = test_simple_pagerank()
    
    # Test complex case
    complex_pass = test_complex_pagerank()
    
    print("\n" + "=" * 50)
    print("📊 Final Results:")
    print(f"Simple Test: {'✅ PASS' if simple_pass else '❌ FAIL'}")
    print(f"Complex Test: {'✅ PASS' if complex_pass else '❌ FAIL'}")
    
    if simple_pass and complex_pass:
        print("\n🎉 All tests PASSED! NetworkX results are correct.")
        print("If Solidity tests are failing, the issue is in the Solidity implementation.")
    else:
        print("\n⚠️  Some tests FAILED! The expected values may need adjustment.")
    
    print("\n💡 To run Solidity tests when forge is available:")
    print("cd packages/foundry")
    print("forge test --match-contract PageRankVerificationTest -vv")

if __name__ == "__main__":
    main() 