#!/usr/bin/env python3
"""Assemble a reviewable evidence packet from the published logs of a run that was made elsewhere.

  candidate_package_run.py --src COPY --out evidence/DIR --tested-head SHA --parser-rev SHA --reeval-rev SHA --packaging-rev SHA \
      --run-by TEXT --input-ref TEXT --failed-ref TEXT [--source-index FILE] [--original-failed FILE] [--selection TEXT]

Why it exists: the clean run at 3efdb6f was made by Hermes and passed every stage, but the gate that judged it read only the Forge 1.5
output form and refused it (original FAILED.txt, kept at its publication). The designated reviewer chose that run as the evidence of
record and asked for the README and checksum manifest to be generated over a separate copy with the repaired parser, naming the tested
revision, the parser revision, the re-evaluation and the packaging revision apart. This script does exactly that and nothing more:

  1. checks every file in COPY/logs against the publisher's checksum index (--source-index), if given;
  2. copies COPY/logs byte for byte into OUT/logs (never the publisher's wrapper script, transcript or FAILED.txt);
  3. runs the gate on OUT and stops, leaving no README or checksums, unless it passes;
  4. renders OUT/README.md with candidate_evidence_readme.render (an intro that says whose run it is and why the original gate failed,
     a limits section, no claim that this script's author ran the logs) and writes OUT/SHA256SUMS.

The original failed result is not copied, rewritten or backdated: --original-failed is read only to print its sha256 in the README.
"""
import argparse, hashlib, os, shutil, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import candidate_evidence_gate as gate
import candidate_evidence_readme as readme


class PackageError(RuntimeError):
    pass


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def check_index(logs_dir, index_path):
    """Every logs/ entry of the publisher's index must match, and no log may be missing from it."""
    listed = {}
    with open(index_path) as f:
        for line in f:
            parts = line.split(None, 1)
            if len(parts) == 2:
                listed[parts[1].strip().lstrip("./")] = parts[0]
    have = sorted(os.listdir(logs_dir))
    for name in have:
        if name not in listed:
            raise PackageError(f"logs/{name} is not in the publisher's index")
        if sha256(os.path.join(logs_dir, name)) != listed[name]:
            raise PackageError(f"logs/{name} does not match the publisher's index")
    for name in listed:
        if name != "FAILED.txt" and name not in have:
            raise PackageError(f"the publisher's index lists logs/{name}, which is not in the copy")
    return len(have)


def intro_text(a):
    failed = f", sha256 `{a.failed_sha}`" if a.failed_sha else ""
    return (
        f"Tested revision (the code under test): `@HEAD@`. These logs are the original, unmodified output of one run of\n"
        f"`scripts/candidate_evidence.sh` at that revision, made by {a.run_by} and published at {a.input_ref}. That run's own gate\n"
        f"failed on the output format, not on a result (original `FAILED.txt`{failed}, kept at {a.failed_ref} and not rewritten here).\n"
        f"The gate was repaired afterwards (parser revision `{a.parser_rev}`), the published output was re-evaluated on a separate copy\n"
        f"(re-evaluation revision `{a.reeval_rev}`, `evidence/bootstrap-candidate-3efdb6f-gate-reevaluation/`), and this packet was assembled\n"
        f"from a separate copy of the published logs by `scripts/candidate_package_run.py` (packaging revision `{a.packaging_rev}`; this\n"
        f"directory is added by the commit after it). {a.selection}\n"
        f"The original gate result is not backdated: it failed, and the repaired gate passes the same logs. Nothing here is a public-chain\n"
        f"receipt: tests ran on a local EVM with synthetic time; fork runs and rehearsals ran on local Anvil forks of Base Sepolia with\n"
        f"Circle's USDC, every fork pinned to Base Sepolia block @FBLOCK@ (hash `@FHASH@`)."
    )


LIMITS = """## Limits of this packet

- One host, one run. Nobody else has reproduced it; the gate checks that the logs say what a pass says, not that the run was faithful beyond what they record. The designated reviewer's read-only inspection of the published evidence found the seven exit codes and summaries consistent; that is inspection, not execution.
- The local suite reports skipped tests: they are fork suites that need RPC settings the local stage does not set (`BASE_SEPOLIA_RPC_URL`, or `LIVE_RPC_URL` and `LIVE_POOL`). The router fork suites ran in their own stage, with 0 skipped.
- Local EVM and local forks only: no public-chain receipt, no audit, no outside reproduction.
- This packet is assembled for review. It is not an acceptance: full packet revalidation, overall acceptance and the public-chain HOLD remain with the designated reviewer, and no readiness is claimed."""

REPRODUCE = """To reproduce the run itself, check out the tested revision and run the script (needs forge, anvil, cast, python3 and https://sepolia.base.org):

```
git checkout @HEAD@
scripts/candidate_evidence.sh
```

To re-judge this packet, run `python3 scripts/candidate_evidence_gate.py` on a copy of this directory (the gate deletes `FAILED.txt` on success and writes it on failure, so never point it at the only copy), and `sha256sum -c SHA256SUMS` from this directory."""


def package(a):
    logs_src = os.path.join(a.src, "logs")
    if not os.path.isdir(logs_src):
        raise PackageError(f"{logs_src} is not a directory")
    if os.path.exists(a.out):
        raise PackageError(f"{a.out} already exists; the packet is written once")
    if a.source_index:
        check_index(logs_src, a.source_index)
    a.failed_sha = sha256(a.original_failed) if a.original_failed else None
    shutil.copytree(logs_src, os.path.join(a.out, "logs"))
    try:
        problems = gate.gate(a.out)
        if problems:
            raise PackageError("the gate refused the copied logs:\n" + "\n".join("- " + p for p in problems))
        md = readme.render(a.out, a.tested_head, intro=intro_text(a), limits=LIMITS, reproduce=REPRODUCE)
    except Exception:
        shutil.rmtree(a.out, ignore_errors=True)  # no partial packet, no README, no checksums
        raise
    with open(os.path.join(a.out, "README.md"), "w") as f:
        f.write(md)
    rows = []
    for root, _, files in os.walk(a.out):
        for name in files:
            full = os.path.join(root, name)
            rel = "./" + os.path.relpath(full, a.out).replace(os.sep, "/")
            if rel != "./SHA256SUMS":
                rows.append((rel, sha256(full)))
    with open(os.path.join(a.out, "SHA256SUMS"), "w") as f:
        for rel, digest in sorted(rows):
            f.write(f"{digest}  {rel}\n")
    return len(rows)


def main():
    ap = argparse.ArgumentParser()
    for name in ("src", "out", "tested-head", "parser-rev", "reeval-rev", "packaging-rev", "run-by", "input-ref", "failed-ref"):
        ap.add_argument("--" + name, required=True)
    ap.add_argument("--source-index")
    ap.add_argument("--original-failed")
    ap.add_argument("--selection", default="")
    a = ap.parse_args()
    for k in ("tested_head", "parser_rev", "reeval_rev", "packaging_rev"):
        if not (len(getattr(a, k)) in (7, 40) and all(c in "0123456789abcdef" for c in getattr(a, k))):
            print(f"candidate_package_run: --{k.replace('_', '-')} is not a git revision", file=sys.stderr)
            return 1
    try:
        n = package(a)
    except (PackageError, OSError) as e:
        print(f"candidate_package_run: {e}", file=sys.stderr)
        return 1
    print(f"packet written to {a.out} ({n} files hashed)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
