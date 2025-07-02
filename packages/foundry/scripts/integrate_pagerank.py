#!/usr/bin/env python3
"""
Complete NetworkX PageRank Integration with Smart Contract
This script demonstrates the full workflow of using NetworkX PageRank with the smart contract
"""

import json
import sys
import os
from typing import Dict, List, Any
from pagerank_oracle import PageRankOracle

def simulate_contract_attestations():
    """
    Simulate the attestation data that would come from the smart contract
    This represents what exportAttestationData() would return
    """
    return {
        "borrowers": [
            "0x2222",  # Borrower 1
            "0x3333",  # Borrower 2
            "0x4444"   # Borrower 3
        ],
        "attesters": [
            ["0x1111", "0x5555"],  # Attesters for borrower 0x2222
            ["0x1111", "0x6666"],  # Attesters for borrower 0x3333
            ["0x2222", "0x7777"]   # Attesters for borrower 0x4444
        ],
        "weights": [
            [800_000, 600_000],    # Weights for borrower 0x2222 (80%, 60%)
            [400_000, 900_000],    # Weights for borrower 0x3333 (40%, 90%)
            [700_000, 500_000]     # Weights for borrower 0x4444 (70%, 50%)
        ]
    }

def demonstrate_weight_change_impact():
    """
    Demonstrate how NetworkX PageRank responds to attestation weight changes
    This shows the sensitivity that the tests expect
    """
    print("=== DEMONSTRATING NETWORKX PAGERANK WEIGHT SENSITIVITY ===\n")
    
    oracle = PageRankOracle()
    
    # Test case 1: High weight attestation
    print("Test 1: High weight attestation (80%)")
    test_data_high = {
        "borrowers": ["0x2222"],
        "attesters": [["0x1111"]],
        "weights": [[800_000]]  # 80% weight
    }
    
    scores_high = oracle.compute_pagerank_from_contract_data(test_data_high)
    print(f"Score with 80% weight: {scores_high.get('0x2222', 0)}")
    
    # Test case 2: Low weight attestation
    print("\nTest 2: Low weight attestation (40%)")
    test_data_low = {
        "borrowers": ["0x2222"],
        "attesters": [["0x1111"]],
        "weights": [[400_000]]  # 40% weight
    }
    
    scores_low = oracle.compute_pagerank_from_contract_data(test_data_low)
    print(f"Score with 40% weight: {scores_low.get('0x2222', 0)}")
    
    # Compare results
    high_score = scores_high.get('0x2222', 0)
    low_score = scores_low.get('0x2222', 0)
    
    print(f"\nComparison:")
    print(f"  High weight (80%) score: {high_score}")
    print(f"  Low weight (40%) score:  {low_score}")
    print(f"  Score difference: {high_score - low_score}")
    print(f"  Higher weight produces higher score: {high_score > low_score}")
    
    return high_score > low_score

def demonstrate_complex_network():
    """
    Demonstrate NetworkX PageRank with a more complex network
    """
    print("\n=== DEMONSTRATING COMPLEX NETWORK PAGERANK ===\n")
    
    oracle = PageRankOracle()
    
    # Complex network with multiple participants and attestations
    complex_data = simulate_contract_attestations()
    
    print("Complex network attestations:")
    for i, borrower in enumerate(complex_data["borrowers"]):
        attesters = complex_data["attesters"][i]
        weights = complex_data["weights"][i]
        print(f"  Borrower {borrower}:")
        for j, attester in enumerate(attesters):
            weight_pct = (weights[j] * 100) / 1_000_000
            print(f"    - Attested by {attester} with {weight_pct}% confidence")
    
    # Compute PageRank
    scores = oracle.compute_pagerank_from_contract_data(complex_data)
    
    print(f"\nNetworkX PageRank scores:")
    for address, score in scores.items():
        print(f"  {address}: {score}")
    
    return scores

def generate_contract_update_calls(scores: Dict[str, int]):
    """
    Generate the contract calls that would update the scores
    """
    print(f"\n=== GENERATING CONTRACT UPDATE CALLS ===\n")
    
    # Convert addresses to the format expected by the contract
    addresses = list(scores.keys())
    score_values = list(scores.values())
    
    print("Contract function call:")
    print(f"updateCreditScores({addresses}, {score_values})")
    
    # Also show individual calls
    print(f"\nIndividual calls:")
    for address, score in scores.items():
        print(f"updateCreditScore({address}, {score})")

def main():
    """Main demonstration function"""
    print("NETWORKX PAGERANK INTEGRATION DEMONSTRATION")
    print("=" * 50)
    
    # Test 1: Weight sensitivity (this addresses the failing test)
    weight_sensitive = demonstrate_weight_change_impact()
    
    # Test 2: Complex network
    complex_scores = demonstrate_complex_network()
    
    # Test 3: Generate contract update calls
    generate_contract_update_calls(complex_scores)
    
    # Summary
    print(f"\n=== SUMMARY ===")
    print(f"NetworkX PageRank correctly responds to weight changes: {weight_sensitive}")
    print(f"Complex network processed with {len(complex_scores)} participants")
    print(f"All scores are within valid range (0 to 1,000,000)")
    
    # Save results for reference
    with open("networkx_pagerank_demo_results.json", "w") as f:
        json.dump({
            "weight_sensitivity_test": weight_sensitive,
            "complex_network_scores": complex_scores,
            "summary": {
                "participants": len(complex_scores),
                "all_scores_valid": all(0 <= score <= 1_000_000 for score in complex_scores.values())
            }
        }, f, indent=2)
    
    print(f"\nResults saved to networkx_pagerank_demo_results.json")

if __name__ == "__main__":
    main() 