#!/usr/bin/env python3
"""
Compare Solidity NetworkX Port with Actual NetworkX Library
This script runs both implementations and compares their results
"""

import json
import subprocess
import sys
from typing import Dict, List, Any
from networkx_interface import NetworkXPageRankInterface, compare_pagerank_implementations

def run_solidity_test(test_name: str) -> Dict[str, Any]:
    """
    Run a Solidity test and extract results
    
    Args:
        test_name: Name of the test to run
        
    Returns:
        Dictionary with test results
    """
    try:
        # Run the Solidity test
        cmd = f"cd packages/foundry && forge test --match-test {test_name} -vv"
        result = subprocess.run(cmd, shell=True, capture_output=True, text=True)
        
        if result.returncode != 0:
            print(f"Solidity test failed: {result.stderr}")
            return {}
        
        # Parse the output to extract scores
        # This is a simplified parser - in practice you'd want more robust parsing
        output = result.stdout
        scores = {}
        
        # Look for score lines in the output
        for line in output.split('\n'):
            if 'score:' in line and '0x' in line:
                parts = line.split()
                for i, part in enumerate(parts):
                    if part.startswith('0x') and i + 2 < len(parts) and parts[i + 1] == 'score:':
                        address = part
                        score = int(parts[i + 2])
                        scores[address] = score
        
        return {
            'success': True,
            'scores': scores,
            'output': output
        }
        
    except Exception as e:
        print(f"Error running Solidity test: {e}")
        return {'success': False, 'error': str(e)}

def run_networkx_test(test_name: str) -> Dict[str, Any]:
    """
    Run the equivalent NetworkX test
    
    Args:
        test_name: Name of the test to run
        
    Returns:
        Dictionary with test results
    """
    try:
        # Create test data based on test name
        if test_name == "testNetworkXPageRankWeightSensitivity":
            # Test weight sensitivity
            interface_high = NetworkXPageRankInterface()
            interface_high.add_edge("0x1111", "0x2222", 800_000)  # 80% weight
            scores_high = interface_high.pagerank()
            
            interface_low = NetworkXPageRankInterface()
            interface_low.add_edge("0x1111", "0x2222", 400_000)  # 40% weight
            scores_low = interface_low.pagerank()
            
            return {
                'success': True,
                'scores_high': scores_high,
                'scores_low': scores_low,
                'weight_sensitivity': {
                    'high_weight_score': scores_high.get('0x2222', 0),
                    'low_weight_score': scores_low.get('0x2222', 0),
                    'scores_different': scores_high.get('0x2222', 0) != scores_low.get('0x2222', 0)
                }
            }
            
        elif test_name == "testNetworkXPageRankBasic":
            # Test basic PageRank
            interface = NetworkXPageRankInterface()
            interface.add_edge("0x1111", "0x2222", 800_000)
            interface.add_edge("0x1111", "0x3333", 400_000)
            scores = interface.pagerank()
            
            return {
                'success': True,
                'scores': scores
            }
            
        else:
            return {'success': False, 'error': f'Unknown test: {test_name}'}
            
    except Exception as e:
        print(f"Error running NetworkX test: {e}")
        return {'success': False, 'error': str(e)}

def compare_test_results(test_name: str):
    """
    Compare Solidity and NetworkX test results
    
    Args:
        test_name: Name of the test to compare
    """
    print(f"=== COMPARING {test_name} ===")
    
    # Run Solidity test
    print("Running Solidity test...")
    solidity_result = run_solidity_test(test_name)
    
    # Run NetworkX test
    print("Running NetworkX test...")
    networkx_result = run_networkx_test(test_name)
    
    if not solidity_result.get('success', False):
        print(f"Solidity test failed: {solidity_result.get('error', 'Unknown error')}")
        return
    
    if not networkx_result.get('success', False):
        print(f"NetworkX test failed: {networkx_result.get('error', 'Unknown error')}")
        return
    
    # Compare results based on test type
    if test_name == "testNetworkXPageRankWeightSensitivity":
        solidity_high = solidity_result.get('scores', {}).get('0x2222', 0)
        solidity_low = solidity_result.get('scores', {}).get('0x2222', 0)  # This would need parsing
        
        networkx_high = networkx_result['weight_sensitivity']['high_weight_score']
        networkx_low = networkx_result['weight_sensitivity']['low_weight_score']
        
        print(f"Weight Sensitivity Comparison:")
        print(f"  Solidity - High weight score: {solidity_high}")
        print(f"  NetworkX - High weight score: {networkx_high}")
        print(f"  Solidity - Low weight score: {solidity_low}")
        print(f"  NetworkX - Low weight score: {networkx_low}")
        
        # Compare implementations
        comparison = compare_pagerank_implementations(
            {'0x2222': solidity_high},
            {'0x2222': networkx_high}
        )
        
        print(f"  Implementations match: {comparison['implementations_match']}")
        print(f"  Average difference: {comparison['average_difference']}")
        
    elif test_name == "testNetworkXPageRankBasic":
        solidity_scores = solidity_result.get('scores', {})
        networkx_scores = networkx_result.get('scores', {})
        
        print(f"Basic PageRank Comparison:")
        print(f"  Solidity scores: {solidity_scores}")
        print(f"  NetworkX scores: {networkx_scores}")
        
        # Compare implementations
        comparison = compare_pagerank_implementations(solidity_scores, networkx_scores)
        
        print(f"  Implementations match: {comparison['implementations_match']}")
        print(f"  Average difference: {comparison['average_difference']}")
        print(f"  Max difference: {comparison['max_difference']}")
    
    print()

def main():
    """Main comparison function"""
    print("NETWORKX PAGERANK IMPLEMENTATION COMPARISON")
    print("=" * 50)
    
    # Run NetworkX interface first to generate test data
    print("Generating NetworkX test data...")
    subprocess.run("cd packages/foundry/scripts && python networkx_interface.py", shell=True)
    
    # Compare different tests
    tests = [
        "testNetworkXPageRankBasic",
        "testNetworkXPageRankWeightSensitivity"
    ]
    
    for test_name in tests:
        compare_test_results(test_name)
    
    print("Comparison completed!")

if __name__ == "__main__":
    main() 