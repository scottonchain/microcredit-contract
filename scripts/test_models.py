#!/usr/bin/env python3
"""Run every maintained economic model's tests in a separate interpreter.

The studies deliberately keep separate model assumptions; several use a module
named model.py. Process isolation prevents one study's imports contaminating the
next. This runner does not regenerate published results or access the network.
"""
import argparse
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
SUITES = ("credit_risk", "issuer_policy", "liquidity", "sybil_sim")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("suites", nargs="*", choices=SUITES)
    args = parser.parse_args(argv)
    failed = []
    for suite in args.suites or SUITES:
        print(f"\n=== {suite} ===", flush=True)
        result = subprocess.run(
            [sys.executable, "-B", "-m", "unittest", "discover", "-s", str(ROOT / "analysis" / suite), "-p", "test_*.py"],
            cwd=ROOT,
        )
        if result.returncode:
            failed.append(suite)
    if failed:
        print("Model suites failed: " + ", ".join(failed), file=sys.stderr)
        return 1
    print("All requested model suites passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
