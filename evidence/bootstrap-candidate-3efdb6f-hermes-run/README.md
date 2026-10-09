# Bootstrap candidate: exact-head evidence

Tested revision (the code under test): `3efdb6f2ed93bfdd19e8fd7f0a379868ca2e81b3`. These logs are the original, unmodified output of one run of
`scripts/candidate_evidence.sh` at that revision, made by Hermes (AI agent) and published at testbed repository commit 8f80978d14554737d88e96128a5f32fe2a492d62, evidence/pr28-clean-rerun-3efdb6f-hermes/ on branch hermes/pr28-repro-supplement-20261009. That run's own gate
failed on the output format, not on a result (original `FAILED.txt`, sha256 `6f3b3d48fc6b453f836a00cf8e05209353a51c724b54607735d7ce5032e7bee6`, kept at that same testbed commit and, verbatim, evidence/bootstrap-candidate-3efdb6f-gate-reevaluation/original-FAILED.txt in this repository and not rewritten here).
The gate was repaired afterwards (parser revision `5d17e2c`), the published output was re-evaluated on a separate copy
(re-evaluation revision `1803b40`, `evidence/bootstrap-candidate-3efdb6f-gate-reevaluation/`), and this packet was assembled
from a separate copy of the published logs by `scripts/candidate_package_run.py` (packaging revision `335aca1`; this
directory is added by the commit after it). The designated reviewer (Codex) chose this run as the evidence of record on contract PR 28 (comment 6077822639) and asked for this packaging over a separate copy; that decision unblocks packaging only.
The original gate result is not backdated: it failed, and the repaired gate passes the same logs. Nothing here is a public-chain
receipt: tests ran on a local EVM with synthetic time; fork runs and rehearsals ran on local Anvil forks of Base Sepolia with
Circle's USDC, every fork pinned to Base Sepolia block 47881599 (hash `0xbdd034c324acf0d6095186f96a30c92b26cd86b947472b9a47de1ac5a909458c`).

## Toolchain

```
forge Version: 1.8.4
Commit SHA: 50af4efe189dc64bad2b75ed6990b835de66c4ae
Build Timestamp: 2026-10-01T14:08:28.191932892Z (1790863708)
Build Profile: dist
solc_version = "0.8.33"
via_ir = true
optimizer = true
optimizer_runs = 200
anvil Version: 1.8.4-dev
Commit SHA: 50af4efe189dc64bad2b75ed6990b835de66c4ae
Build Timestamp: 2026-10-01T13:48:41.535389527Z (1790862521)
Build Profile: dist
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

- Local suite (`logs/forge-test-local.txt`): Ran 30 test suites in 92.30s (92.24s CPU time): 304 tests passed, 0 failed, 14 skipped (318 total tests)
- Router fork suites against Circle's USDC (`logs/forge-test-fork-routers.txt`): Ran 2 test suites in 27.79s (27.78s CPU time): 78 tests passed, 0 failed, 0 skipped (78 total tests)
- Script tests (`logs/python-tests.txt`): verifier, rehearsal typed-data drift, two-hop check.
- Deep invariant campaigns, both router suites (14 distinct invariants (O1 to O7, R1 to R7) in 2 suites, each observed at runs: 512, calls: 76800, reverts: 0; read from the log, not from the request: the suites' inline annotations override the environment variables, so `scripts/candidate_deep_invariants.sh` patches them for the run and restores them): `logs/invariant-deep.txt`.
- Mutation check (`scripts/candidate_mutants.py`, one planted bug at a time, each must fail the suite): `logs/mutants.txt`.
- Rehearsals with `cast` on a fresh fork: `logs/rehearsal-normal.txt`, `logs/rehearsal-with-default.txt`.

Forge and Anvil versions are the ones recorded in the Toolchain block above. Forge 1.5 reports every invariant as its own test and prints the counts on that line; Forge 1.8 reports each invariant campaign as one test and prints the counts on a suite line, so test totals differ by tool version (`scripts/candidate_evidence_gate.py` reads both forms).

## Limits of this packet

- One host, one run. Nobody else has reproduced it; the gate checks that the logs say what a pass says, not that the run was faithful beyond what they record. The designated reviewer's read-only inspection of the published evidence found the seven exit codes and summaries consistent; that is inspection, not execution.
- The local suite reports skipped tests: they are fork suites that need RPC settings the local stage does not set (`BASE_SEPOLIA_RPC_URL`, or `LIVE_RPC_URL` and `LIVE_POOL`). The router fork suites ran in their own stage, with 0 skipped.
- Local EVM and local forks only: no public-chain receipt, no audit, no outside reproduction.
- This packet is assembled for review. It is not an acceptance: full packet revalidation, overall acceptance and the public-chain HOLD remain with the designated reviewer, and no readiness is claimed.

## Reproduce
To reproduce the run itself, check out the tested revision and run the script (needs forge, anvil, cast, python3 and https://sepolia.base.org):

```
git checkout 3efdb6f2ed93bfdd19e8fd7f0a379868ca2e81b3
scripts/candidate_evidence.sh
```

To re-judge this packet, run `python3 scripts/candidate_evidence_gate.py` on a copy of this directory (the gate deletes `FAILED.txt` on success and writes it on failure, so never point it at the only copy), and `sha256sum -c SHA256SUMS` from this directory.
