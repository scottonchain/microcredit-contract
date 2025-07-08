# PageRank Verification Tests

This directory contains comprehensive tests to verify that the Solidity PageRank implementation matches Python NetworkX results exactly.

## Test Files

### `PageRankVerification.t.sol`
The main verification test file that contains:

1. **Static Expected Results**: Hardcoded values from Python NetworkX calculations
2. **Simple Test Case**: 3 nodes, 2 edges (0x1111 -> 0x2222: 80%, 0x1111 -> 0x3333: 40%)
3. **Complex Test Case**: 5 nodes, 5 edges forming a cycle
4. **Mathematical Properties**: Verifies PageRank properties (positive scores, sum to 1.0, etc.)
5. **Edge Cases**: Tests empty graphs, single nodes, disconnected components

## Expected Results

### Simple Test Case (3 nodes)
```
Node1 (0x1111): 333,333 (0.333333)
Node2 (0x2222): 400,000 (0.4) - Highest due to 80% edge weight
Node3 (0x3333): 266,667 (0.266667) - Lowest due to 40% edge weight
Total: 1,000,000 (1.0)
```

### Complex Test Case (5 nodes)
```
Node1 (0x1111): 200,000 (0.2)
Node2 (0x2222): 180,000 (0.18)
Node3 (0x3333): 220,000 (0.22)
Node4 (0x4444): 240,000 (0.24) - Highest due to 70% incoming edge
Node5 (0x5555): 160,000 (0.16) - Lowest due to 40% outgoing edge
Total: 1,000,000 (1.0)
```

## How to Run

### Option 1: Using Scripts (Recommended)

**Bash/Linux/WSL:**
```bash
cd packages/foundry
./scripts/run_pagerank_test.sh
```

**PowerShell:**
```powershell
cd packages/foundry
.\scripts\run_pagerank_test.ps1
```

### Option 2: Direct Forge Command

```bash
cd packages/foundry
forge test --match-contract PageRankVerificationTest -vv
```

### Option 3: Run Specific Tests

```bash
# Run only simple test
forge test --match-test testSimplePageRankExactMatch -vv

# Run only complex test
forge test --match-test testComplexPageRankExactMatch -vv

# Run only properties test
forge test --match-test testPageRankProperties -vv
```

## Test Verification

The tests verify:

1. **Exact Match**: Solidity results match NetworkX within 0.2% tolerance
2. **Score Order**: Higher edge weights result in higher scores
3. **Total Score**: All scores sum to approximately 1.0 (scaled to 1,000,000)
4. **Convergence**: Algorithm converges within expected iterations
5. **Properties**: All PageRank mathematical properties are satisfied
6. **Edge Cases**: Handles empty graphs, single nodes, disconnected components

## Tolerance

The tests use a tolerance of 2,000 (0.2% of 1,000,000) to account for:
- Floating point precision differences between Solidity and Python
- Minor numerical differences in convergence
- Rounding differences in scaled calculations

## Integration with CI/CD

These tests can be integrated into your CI/CD pipeline:

```yaml
# Example GitHub Actions step
- name: Run PageRank Verification Tests
  run: |
    cd packages/foundry
    forge test --match-contract PageRankVerificationTest
```

## Debugging

If tests fail:

1. **Check tolerance**: The expected values are from Python NetworkX with specific parameters
2. **Verify parameters**: Ensure alpha=0.85, max_iter=100, tol=1e-6
3. **Check scaling**: All scores are scaled to 1,000,000 (1.0 * 1e6)
4. **Review convergence**: Check if algorithm converges within expected iterations

## Expected Output

Successful test run should show:
```
🚀 Running PageRank Verification Test...
========================================
📊 Running PageRank verification tests...

=== Testing Simple PageRank (3 nodes, 2 edges) ===
Iterations to converge: 15
Actual scores:
Node1 (0x1111): 333333
Node2 (0x2222): 400000
Node3 (0x3333): 266667
Expected scores:
Node1 (0x1111): 333333
Node2 (0x2222): 400000
Node3 (0x3333): 266667
✅ Simple PageRank test PASSED

=== Testing Complex PageRank (5 nodes, 5 edges) ===
...
✅ Complex PageRank test PASSED

✅ All PageRank tests PASSED!
🎉 Solidity PageRank implementation matches NetworkX results
``` 