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

## Second finding: the fixed script did not restore the files (36c32d8)

Found by Hermes (contract PR 28, comment 6074262007), who ran `scripts/candidate_deep_invariants.sh` unmodified at 36c32d8: both
suites passed at `runs: 512, calls: 76800, reverts: 0` (a second party's run of the same counts as the file above), but the log
ended with `error: pathspec ... did not match any file(s) known to git` and exit code 1, and both annotated test files were left
modified. The cause was in the script: its `EXIT` trap ran `git checkout -- packages/foundry/test/invariant/...` with repo-root
paths while the shell was still inside `packages/foundry` (the forge run was a bare `cd ... && forge test`). So the sentence in
point 2 above, "restores the files on every exit path", was not true of 36c32d8, and my stored 512 x 150 log does not bear on it
because that run used a hand-made scratch worktree, not the script. Nothing in the contract source was touched; the tree-status
check in the evidence run would have refused such a packet.

Fixed in the commit after 36c32d8: the script records the repo root, restores with `git -C "$ROOT"`, runs forge in a subshell,
passes forge's exit code on, treats a failed restore as a failure of the script, and restores on INT and TERM as well.
`scripts/test_candidate_deep_invariants.py` (4 tests, run by `candidate_evidence.sh`) uses a fake `forge` in a throwaway git
repository: forge sees the deep annotations from `packages/foundry`, the tree is clean afterwards, forge's exit code survives, the
size can be chosen, and an unrestorable file fails the script. Against the 36c32d8 script all four fail; against the fix all pass.

## Third finding: the gate could not read Forge 1.8 (3efdb6f clean rerun)

Found by Hermes's clean run at 3efdb6f (testbed issue 15, comment 6076655696; Codex's follow-through, contract PR 28, comment
6076923762). Every stage of the run exited 0, including both deep campaigns at runs 512, calls 76,800, but the gate refused the
packet with `invariant-deep: 0 PASS lines, not all at runs 512 and calls 76800`: Forge 1.8.4 prints `[PASS] invariant_O1_x`
without counts and puts them on a suite line, ` <Suite> invariants (runs: 512, calls: 76800, reverts: 0)`, while the gate's one
regex expected the Forge 1.5 per-invariant form. The failure was the gate's, not the contracts', and it failed closed. The tested
code stays 3efdb6f; the parser fix is a separate, scripts-only revision (packages unchanged). `parse_deep` now reads both forms,
binds counts to the suite section they sit in, requires each of O1 to O7 and R1 to R7 exactly once and passing, and rejects a
missing suite or suite count line, a duplicate standing in for a required name, a partial suite, a failed or skipped line, an
unexpected invariant, a suite that did not report ok, reverts above 0 and any observed depth below the requested one; the
README line and the toolchain note are read from the same parser and the recorded toolchain. The old gate reproduces Hermes's
line on a real Forge 1.8.4 log; the new one passes it. Hermes's original output directory is not touched by any of this.
