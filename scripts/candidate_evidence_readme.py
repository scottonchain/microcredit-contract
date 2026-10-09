#!/usr/bin/env python3
"""Render README.md for an evidence directory that the gate has already passed.

  candidate_evidence_readme.py OUT_DIR HEAD_SHA            what candidate_evidence.sh calls after its own gate passed
  (library) render(out, head, intro=None, limits=None, reproduce=None)   used by candidate_package_run.py for a run made elsewhere

Every figure is read from the logs by the same parsers the gate uses; nothing is typed in. `intro`, `limits` and `reproduce` let a
packet assembled from someone else's run say so instead of claiming it was produced by this script from a clean checkout.
"""
import json, os, re, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import candidate_evidence_gate as gate  # the README line comes from the parser that the gate just passed, not from a second regex


def read(path):
    with open(path) as f:
        return f.read()


def render(out, head, intro=None, limits=None, reproduce=None):
    v = json.loads(read(f"{out}/logs/verifier.json"))
    rows = ["| Contract | Runtime bytes | EIP-170 margin | Masked-runtime sha256, metadata removed | ABI sha256 | Strict match |", "| --- | ---: | ---: | --- | --- | --- |"]
    for role, c in v["contracts"].items():
        rows.append(f"| {role} | {c['onchain_bytes']:,} | {c['eip170_margin']:,} | `{c['masked_nometa_sha256_build']}` | `{c['abi_sha256']}` | {c['match_strict']} |")

    def last(path, pat):
        t = read(path)
        return re.findall(pat, t)[-1] if re.findall(pat, t) else "n/a"
    local = last(f"{out}/logs/forge-test-local.txt", r"Ran \d+ test suites[^\n]*")
    deep_txt = gate.deep_summary(read(f"{out}/logs/invariant-deep.txt"))
    fork = last(f"{out}/logs/forge-test-fork-routers.txt", r"Ran \d+ test suites[^\n]*")
    tool = read(f"{out}/logs/toolchain.txt").strip()
    fblock, fhash = read(f"{out}/logs/fork-block.txt").split()
    if intro is None:
        intro = f"""Code head: `{head}`. This directory was produced by `scripts/candidate_evidence.sh` from a clean checkout of that head and
added in a commit that changes no code. Nothing here is a public-chain receipt: tests ran on a local EVM with synthetic
time; fork runs and rehearsals ran on local Anvil forks of Base Sepolia with Circle's USDC, every fork pinned to Base Sepolia
block {fblock} (hash `{fhash}`)."""
    if reproduce is None:
        reproduce = f"""
```
git checkout {head}
scripts/candidate_evidence.sh   # needs forge, anvil, cast, python3 and https://sepolia.base.org
```"""
    def fill(text):  # placeholders for a caller that cannot know these values before the logs are read
        return text.replace("@HEAD@", head).replace("@FBLOCK@", fblock).replace("@FHASH@", fhash)
    intro, reproduce = fill(intro), fill(reproduce)
    limits = f"\n\n{fill(limits).strip()}" if limits else ""
    return f"""# Bootstrap candidate: exact-head evidence

{intro}

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

Forge and Anvil versions are the ones recorded in the Toolchain block above. Forge 1.5 reports every invariant as its own test and prints the counts on that line; Forge 1.8 reports each invariant campaign as one test and prints the counts on a suite line, so test totals differ by tool version (`scripts/candidate_evidence_gate.py` reads both forms).{limits}

## Reproduce
{reproduce}
"""


def main():
    out, head = sys.argv[1], sys.argv[2]
    with open(f"{out}/README.md", "w") as f:
        f.write(render(out, head))


if __name__ == "__main__":
    main()
