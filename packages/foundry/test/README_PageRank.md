# PageRank Verification

`PageRankVerification.t.sol` checks the on-chain PageRank (`contracts/PageRank.sol`) against
NetworkX. Baselines come from `scripts-py/pagerank_calculator.py`, which calls
`networkx.pagerank(alpha=0.85, max_iter=100, tol=1e-6)`, rescaled to `PR_SCALE = 100,000`.
Every node must land within `TOLERANCE = 100` (0.1%) of its baseline; the integer
implementation is currently within 20.

| Case   | Graph                                                    | Expected scores (x 100,000) |
| ------ | -------------------------------------------------------- | --------------------------- |
| Simple | 0x1111 -> 0x2222 (80%), 0x1111 -> 0x3333 (40%)           | 25,974 / 40,692 / 33,333    |
| Cycle  | 0x1111 -> 0x2222 -> 0x3333 -> 0x4444 -> 0x5555 -> 0x1111 | 20,000 each                 |

The suite also covers empty and disconnected graphs, re-attestation replacing an edge weight,
owner/oracle-only clearing, and the credit-score curve
`score = SCALE * x / (x + 100)` with `x = 1000 * PR / max(PR)`.

## Running

```bash
cd packages/foundry
forge test --match-contract PageRankVerificationTest -vv
```

## Regenerating baselines

If the algorithm changes, regenerate the expected values and update the constants in the test.

```bash
cd packages/foundry/scripts-py
pip install -r requirements.txt
cat > simple.json <<'EOF'
[{"attester": "0x1111", "borrower": "0x2222", "weight": 800000},
 {"attester": "0x1111", "borrower": "0x3333", "weight": 400000}]
EOF
python pagerank_calculator.py compute simple.json
```

`pagerank_calculator.py` prints scores scaled to 1,000,000; divide by 10 for `PR_SCALE`.
Weights use the contract's `SCALE` (1,000,000 = 100%).
