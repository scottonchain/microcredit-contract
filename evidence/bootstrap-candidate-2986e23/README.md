# Bootstrap candidate: exact-head evidence

Code head: `2986e232062afbf324b406d4fcb53991742cd083`. This directory was produced by `scripts/candidate_evidence.sh` from a clean checkout of that head and
added in a commit that changes no code. Nothing here is a public-chain receipt: tests ran on a local EVM with synthetic
time; fork runs and rehearsals ran on local Anvil forks of Base Sepolia with Circle's USDC, every fork pinned to Base Sepolia
block 47864920 (hash `0x7d061a18d64d196c55742feb2afa35d8cfa443db98eb55f74b4cc542c7e68e96`).

## Toolchain

```
forge Version: 1.5.1-v1.5.1
Commit SHA: b0a9dd9ceda36f63e2326ce530c10e6916f4b8a2
Build Timestamp: 2025-12-19T14:07:55.455914129Z (1766153275)
Build Profile: maxperf
solc_version = "0.8.33"
via_ir = true
optimizer = true
optimizer_runs = 200
anvil Version: 1.5.1-v1.5.1
Commit SHA: b0a9dd9ceda36f63e2326ce530c10e6916f4b8a2
Build Timestamp: 2025-12-19T14:07:55.455914129Z (1766153275)
Build Profile: maxperf
```

## Contracts (from `logs/verifier.json`, deployed to a fork by `DeployBootstrapCandidate.s.sol`)

| Contract | Runtime bytes | EIP-170 margin | Masked-runtime sha256, metadata removed | ABI sha256 | Strict match |
| --- | ---: | ---: | --- | --- | --- |
| pool | 24,439 | 137 | `e1afd70e0e1e3300b9a5071663cb0350292680621f06c3bd3a21f4fa769c1739` | `35755c5dbc61b3af72763452975fee8148a24a08864f7a606959b578d93132df` | True |
| lens | 3,287 | 21,289 | `9c23acfe162615347a0838fe5be587a34b758f25ee31b4fb1856630051d16ff9` | `cea757c169ae1215d1da938b796d35334c46c1ed025257d342adc13ac715f337` | True |
| router | 18,105 | 6,471 | `51c9218c5e3978dd7540d0c0ea6e8b179ba46240e875ec752b5f2753b64a728c` | `97d70fa6f17785c292a0e2819f13e1df58d89930a6f494063ac7c9b160fd86ae` | True |

Compare hosts on the size, the metadata-free hash and the ABI hash: the compiler's metadata trailer depends on the checkout path, so
the full masked hash in `logs/verifier.json` (`masked_sha256_*`) differs between two checkouts of the same source. Full `forge build --sizes` is in `logs/build-sizes.txt`. Every contract matched the compiled artifact strictly (immutables
zeroed on both sides) and every wiring check held, including `lens.credit == pool` read through the lens's own getter.
`scripts/candidate_evidence_gate.py` refused to complete this packet unless every run exited 0 and its summary line passed.

## Tests

- Local suite (`logs/forge-test-local.txt`): Ran 30 test suites in 16.58s (55.24s CPU time): 329 tests passed, 0 failed, 14 skipped (343 total tests)
- Router fork suites against Circle's USDC (`logs/forge-test-fork-routers.txt`): Ran 2 test suites in 35.99s (71.98s CPU time): 78 tests passed, 0 failed, 0 skipped (78 total tests)
- Script tests (`logs/python-tests.txt`): verifier, rehearsal typed-data drift, two-hop check.
- Deep invariant campaigns (512 runs of depth 150, both router suites) are recorded in `logs/invariant-deep.txt`.
- Mutation check (`scripts/candidate_mutants.py`, one planted bug at a time, each must fail the suite): `logs/mutants.txt`.
- Rehearsals with `cast` on a fresh fork: `logs/rehearsal-normal.txt`, `logs/rehearsal-with-default.txt`.

Local Forge here is 1.5.1; CI uses 1.8.5, which counts each invariant campaign as one test, so counts differ by tool version.

## Reproduce

```
git checkout 2986e232062afbf324b406d4fcb53991742cd083
scripts/candidate_evidence.sh   # needs forge, anvil, cast, python3 and https://sepolia.base.org
```
