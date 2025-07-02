#!/usr/bin/env python3
"""
PageRank Calculator for Decentralized Microcredit System
Uses NetworkX to compute PageRank scores based on attestation weights
"""

import networkx as nx
import json
import sys
from typing import Dict, List, Tuple, Any

class PageRankCalculator:
    def __init__(self, scale: int = 1_000_000):
        """
        Initialize PageRank calculator
        
        Args:
            scale: Scaling factor for weights (default 1e6 to match Solidity)
        """
        self.scale = scale
        self.graph = nx.DiGraph()
        
    def add_attestation(self, attester: str, borrower: str, weight: int):
        """
        Add an attestation to the graph
        
        Args:
            attester: Address of the attester
            borrower: Address of the borrower
            weight: Attestation weight (0 to scale)
        """
        # Normalize weight to 0-1 range
        normalized_weight = weight / self.scale
        
        # Add edge with weight
        self.graph.add_edge(attester, borrower, weight=normalized_weight)
        
    def compute_pagerank(self, damping_factor: float = 0.7, max_iter: int = 100, tol: float = 1e-6) -> Dict[str, float]:
        """
        Compute PageRank scores for all nodes
        
        Args:
            damping_factor: PageRank damping factor (default 0.7)
            max_iter: Maximum iterations
            tol: Convergence tolerance
            
        Returns:
            Dictionary mapping node addresses to PageRank scores
        """
        if len(self.graph.nodes()) == 0:
            return {}
            
        # Compute PageRank using NetworkX
        pagerank_scores = nx.pagerank(
            self.graph,
            alpha=damping_factor,
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

def main():
    """Example usage and testing"""
    if len(sys.argv) < 2:
        print("Usage: python pagerank_calculator.py <command> [args...]")
        print("Commands:")
        print("  test - Run test calculations")
        print("  compute <attestations.json> - Compute PageRank from JSON file")
        return
        
    command = sys.argv[1]
    calculator = PageRankCalculator()
    
    if command == "test":
        # Test with simple attestation scenario
        print("Running test calculations...")
        
        # Add test attestations
        calculator.add_attestation("0x1111", "0x2222", 100_000)  # 10% weight
        calculator.add_attestation("0x1111", "0x2222", 900_000)  # 90% weight (should replace)
        
        # Compute PageRank
        scores = calculator.compute_pagerank()
        
        print("Test results:")
        print(f"Graph info: {calculator.get_graph_info()}")
        print(f"PageRank scores: {scores}")
        
        # Verify that higher attestation weight produces different scores
        calculator2 = PageRankCalculator()
        calculator2.add_attestation("0x1111", "0x2222", 100_000)  # 10% weight
        scores_low = calculator2.compute_pagerank()
        
        calculator3 = PageRankCalculator()
        calculator3.add_attestation("0x1111", "0x2222", 900_000)  # 90% weight
        scores_high = calculator3.compute_pagerank()
        
        print(f"Score with 10% weight: {scores_low.get('0x2222', 0)}")
        print(f"Score with 90% weight: {scores_high.get('0x2222', 0)}")
        print(f"Scores are different: {scores_low.get('0x2222', 0) != scores_high.get('0x2222', 0)}")
        
    elif command == "compute":
        if len(sys.argv) < 3:
            print("Error: Please provide attestations JSON file")
            return
            
        json_file = sys.argv[2]
        try:
            with open(json_file, 'r') as f:
                attestations = json.load(f)
                
            # Add attestations from JSON
            for attestation in attestations:
                calculator.add_attestation(
                    attestation['attester'],
                    attestation['borrower'],
                    attestation['weight']
                )
                
            # Compute PageRank
            scores = calculator.compute_pagerank()
            
            # Output results
            print(json.dumps({
                'graph_info': calculator.get_graph_info(),
                'pagerank_scores': scores
            }, indent=2))
            
        except FileNotFoundError:
            print(f"Error: File {json_file} not found")
        except json.JSONDecodeError:
            print(f"Error: Invalid JSON in {json_file}")
        except KeyError as e:
            print(f"Error: Missing required field {e} in attestation data")
    else:
        print(f"Unknown command: {command}")

if __name__ == "__main__":
    main() 