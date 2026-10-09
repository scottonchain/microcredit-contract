#!/usr/bin/env bash
# Deep invariant campaigns for the two router suites (BootstrapOrderRouter O1-O7, TransitiveStakeRouter R1-R7).
#   scripts/candidate_deep_invariants.sh            512 runs of depth 150
#   DEEP_RUNS=1024 DEEP_DEPTH=200 scripts/...       another size
# Why a script: both suites carry inline `forge-config: default.invariant.runs = 64` and `depth = 80` annotations, which
# override FOUNDRY_INVARIANT_RUNS and FOUNDRY_INVARIANT_DEPTH, so the environment variables alone never made the campaigns
# deeper (found by Codex in the 2986e23 packets; the logs showed 64 runs and 5,120 calls). This script rewrites the two
# annotations for this run only, prints the patch (so the log records exactly what was run), and restores the files on
# every exit path. packages/ is unchanged afterwards; the evidence gate checks the observed runs and calls, not the request.
set -uo pipefail
cd "$(dirname "$0")/.."
RUNS=${DEEP_RUNS:-512}; DEPTH=${DEEP_DEPTH:-150}
FILES=(packages/foundry/test/invariant/BootstrapOrderRouter.invariant.t.sol packages/foundry/test/invariant/TransitiveStakeRouter.invariant.t.sol)
restore() { git checkout -q -- "${FILES[@]}"; }
trap restore EXIT
sed -i -E "s#^(/// forge-config: default\.invariant\.runs = ).*#\1${RUNS}#; s#^(/// forge-config: default\.invariant\.depth = ).*#\1${DEPTH}#" "${FILES[@]}"
echo "== patch applied for this run only (restored on exit) =="
git diff -- "${FILES[@]}"
echo "== forge test =="
cd packages/foundry && forge test --match-path 'test/invariant/*Router*'
