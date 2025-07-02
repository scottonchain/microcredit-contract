#!/usr/bin/env python3
"""
Smart Contract Integration for NetworkX PageRank
Integrates with the DecentralizedMicrocredit contract to compute PageRank scores
"""

import json
import sys
import os
from typing import Dict, List, Any
from pagerank_calculator import PageRankCalculator

class ContractIntegration:
    def __init__(self, contract_address: str = None):
        """
        Initialize contract integration
        
        Args:
            contract_address: Address of the deployed contract (for future web3 integration)
        """
        self.contract_address = contract_address
        self.calculator = PageRankCalculator()
        
    def process_attestation_data(self, attestation_data: Dict[str, Any]) -> Dict[str, int]:
        """
        Process attestation data from the smart contract and compute PageRank
        
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
        
    def export_scores_to_json(self, scores: Dict[str, int], filename: str = "pagerank_scores.json"):
        """
        Export PageRank scores to JSON file
        
        Args:
            scores: Dictionary of address -> score mappings
            filename: Output filename
        """
        with open(filename, 'w') as f:
            json.dump(scores, f, indent=2)
        print(f"PageRank scores exported to {filename}")
        
    def generate_update_calldata(self, scores: Dict[str, int]) -> List[str]:
        """
        Generate calldata for updating credit scores in the smart contract
        This would be used with a web3 integration to update scores on-chain
        
        Args:
            scores: Dictionary of address -> score mappings
            
        Returns:
            List of function call data strings
        """
        # This is a placeholder for future web3 integration
        # In a real implementation, this would generate actual contract calls
        calldata = []
        
        for address, score in scores.items():
            # Example: updateCreditScore(address user, uint256 newScore)
            calldata.append(f"updateCreditScore({address}, {score})")
            
        return calldata

def main():
    """Example usage and testing"""
    if len(sys.argv) < 2:
        print("Usage: python contract_integration.py <command> [args...]")
        print("Commands:")
        print("  test - Run integration test")
        print("  process <attestations.json> - Process attestation data from JSON")
        return
        
    command = sys.argv[1]
    integration = ContractIntegration()
    
    if command == "test":
        # Test with sample attestation data
        print("Running integration test...")
        
        # Sample attestation data (format matching contract export)
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
        
        # Process the data
        scores = integration.process_attestation_data(test_data)
        
        print("Test results:")
        print(f"Graph info: {integration.calculator.get_graph_info()}")
        print(f"PageRank scores: {scores}")
        
        # Export scores
        integration.export_scores_to_json(scores, "test_scores.json")
        
        # Generate update calldata
        calldata = integration.generate_update_calldata(scores)
        print(f"Update calldata: {calldata}")
        
    elif command == "process":
        if len(sys.argv) < 3:
            print("Error: Please provide attestations JSON file")
            return
            
        json_file = sys.argv[2]
        try:
            with open(json_file, 'r') as f:
                attestation_data = json.load(f)
                
            # Process the data
            scores = integration.process_attestation_data(attestation_data)
            
            # Export results
            output_file = f"pagerank_scores_{os.path.splitext(os.path.basename(json_file))[0]}.json"
            integration.export_scores_to_json(scores, output_file)
            
            print(f"Processed {len(scores)} addresses")
            print(f"Results saved to {output_file}")
            
        except FileNotFoundError:
            print(f"Error: File {json_file} not found")
        except json.JSONDecodeError:
            print(f"Error: Invalid JSON in {json_file}")
    else:
        print(f"Unknown command: {command}")

if __name__ == "__main__":
    main() 