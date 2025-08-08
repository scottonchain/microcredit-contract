#!/usr/bin/env python3
"""
PageRank Oracle for Smart Contract Integration

This script is used to generate the PageRank baseline results for the Solidity test
`PageRankVerification.t.sol` in `packages/foundry/test`. The expected values in the Solidity
test are derived from the output of this script (using NetworkX). If you change the PageRank
algorithm or want to update the expected results, run this script with the appropriate attestation
data to regenerate the baseline values. See the README_PageRank.md for more details.
"""

import networkx as nx
import json
import sys
import os
from typing import Dict, List, Any
from pagerank_calculator import PageRankCalculator

class PageRankOracle:
    def __init__(self, contract_address: str = None):
        """
        Initialize PageRank oracle
        
        Args:
            contract_address: Address of the deployed contract
        """
        self.contract_address = contract_address
        self.calculator = PageRankCalculator()
        
    def compute_pagerank_from_contract_data(self, attestation_data: Dict[str, Any]) -> Dict[str, int]:
        """
        Compute PageRank from contract attestation data
        
        Args:
            attestation_data: Dictionary with borrowers, attesters, and weights arrays
            
        Returns:
            Dictionary mapping addresses to PageRank scores
        """
        borrowers = attestation_data.get('borrowers', [])
        attesters_arrays = attestation_data.get('attesters', [])
        weights_arrays = attestation_data.get('weights', [])
        
        # Clear previous data
        self.calculator = PageRankCalculator()
        
        # Add all attestations to the graph
        for i, borrower in enumerate(borrowers):
            if i < len(attesters_arrays) and i < len(weights_arrays):
                attesters = attesters_arrays[i]
                weights = weights_arrays[i]
                
                for j, attester in enumerate(attesters):
                    if j < len(weights):
                        weight = weights[j]
                        self.calculator.add_attestation(attester, borrower, weight)
        
        # Compute PageRank scores
        scores = self.calculator.compute_pagerank()
        return scores
        
    def update_contract_scores(self, scores: Dict[str, int], contract_interface=None):
        """
        Update credit scores in the smart contract
        This would integrate with web3 to make actual contract calls
        
        Args:
            scores: Dictionary of address -> score mappings
            contract_interface: Web3 contract interface (for future implementation)
        """
        # This is a placeholder for web3 integration
        # In a real implementation, this would make actual contract calls
        print("Would update contract with scores:", scores)
        
        # For now, just save to a file that can be used for manual updates
        with open("pagerank_scores.json", "w") as f:
            json.dump(scores, f, indent=2)
        print("Scores saved to pagerank_scores.json")
        
    def process_and_update(self, attestation_data: Dict[str, Any]) -> Dict[str, int]:
        """
        Complete workflow: compute PageRank and update contract
        
        Args:
            attestation_data: Contract attestation data
            
        Returns:
            Computed PageRank scores
        """
        print("Computing PageRank from attestation data...")
        scores = self.compute_pagerank_from_contract_data(attestation_data)
        
        print("Updating contract scores...")
        self.update_contract_scores(scores)
        
        return scores

def main():
    """Main function for oracle operation"""
    if len(sys.argv) < 2:
        print("Usage: python pagerank_oracle.py <command> [args...]")
        print("Commands:")
        print("  compute <attestations.json> - Compute PageRank from JSON file")
        print("  test - Run test with sample data")
        return
        
    command = sys.argv[1]
    oracle = PageRankOracle()
    
    if command == "test":
        # Test with sample attestation data
        print("Running oracle test...")
        
        test_data = {
            "borrowers": ["0x2222", "0x3333"],
            "attesters": [
                ["0x1111", "0x4444"],  # Attesters for borrower 0x2222
                ["0x1111"]             # Attesters for borrower 0x3333
            ],
            "weights": [
                [100_000, 200_000],    # Weights for borrower 0x2222
                [300_000]              # Weights for borrower 0x3333
            ]
        }
        
        scores = oracle.process_and_update(test_data)
        print(f"Test completed. Scores: {scores}")
        
    elif command == "compute":
        if len(sys.argv) < 3:
            print("Error: Please provide attestations JSON file")
            return
            
        json_file = sys.argv[2]
        try:
            with open(json_file, 'r') as f:
                attestation_data = json.load(f)
                
            scores = oracle.process_and_update(attestation_data)
            print(f"Oracle processing completed. Updated {len(scores)} addresses.")
            
        except FileNotFoundError:
            print(f"Error: File {json_file} not found")
        except json.JSONDecodeError:
            print(f"Error: Invalid JSON in {json_file}")
    else:
        print(f"Unknown command: {command}")

if __name__ == "__main__":
    main() 