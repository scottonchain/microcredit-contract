#!/usr/bin/env python3
"""Mutation check of the bootstrap candidate: plant one deliberate bug at a time and require the local suite to fail.

  scripts/candidate_mutants.py [--only SUBSTRING]      (run from a clean checkout; restores every file it touches)

Each mutant is a literal replacement in one contract; the run executes `forge test` in packages/foundry and the mutant
is KILLED when at least one test fails. A mutant that SURVIVES is a missing test and the script exits non-zero.
"""
import os, subprocess, sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "packages", "foundry")
ORD, BASE, POOL = "contracts/BootstrapOrderRouter.sol", "contracts/TransitiveStakeRouter.sol", "contracts/DecentralizedMicrocredit.sol"
SCOPE = "(p.rootEdge.borrower != address(0) && p.rootEdge.borrower != borrower)"
MUTANTS = [
    # order router: ledgers and settlement
    ("settle forgets to debit escrow", ORD, "        totalEscrowHeld -= o.price;\n        if (debt != 0) {", "        if (debt != 0) {"),
    ("refund forgets to debit escrow", ORD, "        o.state = State.Refunded;\n        totalEscrowHeld -= o.price;", "        o.state = State.Refunded;"),
    ("settle skips returning the lot", ORD, "        _sync(worker); // the loan is closed: the roots' lot comes back now, not when somebody remembers", ""),
    ("fund counts escrow twice", ORD, "totalEscrowHeld += price;", "totalEscrowHeld += price + 1;"),
    # shared root-to-mid edge
    ("root edge key scoped to the borrower again", BASE, "_useConsent(edgeKey(root, mid, address(0)), p.rootEdge", "_useConsent(edgeKey(root, mid, borrower), p.rootEdge"),
    ("wildcard scope not accepted", BASE, SCOPE, "p.rootEdge.borrower != borrower"),
    ("exact scope ignored", BASE, SCOPE, "false"),
    ("router accepts a pool that does not name it", BASE, "if (pool_.ORIGINATOR() != address(this)) revert NotManager();", ""),
    # the officer gate
    ("no officer gate in originateOrder", ORD, "officer == address(0) || ap.officerEpoch != officerEpoch || ap.policyVersion != policyVersion\n                    || ap.expiry < block.timestamp\n            ) revert NoApproval();", "false) revert NoApproval();"),
    ("approval amount ceiling ignored", ORD, "if (req.amount > ap.maxAmount) revert ApprovalTooSmall();", ""),
    ("officer rotation keeps the epoch", ORD, "        policyVersion = newPolicyVersion;\n        unchecked {\n            ++officerEpoch;\n        }", "        policyVersion = newPolicyVersion;"),
    ("approval not bound to the intent hash", ORD, "|| a.intentHash != o.intentHash ||", "||"),
    ("anyone can name the officer", ORD, "function setOfficer(address newOfficer, uint256 newPolicyVersion) external onlyOfficerAdmin {", "function setOfficer(address newOfficer, uint256 newPolicyVersion) external {"),
    ("anyone can revoke the officer", ORD, "if (msg.sender != officerAdmin && msg.sender != officer) revert NotOfficerAdmin();", ""),
    ("stale epoch accepted when recording an approval", ORD, "|| a.officerEpoch != officerEpoch\n                ||", "||"),
    # the pool's originator gate
    ("pool originator gate removed", POOL, "        require(ORIGINATOR == address(0) || msg.sender == ORIGINATOR, NotManager());\n", ""),
    ("pool originator gate inverted", POOL, "ORIGINATOR == address(0) || msg.sender == ORIGINATOR", "ORIGINATOR == address(0) || msg.sender != ORIGINATOR"),
    ("pool treats a zero originator as closed", POOL, "ORIGINATOR == address(0) || msg.sender == ORIGINATOR", "msg.sender == ORIGINATOR"),
]


def suite():
    r = subprocess.run(["forge", "test"], cwd=ROOT, capture_output=True, text=True)
    text = r.stdout + r.stderr
    if "Compiler run failed" in text:
        return None, text[-400:]
    return [l.split("] ")[-1].split("(")[0] for l in text.splitlines() if l.startswith("[FAIL")], ""


def main():
    only = sys.argv[sys.argv.index("--only") + 1] if "--only" in sys.argv else ""
    base, _ = suite()
    if base:
        raise SystemExit(f"the unmutated suite already fails: {base[:3]}")
    survived = 0
    for label, rel, old, new in MUTANTS:
        if only not in label:
            continue
        path = os.path.join(ROOT, rel)
        original = open(path).read()
        if old not in original:
            raise SystemExit(f"mutant '{label}': the original text is not in {rel}")
        try:
            open(path, "w").write(original.replace(old, new, 1))
            failed, err = suite()
        finally:
            open(path, "w").write(original)
        if failed is None:
            print(f"{label}: DID NOT COMPILE {err}")
            survived += 1
        elif failed:
            print(f"{label}: KILLED by {len(failed)} test(s), e.g. {failed[0]}")
        else:
            print(f"{label}: SURVIVED")
            survived += 1
    print(f"{len(MUTANTS) if not only else 'selected'} mutants, {survived} survived or did not compile")
    sys.exit(1 if survived else 0)


if __name__ == "__main__":
    main()
