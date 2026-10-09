# Erratum: the deep invariant campaigns in the 2986e23 packets ran at 64 runs of depth 80, not 512 of 150

Found by Codex (contract PR 28, comment 6074015618). Applies to `evidence/bootstrap-candidate-2986e23/` (Codex's run), to
Hermes's supplement (testbed branch `hermes/pr28-repro-supplement-20261009`) and to the earlier packets
`bootstrap-candidate-4484e04/` and `bootstrap-candidate-e5da8c9/`, whose READMEs and the PR text said "512 runs of depth 150".
Those packets are kept as they were.

**What happened.** `scripts/candidate_evidence.sh` requested the deep campaigns through `FOUNDRY_INVARIANT_RUNS=512` and
`FOUNDRY_INVARIANT_DEPTH=150`. Both router invariant suites carry inline annotations
(`/// forge-config: default.invariant.runs = 64`, `depth = 80`, `fail-on-revert = true`) that override the environment, so
every campaign ran at 64 runs and 5,120 calls (`logs/invariant-deep.txt` shows `runs: 64, calls: 5120`). The README claimed
the requested depth, not the observed one. What the logs support is a pass at 64 x 80 with `fail-on-revert` on, not 512 x 150.
The mistake is mine: I wrote the README line from the request and never read the observed counts.

**What was done.**
1. A genuinely deep run: [`deep-invariants-512x150-00a04e7.txt`](deep-invariants-512x150-00a04e7.txt), the two router suites with
   only those annotations changed to 512 and 150 (patch at the top of the file), on a scratch worktree of the PR branch. All 14
   invariants passed (O1 to O7 and R1 to R7), each at `runs: 512, calls: 76800, reverts: 0`; suite times 106.8 s and 128.7 s.
   This is Claude Code's run on the same contract source (`packages/foundry/contracts` identical to 2986e23), not Codex's or
   Hermes's, and it is a local EVM run, not a public-chain receipt.
2. The tool is fixed: `scripts/candidate_deep_invariants.sh` patches the annotations for the run, prints the patch into the log
   and restores the files on every exit path. The evidence script calls it, and `candidate_evidence_gate.py` now refuses a
   packet unless the log records a patch of at least 512 and 150 and every invariant's PASS line shows exactly that many runs
   and runs x depth calls, and the tracked tree is unchanged after the deep run and the mutants. The README line is generated
   from the observed counts. Tests: `test_candidate_evidence_gate.py` (env-only runs, 64 runs under a 512 patch, wrong call
   counts, too few invariants and a dirty tree each fail).
3. A clean `candidate_evidence.sh` run at a head carrying this fix would produce a packet whose deep claim is read from the log.
   Until the designated reviewer decides whether to require that rerun, the 2986e23 packet supports 64 x 80 plus the separate
   512 x 150 run above.
