# Bootstrap candidate: exact-head evidence

Code head: `4484e04dc4f63c1d45cbe81f9cd73fa208b0d2eb`. This directory was produced by `scripts/candidate_evidence.sh` from a clean checkout of that head and
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
| pool | 24,538 | 38 | `cc979baa0d5e9c8f55363a264f9bc885db3db6614d342efa3e069b5cc83ca758` | `f65f697ccfcbf964214c390d544237ce9eab09e6b1cf69e30495e5e74efbf700` | True |
| lens | 3,287 | 21,289 | `36f7956df62569da3d76a2d1f1bdb73460d3980ec87e8b31f55fe7b0880d8922` | `cea757c169ae1215d1da938b796d35334c46c1ed025257d342adc13ac715f337` | True |
| router | 16,748 | 7,828 | `b3b7a9d66446ddb71e1084232cc87a1af7a51d6f5d7bc85300cd58f7c51b5138` | `450c64afc05429c17965fe1480655c85c5bccfd664223c9ed662b4093e9f8868` | True |

Full `forge build --sizes` is in `logs/build-sizes.txt`. Every contract matched the compiled artifact strictly (immutables
zeroed on both sides) and every wiring check held.

## Tests

- Local suite (`logs/forge-test-local.txt`): Ran 31 test suites in 15.70s (39.12s CPU time): 340 tests passed, 0 failed, 14 skipped (354 total tests)
- Router fork suites against Circle's USDC (`logs/forge-test-fork-routers.txt`): Ran 2 test suites in 5.86s (10.90s CPU time): 66 tests passed, 0 failed, 0 skipped (66 total tests)
- Script tests (`logs/python-tests.txt`): verifier, rehearsal typed-data drift, two-hop check.
- Deep invariant campaigns (512 runs of depth 150, both router suites) are recorded in `logs/invariant-deep.txt`.
- Rehearsals with `cast` on a fresh fork: `logs/rehearsal-normal.txt`, `logs/rehearsal-with-default.txt`.

Local Forge here is 1.5.1; CI uses 1.8.5, which counts each invariant campaign as one test, so counts differ by tool version.

## Reproduce

```
git checkout 4484e04dc4f63c1d45cbe81f9cd73fa208b0d2eb
scripts/candidate_evidence.sh   # needs forge, anvil, cast, python3 and https://sepolia.base.org
```
