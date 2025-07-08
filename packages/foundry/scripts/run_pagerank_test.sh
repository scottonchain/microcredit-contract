#!/bin/bash

# PageRank Verification Test Runner
# This script runs the PageRank verification test to ensure Solidity implementation matches NetworkX

echo "🚀 Running PageRank Verification Test..."
echo "========================================"

# Check if forge is available
if ! command -v forge &> /dev/null; then
    echo "❌ Error: forge command not found"
    echo "Please install Foundry first:"
    echo "curl -L https://foundry.paradigm.xyz | bash"
    echo "source ~/.bashrc"
    echo "foundryup"
    exit 1
fi

# Navigate to foundry directory
cd "$(dirname "$0")/.."

# Run the PageRank verification test
echo "📊 Running PageRank verification tests..."
forge test --match-contract PageRankVerificationTest -vv

# Check exit code
if [ $? -eq 0 ]; then
    echo ""
    echo "✅ All PageRank tests PASSED!"
    echo "🎉 Solidity PageRank implementation matches NetworkX results"
    echo ""
    echo "Test Summary:"
    echo "- Simple PageRank (3 nodes): ✅ Exact match with NetworkX"
    echo "- Complex PageRank (5 nodes): ✅ Exact match with NetworkX"
    echo "- PageRank properties: ✅ All mathematical properties verified"
    echo "- Edge cases: ✅ Handled correctly"
    exit 0
else
    echo ""
    echo "❌ PageRank tests FAILED!"
    echo "🔍 Check the output above for details"
    echo "💡 The Solidity implementation may not match NetworkX exactly"
    exit 1
fi 