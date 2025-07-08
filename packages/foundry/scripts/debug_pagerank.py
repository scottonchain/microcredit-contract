#!/usr/bin/env python3
"""
Debug PageRank Implementation
This script helps understand exactly how NetworkX PageRank works
"""

import networkx as nx

def debug_simple_pagerank():
    """Debug the simple 3-node case step by step"""
    print("=== Debugging Simple PageRank (3 nodes, 2 edges) ===")
    
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
        print(f"  {node}: {score:.6f} ({int(score * 1_000_000):,})")
    
    total = sum(pagerank_scores.values())
    print(f"Total: {total:.6f} ({int(total * 1_000_000):,})")
    
    # Check if scores sum to 1.0
    print(f"Sum to 1.0: {abs(total - 1.0) < 1e-10}")
    
    return pagerank_scores

def debug_complex_pagerank():
    """Debug the complex 5-node case"""
    print("\n=== Debugging Complex PageRank (5 nodes, 5 edges) ===")
    
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
        print(f"  {node}: {score:.6f} ({int(score * 1_000_000):,})")
    
    total = sum(pagerank_scores.values())
    print(f"Total: {total:.6f} ({int(total * 1_000_000):,})")
    
    return pagerank_scores

def main():
    """Main debug function"""
    print("🔍 Debugging NetworkX PageRank Implementation")
    print("=" * 60)
    
    # Debug simple case
    simple_scores = debug_simple_pagerank()
    
    # Debug complex case
    complex_scores = debug_complex_pagerank()
    
    print("\n" + "=" * 60)
    print("📋 Key Insights:")
    print("1. NetworkX uses weighted out-degrees for normalization")
    print("2. Scores always sum to exactly 1.0")
    print("3. Convergence is based on L1 norm of changes")
    print("4. Personalization defaults to uniform distribution")
    
    print("\n💡 Solidity Implementation Should:")
    print("1. Use weighted out-degrees: sum of edge weights from each node")
    print("2. Normalize incoming scores by out-degree")
    print("3. Use uniform personalization: 1.0 / numberOfNodes")
    print("4. Check convergence: total_delta < tol * numberOfNodes")

if __name__ == "__main__":
    main() 