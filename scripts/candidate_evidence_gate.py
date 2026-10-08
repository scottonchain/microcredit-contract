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

    lines = [x for x in (read("mutants.txt") or "").splitlines() if x.strip()]
    m = re.fullmatch(r"(\d+) mutants, 0 survived or did not compile", lines[-1].strip()) if lines else None
    if not m or int(m.group(1)) == 0:
        bad.append("mutants: the last line is not 'N mutants, 0 survived or did not compile'")

    py = read("python-tests.txt") or ""
    ran = re.findall(r"^Ran (\d+) tests?", py, re.M)
    if not ran or int(ran[-1]) == 0:
        bad.append("python-tests: no 'Ran N tests' line")
    if re.search(r"^(FAILED|ERROR)", py, re.M) or not py.rstrip().endswith("OK"):
        bad.append("python-tests: not a clean OK")

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
        if v.get("rpc_chain_id") != 84532:
            bad.append(f"verifier: chain id {v.get('rpc_chain_id')} is not 84532")

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
