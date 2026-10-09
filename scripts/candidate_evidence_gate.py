#!/usr/bin/env python3
"""Fail-closed gate for the candidate evidence directory (run by candidate_evidence.sh before it writes README.md and SHA256SUMS).

  candidate_evidence_gate.py EVIDENCE_DIR

Reads `logs/exit-codes.txt` (one `name rc` line per run) and the logs, and exits non-zero, writing `FAILED.txt`, unless every
run exited 0 and its own summary line says what a pass says: no failed, no skipped fork test, no surviving mutant, both
rehearsals OK, every script test OK, and a verifier report that is ok with every check true and the lens linked to the pool
that was verified. A failed or partial run therefore cannot leave behind a complete-looking packet (Codex review 5462466632).
"""
import json, os, re, sys

RUNS = ("forge-test-local", "forge-test-fork-routers", "invariant-deep", "mutants", "python-tests", "rehearsal-normal", "rehearsal-with-default")
LENS_CHECK = "lens.credit == pool (the lens reads this pool)"


def forge_totals(text):
    m = re.findall(r"(\d+) tests passed, (\d+) failed, (\d+) skipped", text)
    return tuple(int(x) for x in m[-1]) if m else None


def gate(out):
    """Return a list of problems; empty means the packet may be completed."""
    bad = []
    def read(name):
        path = os.path.join(out, "logs", name)
        if not os.path.exists(path):
            return None
        with open(path) as f:
            return f.read()

    codes = {}
    for line in (read("exit-codes.txt") or "").splitlines():
        parts = line.split()
        if len(parts) == 2 and parts[1].lstrip("-").isdigit():
            codes[parts[0]] = int(parts[1])
    for name in RUNS:
        if name not in codes:
            bad.append(f"{name}: no exit code recorded")
        elif codes[name] != 0:
            bad.append(f"{name}: exited {codes[name]}")

    for name, allow_skipped in (("forge-test-local", True), ("forge-test-fork-routers", False), ("invariant-deep", False)):
        t = forge_totals(read(name + ".txt") or "")
        if t is None:
            bad.append(f"{name}: no 'N tests passed, N failed, N skipped' summary")
            continue
        passed, failed, skipped = t
        if passed == 0:
            bad.append(f"{name}: no test passed")
        if failed:
            bad.append(f"{name}: {failed} failed")
        if skipped and not allow_skipped:
            bad.append(f"{name}: {skipped} skipped (a fork or invariant test that did not run is not evidence)")

    # The deep campaigns: what was asked is in the patch printed at the top of the log, what ran is in the PASS lines. Both
    # router suites carry inline annotations that override the environment, so the request alone proves nothing.
    deep = read("invariant-deep.txt") or ""
    want_runs = re.findall(r"^\+/// forge-config: default\.invariant\.runs = (\d+)\s*$", deep, re.M)
    want_depth = re.findall(r"^\+/// forge-config: default\.invariant\.depth = (\d+)\s*$", deep, re.M)
    seen = re.findall(r"^\[PASS\] invariant_\w+\([^)]*\) \(runs: (\d+), calls: (\d+)", deep, re.M)
    if len(set(want_runs)) != 1 or len(set(want_depth)) != 1 or len(want_runs) < 2:
        bad.append("invariant-deep: no patch of the inline runs and depth annotations recorded in the log")
    elif int(want_runs[0]) < 512 or int(want_depth[0]) < 150:
        bad.append(f"invariant-deep: requested {want_runs[0]} runs of depth {want_depth[0]}, below 512 of 150")
    elif len(seen) < 14 or any(int(r) != int(want_runs[0]) or int(c) != int(want_runs[0]) * int(want_depth[0]) for r, c in seen):
        bad.append(f"invariant-deep: {len(seen)} PASS lines, not all at runs {want_runs[0]} and calls {int(want_runs[0]) * int(want_depth[0])}")
    ts = read("tree-status.txt")
    if ts is None or ts.strip():
        bad.append("tree-status.txt: missing or not empty (the tree must be clean after the deep run and the mutants)")

    lines = [x for x in (read("mutants.txt") or "").splitlines() if x.strip()]
    m = re.fullmatch(r"(\d+) mutants, 0 survived or did not compile", lines[-1].strip()) if lines else None
    if not m or int(m.group(1)) == 0:
        bad.append("mutants: the last line is not 'N mutants, 0 survived or did not compile'")

    py = (read("python-tests.txt") or "").splitlines()
    ran = [int(x) for x in re.findall(r"^Ran (\d+) tests?\b", "\n".join(py), re.M)]
    if not ran or ran[-1] == 0:
        bad.append("python-tests: no positive 'Ran N tests' line")
    elif "OK" not in [x.strip() for x in py[max(i for i, x in enumerate(py) if re.match(r"Ran \d+ tests?\b", x)):]]:
        bad.append("python-tests: no exact 'OK' line after the last 'Ran N tests' summary")
    if any(re.match(r"(FAILED|ERROR)\b", x) for x in py):
        bad.append("python-tests: a FAILED or ERROR line")

    for name, final in (("rehearsal-normal", "REHEARSAL OK"), ("rehearsal-with-default", "REHEARSAL OK (with default path)")):
        ls = [x for x in (read(name + ".txt") or "").splitlines() if x.strip()]
        if not ls or ls[-1].strip() != final:
            bad.append(f"{name}: the last line is not '{final}'")

    try:
        v = json.loads(read("verifier.json") or "")
    except ValueError:
        v = None
    if not v:
        bad.append("verifier.json: missing or not JSON")
    else:
        if v.get("ok") is not True:
            bad.append("verifier: ok is not true")
        checks = v.get("checks", {})
        if LENS_CHECK not in checks:
            bad.append("verifier: the lens.credit check is absent")
        for k, val in checks.items():
            if val is not True:
                bad.append(f"verifier check false: {k}")
        pool = v.get("contracts", {}).get("pool", {}).get("address", "")
        lens = v.get("wiring", {}).get("lens.credit")
        if not pool or not isinstance(lens, str) or lens.lower() != pool.lower():
            bad.append(f"verifier: lens.credit {lens!r} is not the verified pool {pool!r}")
        for role in ("pool", "lens", "router"):
            c = v.get("contracts", {}).get(role)
            if not c or c.get("match_strict") is not True:
                bad.append(f"verifier: {role} is not a strict build match")
            elif not re.fullmatch(r"[0-9a-f]{64}", str(c.get("masked_nometa_sha256_build", ""))) or \
                    c.get("masked_nometa_sha256_build") != c.get("masked_nometa_sha256_onchain"):
                bad.append(f"verifier: {role} has no equal metadata-free masked-runtime hashes")
        if v.get("rpc_chain_id") != 84532:
            bad.append(f"verifier: chain id {v.get('rpc_chain_id')} is not 84532")

    fb = (read("fork-block.txt") or "").split()
    if len(fb) != 2 or not fb[0].isdigit() or int(fb[0]) == 0 or not re.fullmatch(r"0x[0-9a-fA-F]{64}", fb[1]):
        bad.append("fork-block.txt: no pinned block number and hash")
    for name in ("toolchain.txt", "build-sizes.txt"):
        if not (read(name) or "").strip():
            bad.append(f"{name}: empty or missing")
    return bad


def main():
    out = sys.argv[1]
    bad = gate(out)
    path = os.path.join(out, "FAILED.txt")
    if bad:
        with open(path, "w") as f:
            f.write("The evidence run did not pass; no README.md or SHA256SUMS was written.\n" + "\n".join("- " + b for b in bad) + "\n")
        print("EVIDENCE GATE FAILED:\n" + "\n".join("- " + b for b in bad), file=sys.stderr)
        return 1
    if os.path.exists(path):
        os.remove(path)
    print("evidence gate: all runs passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
