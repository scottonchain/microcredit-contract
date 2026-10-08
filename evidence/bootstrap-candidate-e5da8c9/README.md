# Bootstrap candidate: exact-head evidence

Code head: `e5da8c92a2f57c2277cf16064d70203a72657345`. This directory was produced by `scripts/candidate_evidence.sh` from a clean checkout of that head and
added in a commit that changes no code. Nothing here is a public-chain receipt: tests ran on a local EVM with synthetic
time; fork runs and rehearsals ran on a local Anvil fork of Base Sepolia with Circle's USDC.

## Toolchain

```
forge Version: 1.5.1-stable
Commit SHA: b0a9dd9ceda36f63e2326ce530c10e6916f4b8a2
Build Timestamp: 2025-12-22T11:39:01.425730780Z (1766403541)
Build Profile: maxperf
solc_version = "0.8.33"
via_ir = true
optimizer = true
optimizer_runs = 200
```

## Contracts (from `logs/verifier.json`, deployed to a fork by `DeployBootstrapCandidate.s.sol`)

| Contract | Runtime bytes | EIP-170 margin | Masked-runtime sha256 | ABI sha256 | Strict match |
| --- | ---: | ---: | --- | --- | --- |
| pool | 24,439 | 137 | `d64baea7b470412c2463dac0b2fbe1d48e2708b946f920bc28ee0b4b9d009fe9` | `35755c5dbc61b3af72763452975fee8148a24a08864f7a606959b578d93132df` | True |
| lens | 3,287 | 21,289 | `2641269fb22bb92ff7921c289518f8133362224b97dd71d3938811440fd5c7fc` | `cea757c169ae1215d1da938b796d35334c46c1ed025257d342adc13ac715f337` | True |
| router | 18,105 | 6,471 | `9396176d260b00c402817a1c6479e5267b665fa5aaa2494ed566aec73033171a` | `97d70fa6f17785c292a0e2819f13e1df58d89930a6f494063ac7c9b160fd86ae` | True |

Full `forge build --sizes` is in `logs/build-sizes.txt`. Every contract matched the compiled artifact strictly (immutables
zeroed on both sides) and every wiring check held.

## Tests

- Local suite (`logs/forge-test-local.txt`): Ran 30 test suites in 18.47s (45.45s CPU time): 329 tests passed, 0 failed, 14 skipped (343 total tests)
- Router fork suites against Circle's USDC (`logs/forge-test-fork-routers.txt`): Ran 2 test suites in 20.28s (40.55s CPU time): 78 tests passed, 0 failed, 0 skipped (78 total tests)
- Script tests (`logs/python-tests.txt`): verifier, rehearsal typed-data drift, two-hop check.
- Deep invariant campaigns (512 runs of depth 150, both router suites) are recorded in `logs/invariant-deep.txt`.
- Mutation check (`scripts/candidate_mutants.py`, one planted bug at a time, each must fail the suite): `logs/mutants.txt`.
- Rehearsals with `cast` on a fresh fork: `logs/rehearsal-normal.txt`, `logs/rehearsal-with-default.txt`.

Local Forge here is 1.5.1; CI uses 1.8.5, which counts each invariant campaign as one test, so counts differ by tool version.

## Reproduce

```
git checkout e5da8c92a2f57c2277cf16064d70203a72657345
scripts/candidate_evidence.sh   # needs forge, anvil, cast, python3 and https://sepolia.base.org
```
