#!/usr/bin/env python3
"""Fail-closed gate for the candidate evidence directory (run by candidate_evidence.sh before it writes README.md and SHA256SUMS).

  candidate_evidence_gate.py EVIDENCE_DIR [--check]

`--check` is read-only: use it on a published packet without changing its original FAILED.txt.

Reads `logs/exit-codes.txt` (one `name rc` line per run) and the logs, and exits non-zero, writing `FAILED.txt`, unless every
run exited 0 and its own summary line says what a pass says: no failed, no skipped fork test, no surviving mutant, both
rehearsals OK, every script test OK, and a verifier report that is ok with every check true and the lens linked to the pool
that was verified. A failed or partial run therefore cannot leave behind a complete-looking packet (Codex review 5462466632).
"""
import argparse, json, os, re, sys

RUNS = ("forge-test-local", "forge-test-fork-routers", "invariant-deep", "mutants", "python-tests", "rehearsal-normal", "rehearsal-with-default")
LENS_CHECK = "lens.credit == pool (the lens reads this pool)"


def forge_totals(text):
    m = re.findall(r"(\d+) tests passed, (\d+) failed, (\d+) skipped", text)
    return tuple(int(x) for x in m[0]) if len(m) == 1 else None


DEEP_SUITES = {"BootstrapOrderRouterInvariantTest": "O", "TransitiveStakeRouterInvariantTest": "R"}
DEEP_COUNT = 7  # each suite carries invariants <letter>1 to <letter>7, each exactly once
RAN_SUITE = re.compile(r"^Ran (\d+) tests? for (\S+):(\w+)\s*$")
RAN_ANY = re.compile(r"^Ran \d+ test")
INV_LINE = re.compile(r"^\[(PASS|FAIL|SKIP)[^\]]*\]\s+invariant_([A-Za-z])(\d+)_\w*?(?:\(\))?(?:\s+\(runs: (\d+), calls: (\d+), reverts: (\d+)\))?\s*$")
SUITE_COUNTS = re.compile(r"^\s*(\w+) invariants \(runs: (\d+), calls: (\d+), reverts: (\d+)\)\s*$")
SUITE_RESULT = re.compile(r"^Suite result: (\w+)\. (\d+) passed; (\d+) failed; (\d+) skipped")


def parse_deep(text):
    """Read a `forge test` log of the two router invariant suites in either real output form and return (suites, problems).

    Forge 1.5 prints one line per invariant, `[PASS] invariant_O1_x() (runs: R, calls: C, reverts: V)`. Forge 1.8 prints each
    campaign as one test: a bare `[PASS]`, the invariants as `[PASS] invariant_O1_x` without counts, and one suite line
    ` <Suite> invariants (runs: R, calls: C, reverts: V)` that holds the counts of every invariant in it. Counts are bound to the
    suite whose `Ran N test(s) for <file>:<Suite>` section they appear in; nothing is read across suites.
    suites maps a suite name to {"ids": {n: [record, ...]}, "counts": (runs, calls, reverts) | None, "result": (...) | None,
    "bad": [lines]}; each record is (status, own counts | None)."""
    suites, problems, cur = {}, [], None
    for raw in text.splitlines():
        line = raw.rstrip()
        m = RAN_SUITE.match(line)
        if m:
            cur = m.group(3)
            if cur in suites:
                problems.append(f"invariant-deep: suite {cur} appears twice")
            suites.setdefault(cur, {"ids": {}, "counts": None, "result": None, "bad": []})
            continue
        if RAN_ANY.match(line):
            cur = None  # the closing `Ran N test suites` summary
            continue
        if re.match(r"^\[(FAIL|SKIP)", line):
            if cur is None:
                problems.append(f"invariant-deep: a failed or skipped line outside any suite: {line[:80]}")
            else:
                suites[cur]["bad"].append(line[:80])
            continue
        if cur is None:
            continue
        m = INV_LINE.match(line)
        if m:
            n = int(m.group(3))
            own = tuple(int(x) for x in m.group(4, 5, 6)) if m.group(4) else None
            suites[cur]["ids"].setdefault((m.group(2).upper(), n), []).append((m.group(1), own))
            continue
        m = SUITE_COUNTS.match(line)
        if m:
            if m.group(1) != cur:
                problems.append(f"invariant-deep: counts for {m.group(1)} inside the {cur} section")
            elif suites[cur]["counts"] is not None:
                problems.append(f"invariant-deep: {cur} has two suite count lines")
            else:
                suites[cur]["counts"] = tuple(int(x) for x in m.group(2, 3, 4))
            continue
        m = SUITE_RESULT.match(line)
        if m:
            suites[cur]["result"] = (m.group(1), int(m.group(2)), int(m.group(3)), int(m.group(4)))
    return suites, problems


