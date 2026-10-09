#!/usr/bin/env bash
# Produce the exact-head evidence directory for the bootstrap candidate: toolchain, sizes, hashes, complete test and
# rehearsal logs, checksums. Run from a clean checkout of the head to be reviewed:
#   scripts/candidate_evidence.sh [outdir]      (default evidence/bootstrap-candidate-<short head>)
# Needs forge, anvil, cast, python3 and network access to https://sepolia.base.org (fork tests and rehearsals).
set -euo pipefail
cd "$(dirname "$0")/.."
HEAD_SHA=$(git rev-parse HEAD); SHORT=$(git rev-parse --short=7 HEAD)
OUT=${1:-evidence/bootstrap-candidate-$SHORT}
test -z "$(git status --porcelain -- packages scripts docs/*.md CLAUDE.md)" || { echo "tree is not clean"; exit 1; }
rm -rf "$OUT/logs"; rm -f "$OUT/README.md" "$OUT/SHA256SUMS" "$OUT/FAILED.txt"; mkdir -p "$OUT/logs"
RPC=https://sepolia.base.org
ORACLE=0x000000000000000000000000000000000000dEaD
SENDER=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
# Every run records its exit code and its log; nothing is swallowed. scripts/candidate_evidence_gate.py then refuses to let
# a packet exist unless every run exited 0 and its own summary line says it passed (Codex review 5462466632).
RC="$OUT/logs/exit-codes.txt"; : > "$RC"
run() {  # run NAME LOGFILE COMMAND...
  local name=$1 log=$2 rc=0; shift 2
  "$@" > "$OUT/logs/$log" 2>&1 || rc=$?
  echo "$name $rc" >> "$RC"
}
# `forge build --sizes` exits non-zero because an invariant test handler (CreditHandler) is over 24,576 bytes; it is never deployed
( cd packages/foundry && forge build >/dev/null && { forge build --sizes || true; } ) > "$OUT/logs/build-sizes.txt" 2>&1
( cd packages/foundry && forge --version && grep -E "solc_version|via_ir|optimizer|evm_version" foundry.toml ) > "$OUT/logs/toolchain.txt" 2>&1
run forge-test-local forge-test-local.txt bash -c 'cd packages/foundry && forge test'
run forge-test-fork-routers forge-test-fork-routers.txt bash -c "cd packages/foundry && BASE_SEPOLIA_RPC_URL=$RPC forge test --match-path 'test/fork/*Router*'"
# The suites' inline forge-config annotations override FOUNDRY_INVARIANT_*, so the deep run patches them for its own duration
# (scripts/candidate_deep_invariants.sh prints the patch and restores the files); the gate checks the observed runs and calls.
run invariant-deep invariant-deep.txt scripts/candidate_deep_invariants.sh
run mutants mutants.txt python3 scripts/candidate_mutants.py
git status --porcelain --untracked-files=no -- packages scripts docs/*.md CLAUDE.md > "$OUT/logs/tree-status.txt"  # the deep run and the mutants must leave every tracked file as it was (forge may add an untracked foundry.lock)
run python-tests python-tests.txt bash -c 'cd scripts && python3 -m unittest test_verify_candidate_deployment test_candidate_evidence_gate test_candidate_fork test_candidate_deep_invariants test_candidate_rehearsal test_two_hop_check'
# One Base Sepolia block is pinned for the whole run, so both rehearsals start from identical state. Each fork is started and
# stopped by scripts/candidate_fork.py, which tracks the child's pid, refuses a port that already answers and fails if the
# child exits or cannot bind; nothing here uses pkill (Codex review 5463115207: a restart race let the second rehearsal run
# on the first, used fork).
PORT=8546; FORKDIR=$(mktemp -d); PIDFILE="$FORKDIR/anvil.pid"; FORKLOG="$FORKDIR/anvil.log"
trap 'python3 scripts/candidate_fork.py stop --pidfile "$PIDFILE" --port $PORT || true; rm -rf "$FORKDIR"' EXIT
read -r BLOCK BLOCKHASH < <(python3 scripts/candidate_fork.py block --rpc $RPC)
echo "$BLOCK $BLOCKHASH" > "$OUT/logs/fork-block.txt"
anvil --version >> "$OUT/logs/toolchain.txt" 2>&1
fresh_fork() {  # stops the previous fork, starts a fresh one at the pinned block, deploys the candidate; sets P L R
  python3 scripts/candidate_fork.py stop --pidfile "$PIDFILE" --port $PORT
  python3 scripts/candidate_fork.py start --rpc $RPC --block "$BLOCK" --port $PORT --log "$FORKLOG" --pidfile "$PIDFILE" > /dev/null
  local o line; o=$(cd packages/foundry && BOOTSTRAP_ORACLE=$ORACLE forge script script/DeployBootstrapCandidate.s.sol --rpc-url http://127.0.0.1:$PORT --broadcast --unlocked --sender $SENDER 2>&1) || { echo "$o" >&2; exit 1; }
  rm -rf packages/foundry/broadcast/DeployBootstrapCandidate.s.sol
  line=$(echo "$o" | awk '/candidate pool/{p=$NF} /candidate lens/{l=$NF} /candidate bootstrap order router/{r=$NF} END{print p, l, r}')
  [[ $(wc -w <<<"$line") -eq 3 ]] || { echo "deploy did not print three addresses: $line" >&2; exit 1; }
  for a in $line; do [[ $a =~ ^0x[0-9a-fA-F]{40}$ ]] || { echo "deploy did not print three addresses: $line" >&2; exit 1; }; done
  read -r P L R <<<"$line"
}
fresh_fork
python3 scripts/verify_candidate_deployment.py --rpc http://127.0.0.1:$PORT --pool "$P" --lens "$L" --router "$R" --json > "$OUT/logs/verifier.json"
run rehearsal-normal rehearsal-normal.txt python3 scripts/candidate_rehearsal.py run --rpc http://127.0.0.1:$PORT --pool "$P" --router "$R"
fresh_fork
run rehearsal-with-default rehearsal-with-default.txt python3 scripts/candidate_rehearsal.py run --rpc http://127.0.0.1:$PORT --pool "$P" --router "$R" --with-default
python3 scripts/candidate_fork.py stop --pidfile "$PIDFILE" --port $PORT
python3 scripts/candidate_evidence_gate.py "$OUT" || { echo "the evidence run did not pass; see $OUT/FAILED.txt and the logs"; exit 1; }
python3 - "$OUT" "$HEAD_SHA" <<'PY'
import json, re, sys, hashlib, os
out, head = sys.argv[1], sys.argv[2]
v = json.load(open(f"{out}/logs/verifier.json"))
rows = ["| Contract | Runtime bytes | EIP-170 margin | Masked-runtime sha256, metadata removed | ABI sha256 | Strict match |", "| --- | ---: | ---: | --- | --- | --- |"]
for role, c in v["contracts"].items():
    rows.append(f"| {role} | {c['onchain_bytes']:,} | {c['eip170_margin']:,} | `{c['masked_nometa_sha256_build']}` | `{c['abi_sha256']}` | {c['match_strict']} |")
def last(path, pat):
    t = open(path).read()
    return re.findall(pat, t)[-1] if re.findall(pat, t) else "n/a"
local = last(f"{out}/logs/forge-test-local.txt", r"Ran \d+ test suites[^\n]*")
deep = re.findall(r"\[PASS\] invariant_\w+\([^)]*\) \(runs: (\d+), calls: (\d+)", open(f"{out}/logs/invariant-deep.txt").read())
deep_txt = f"{len(deep)} invariants, each observed at runs: {deep[0][0]}, calls: {deep[0][1]}" if deep and len(set(deep)) == 1 else "see the log"
fork = last(f"{out}/logs/forge-test-fork-routers.txt", r"Ran \d+ test suites[^\n]*")
tool = open(f"{out}/logs/toolchain.txt").read().strip()
fblock, fhash = open(f"{out}/logs/fork-block.txt").read().split()
md = f"""# Bootstrap candidate: exact-head evidence

Code head: `{head}`. This directory was produced by `scripts/candidate_evidence.sh` from a clean checkout of that head and
added in a commit that changes no code. Nothing here is a public-chain receipt: tests ran on a local EVM with synthetic
time; fork runs and rehearsals ran on local Anvil forks of Base Sepolia with Circle's USDC, every fork pinned to Base Sepolia
block {fblock} (hash `{fhash}`).

## Toolchain

```
{tool}
```

## Contracts (from `logs/verifier.json`, deployed to a fork by `DeployBootstrapCandidate.s.sol`)

{chr(10).join(rows)}

Compare hosts on the size, the metadata-free hash and the ABI hash: the compiler's metadata trailer depends on the checkout path, so
the full masked hash in `logs/verifier.json` (`masked_sha256_*`) differs between two checkouts of the same source. Full `forge build --sizes` is in `logs/build-sizes.txt`. Every contract matched the compiled artifact strictly (immutables
zeroed on both sides) and every wiring check held, including `lens.credit == pool` read through the lens's own getter.
`scripts/candidate_evidence_gate.py` refused to complete this packet unless every run exited 0 and its summary line passed.

## Tests

- Local suite (`logs/forge-test-local.txt`): {local}
- Router fork suites against Circle's USDC (`logs/forge-test-fork-routers.txt`): {fork}
- Script tests (`logs/python-tests.txt`): verifier, rehearsal typed-data drift, two-hop check.
- Deep invariant campaigns, both router suites ({deep_txt}; read from the log, not from the request: the suites' inline annotations override the environment variables, so `scripts/candidate_deep_invariants.sh` patches them for the run and restores them): `logs/invariant-deep.txt`.
- Mutation check (`scripts/candidate_mutants.py`, one planted bug at a time, each must fail the suite): `logs/mutants.txt`.
- Rehearsals with `cast` on a fresh fork: `logs/rehearsal-normal.txt`, `logs/rehearsal-with-default.txt`.

Local Forge here is 1.5.1; CI uses 1.8.5, which counts each invariant campaign as one test, so counts differ by tool version.

## Reproduce

```
git checkout {head}
scripts/candidate_evidence.sh   # needs forge, anvil, cast, python3 and https://sepolia.base.org
```
"""
open(f"{out}/README.md", "w").write(md)
PY
( cd "$OUT" && find . -type f ! -name SHA256SUMS | sort | xargs sha256sum > SHA256SUMS )
echo "evidence written to $OUT"
