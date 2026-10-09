# Gate re-evaluation of the clean run at 3efdb6f (parser only)

**This is not an acceptance packet, and it is not a new run.** It records what the fixed evidence gate says about the output of
one existing run, kept separate from that run's original failed result. Disposition of the evidence belongs to the designated
reviewer; HOLD is unchanged and no readiness is claimed.

## What was tested, and by what

| Item | Value |
| --- | --- |
| Tested code | contract repo `3efdb6f2ed93bfdd19e8fd7f0a379868ca2e81b3` (`packages/` is identical at every later commit) |
| The run | one execution of `scripts/candidate_evidence.sh`, unmodified, by Hermes (AI agent), 06:20:17Z to 07:38:55Z on 2026-10-09, Forge 1.8.4, solc 0.8.33, local Anvil forks of Base Sepolia only |
| Run output as published | testbed repository, branch `hermes/pr28-repro-supplement-20261009`, commit `8f80978d14554737d88e96128a5f32fe2a492d62`, directory `evidence/pr28-clean-rerun-3efdb6f-hermes/` (original bytes; Hermes's own index is `HERMES_SHA256SUMS.txt` there) |
| Gate that judged it first | `scripts/candidate_evidence_gate.py` at 3efdb6f, result **failed** with one problem, kept verbatim in `original-FAILED.txt` (sha256 `6f3b3d48fc6b453f836a00cf8e05209353a51c724b54607735d7ce5032e7bee6`, equal to Hermes's index) |
| Gate that re-evaluated it | `scripts/candidate_evidence_gate.py` from the parser-fix revision `5d17e2c` (sha256 `28ab333532816a882638ee0c46784249987b9866a80f890788dbe33007a98c65`) |
| How | the published directory was copied to a separate location and the fixed gate run on the copy; the published bytes, Hermes's original directory and the original failed result were not touched (the gate deletes `FAILED.txt` on success, which is why it ran on a copy) |

## Why the first gate failed, and what changed

The first gate said `invariant-deep: 0 PASS lines, not all at runs 512 and calls 76800`. Forge 1.8.4 prints each invariant as
`[PASS] invariant_O1_x` with no counts and prints the counts on one line per suite, for example
` BootstrapOrderRouterInvariantTest invariants (runs: 512, calls: 76800, reverts: 0)`; the first gate's regex read only the Forge 1.5
per-invariant form. The failure was the gate's. The parser fix (`parse_deep` in the gate) reads both forms per suite and per
named invariant; see `evidence/ERRATUM-deep-invariants-2986e23.md`, third finding, and `docs/CANDIDATE_VERIFICATION.md`.

## Result of the re-evaluation

`reevaluation-output.txt`: `evidence gate: all runs passed`, exit 0. Read from the run's own files:

- Exit codes: all seven stages 0 (`forge-test-local`, `forge-test-fork-routers`, `invariant-deep`, `mutants`, `python-tests`, `rehearsal-normal`, `rehearsal-with-default`).
- Deep invariants, parsed per suite: 14 distinct invariants (O1 to O7 in `BootstrapOrderRouterInvariantTest`, R1 to R7 in `TransitiveStakeRouterInvariantTest`), each suite observed at runs 512, calls 76,800, reverts 0; both annotation patches (512 and 150) are in the log; `tree-status.txt` is empty.
- Local suite 304 passed, 0 failed, 14 skipped (fork suites); router fork suites 78 passed, 0 skipped; 18 of 18 mutants killed; 83 script tests OK; both rehearsals `REHEARSAL OK`; fork pinned at Base Sepolia block 47,881,599.
- Verifier, chain 84532, strict build match for all three contracts, `lens.credit == pool`; sizes and metadata-free hashes equal those in the 2986e23 packet that Codex generated: pool 24,439 bytes (`e1afd70e…c1739`, ABI `35755c5d…2df`), lens 3,287 (`9c23acfe…ff9`, `cea757c1…f337`), router 18,105 (`51c9218c…a728c`, `97d70fa6…86ae`). The code under test is the same bytes (`packages/` unchanged since 2986e23).

## What this does not show

- It does not make the run an accepted packet: the gate-written `README.md` and `SHA256SUMS` for 3efdb6f do not exist, and whether to produce them from this output, to rerun, or to rely on the 2986e23 packet plus these corrections is the designated reviewer's decision.
- It is one host's run (Hermes's); nobody else has reproduced it. The gate checks that logs say what a pass says; it cannot see whether the run was faithful beyond what the logs record.
- Local EVM and local forks only: no public-chain receipt, no audit.

## Key input hashes (sha256, from Hermes's index; the full index is in the published directory)

```
02cceb9ccc3bc7c4c72ddda326e120a7ca1e7a9cb81c6f4235a450840cc46a47  logs/invariant-deep.txt
93819202da05338b7b8a712d2f5e69ebfe663e9896e9693f5a35bc1ac5b4e369  logs/exit-codes.txt
7404f4c1e55cf5f5160c0fbb3127f24a95d7af67d04d24985101039de62fac2b  logs/verifier.json
b7d924d0e197a24c903f180a61311d10d547d2a874da17317ce20596ed315846  logs/fork-block.txt
e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855  logs/tree-status.txt (empty)
6f3b3d48fc6b453f836a00cf8e05209353a51c724b54607735d7ce5032e7bee6  FAILED.txt (the original failed result)
```

`scripts/fixtures/forge184-invariant-deep-512x150-3efdb6f-hermes.txt` is `logs/invariant-deep.txt` byte for byte (a fixture for the gate's tests).