def deep_problems(text, runs, depth):
    """Problems with the deep log judged against the requested size; empty means both suites passed every invariant at that size."""
    suites, bad = parse_deep(text)
    for name, letter in DEEP_SUITES.items():
        s = suites.get(name)
        if s is None:
            bad.append(f"invariant-deep: suite {name} is missing")
            continue
        if s["bad"]:
            bad.append(f"invariant-deep: {name} has failed or skipped lines: {s['bad'][0]}")
        if not s["result"] or s["result"][0] != "ok" or s["result"][2] or s["result"][3] or not s["result"][1]:
            bad.append(f"invariant-deep: {name} has no 'Suite result: ok' with 0 failed and 0 skipped")
        want = {(letter, n) for n in range(1, DEEP_COUNT + 1)}
        for key in sorted(want):
            recs = s["ids"].get(key, [])
            if len(recs) != 1:
                bad.append(f"invariant-deep: {name} has {len(recs)} results for {key[0]}{key[1]}, not exactly one")
                continue
            status, own = recs[0]
            if status != "PASS":
                bad.append(f"invariant-deep: {name} {key[0]}{key[1]} is {status}")
            seen = own or s["counts"]
            if own and s["counts"] and own != s["counts"]:
                bad.append(f"invariant-deep: {name} {key[0]}{key[1]} counts {own} differ from the suite line {s['counts']}")
            elif seen is None:
                bad.append(f"invariant-deep: {name} {key[0]}{key[1]} has no observed runs and calls")
            elif seen != (runs, runs * depth, 0):
                bad.append(f"invariant-deep: {name} {key[0]}{key[1]} observed runs/calls/reverts {seen}, "
                           f"not ({runs}, {runs * depth}, 0)")
        for key in sorted(set(s["ids"]) - want):
            bad.append(f"invariant-deep: {name} has an unexpected invariant {key[0]}{key[1]}")
    for name in sorted(set(suites) - set(DEEP_SUITES)):
        bad.append(f"invariant-deep: unexpected suite {name}")
    return bad


def deep_summary(text):
    """One line for the README, read from the log by the same parser; 'see the log' when the log does not parse clean."""
    suites, bad = parse_deep(text)
    seen = {suites[n]["counts"] or next(iter(r[0][1] for r in suites[n]["ids"].values() if r and r[0][1]), None) for n in DEEP_SUITES if n in suites}
    if bad or len(seen) != 1 or None in seen or len(suites) != len(DEEP_SUITES):
        return "see the log"
    runs, calls, reverts = seen.pop()
    return f"{DEEP_COUNT * len(DEEP_SUITES)} distinct invariants (O1 to O7, R1 to R7) in {len(DEEP_SUITES)} suites, each observed at runs: {runs}, calls: {calls}, reverts: {reverts}"


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
        if not parts:
            continue
        if len(parts) != 2 or not re.fullmatch(r"-?\d+", parts[1]):
            bad.append("exit-codes.txt: malformed exit-code record")
        elif parts[0] in codes:
            bad.append(f"exit-codes.txt: duplicate stage {parts[0]}")
        elif parts[0] not in RUNS:
            bad.append(f"exit-codes.txt: unexpected stage {parts[0]}")
        else:
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

    # The deep campaigns: what was asked is in the patch printed at the top of the log, what ran is in the suite sections of the
    # log (either Forge output form, see parse_deep). Both router suites carry inline annotations that override the environment,
    # so the request alone proves nothing.
    deep = read("invariant-deep.txt") or ""
    want_runs = re.findall(r"^\+/// forge-config: default\.invariant\.runs = (\d+)\s*$", deep, re.M)
    want_depth = re.findall(r"^\+/// forge-config: default\.invariant\.depth = (\d+)\s*$", deep, re.M)
    if len(set(want_runs)) != 1 or len(set(want_depth)) != 1 or len(want_runs) < 2:
        bad.append("invariant-deep: no patch of the inline runs and depth annotations recorded in the log")
    elif int(want_runs[0]) < 512 or int(want_depth[0]) < 150:
        bad.append(f"invariant-deep: requested {want_runs[0]} runs of depth {want_depth[0]}, below 512 of 150")
    else:
        bad.extend(deep_problems(deep, int(want_runs[0]), int(want_depth[0])))
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
    if not isinstance(v, dict) or not v:
        bad.append("verifier.json: missing or not a JSON object")
    else:
        if v.get("ok") is not True:
            bad.append("verifier: ok is not true")
        def object_field(name):
            value = v.get(name, {})
            if not isinstance(value, dict):
                bad.append(f"verifier: {name} is not an object")
                return {}
            return value
        checks = object_field("checks")
        contracts = object_field("contracts")
        wiring = object_field("wiring")
        if LENS_CHECK not in checks:
            bad.append("verifier: the lens.credit check is absent")
        for k, val in checks.items():
            if val is not True:
                bad.append(f"verifier check false: {k}")
        pool_contract = contracts.get("pool", {})
        pool = pool_contract.get("address", "") if isinstance(pool_contract, dict) else ""
        lens = wiring.get("lens.credit")
        if not isinstance(pool, str) or not re.fullmatch(r"0x[0-9a-fA-F]{40}", pool) or not isinstance(lens, str) or lens.lower() != pool.lower():
            bad.append(f"verifier: lens.credit {lens!r} is not the verified pool {pool!r}")
        for role in ("pool", "lens", "router"):
            c = contracts.get(role)
            if not isinstance(c, dict) or c.get("match_strict") is not True:
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


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("out")
    ap.add_argument("--check", action="store_true", help="report the gate result without changing any file")
    args = ap.parse_args(argv)
    out = args.out
    bad = gate(out)
    path = os.path.join(out, "FAILED.txt")
    if bad:
        if not args.check:
            with open(path, "w") as f:
                f.write("The evidence run did not pass; no README.md or SHA256SUMS was written.\n" + "\n".join("- " + b for b in bad) + "\n")
        print("EVIDENCE GATE FAILED:\n" + "\n".join("- " + b for b in bad), file=sys.stderr)
        return 1
    if not args.check and os.path.exists(path):
        os.remove(path)
    print("evidence gate: all runs passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
