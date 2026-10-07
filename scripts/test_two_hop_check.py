"""Tests for two_hop_check.py: python3 -m unittest scripts/test_two_hop_check.py -v

The checks are pure functions over two snapshots, so each rule is tested with a synthetic
snapshot that breaks it; the selector table is compared with Foundry's own hashing when `cast`
is installed.
"""

import json
import os
import shutil
import subprocess
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import two_hop_check as t  # noqa: E402

U = t.USDC
A = "0x" + "a" * 40
B = "0x" + "b" * 40
C = "0x" + "c" * 40


def account(addr, **kw):
    base = {
        "address": addr, "granted": 0, "score": 0, "override": 0, "dues": 0, "lost": 0,
        "credit_committed": 0, "stake": 0, "stake_committed": 0, "defaulted": 0,
        "limit": 0, "available": 0, "free_credit": 0, "free_stake": 0,
    }
    base.update(kw)
    return base


def snap(a, b, edge, c=None):
    s = {
        "chain_id": 31337, "pool": "0x" + "1" * 40,
        "provider": {"provider": "0x" + "2" * 40, "fresh": True, "seconds_left": 3600},
        "a": a, "b": b,
        "edge_ab": {"backer": A, "borrower": B, "secured": edge[0], "unsecured": edge[1]},
    }
    if c is not None:
        s["c"] = c
    return s


def grant_pair(x):
    """A holds a 92 USDC issued line and backs B with x from it."""
    before = snap(
        account(A, granted=92 * U, score=92 * U // 100, override=92 * U // 100, limit=92 * U, available=92 * U, free_credit=92 * U),
        account(B), (0, 0), account(C),
    )
    after = snap(
        account(A, granted=92 * U, score=92 * U // 100, override=92 * U // 100, credit_committed=x, limit=92 * U - x, available=92 * U - x, free_credit=92 * U - x),
        account(B, limit=x, available=x), (0, x), account(C),
    )
    return before, after


def stake_pair(x):
    before = snap(account(A, stake=5 * U, free_stake=5 * U), account(B), (0, 0), account(C))
    after = snap(
        account(A, stake=5 * U, stake_committed=x, free_stake=5 * U - x),
        account(B, limit=x, available=x), (x, 0), account(C),
    )
    return before, after


def statuses(results):
    return [s for s, _ in results]


class Verify(unittest.TestCase):
    def test_grant_route_passes(self):
        before, after = grant_pair(2 * U)
        res = t.verify(before, after, 2 * U, "grant")
        self.assertNotIn("FAIL", statuses(res), res)

    def test_stake_route_passes(self):
        before, after = stake_pair(2 * U)
        res = t.verify(before, after, 2 * U, "stake")
        self.assertNotIn("FAIL", statuses(res), res)

    def test_wrong_route_label_fails(self):
        before, after = stake_pair(2 * U)
        self.assertIn("FAIL", statuses(t.verify(before, after, 2 * U, "grant")))

    def test_credit_created_is_caught(self):
        """B's limit rises by more than A's capacity fell: inflation."""
        before, after = grant_pair(2 * U)
        after["b"]["limit"] = 3 * U
        res = t.verify(before, after, 2 * U, "grant")
        failed = [text for s, text in res if s == "FAIL"]
        self.assertTrue(any(text.startswith("2.") for text in failed), res)
        self.assertTrue(any(text.startswith("3.") for text in failed), res)

    def test_backer_capacity_not_reduced_is_caught(self):
        before, after = grant_pair(2 * U)
        after["a"]["free_credit"] = before["a"]["free_credit"]
        after["a"]["limit"] = before["a"]["limit"]
        res = t.verify(before, after, 2 * U, "grant")
        self.assertTrue(any(s == "FAIL" and text.startswith("1.") for s, text in res), res)

    def test_partial_counting_fails_check_two_only_by_shortfall(self):
        before, after = grant_pair(2 * U)
        after["b"]["limit"] = U
        res = t.verify(before, after, 2 * U, "grant")
        self.assertTrue(any(s == "FAIL" and text.startswith("2.") for s, text in res), res)

    def test_received_backing_becoming_free_capacity_is_caught(self):
        before, after = grant_pair(2 * U)
        after["b"]["free_credit"] = 2 * U
        res = t.verify(before, after, 2 * U, "grant")
        self.assertTrue(any(s == "FAIL" and text.startswith("6.") for s, text in res), res)

    def test_second_hop_flow_is_caught(self):
        before, after = grant_pair(2 * U)
        after["c"]["limit"] = U
        res = t.verify(before, after, 2 * U, "grant")
        self.assertTrue(any(s == "FAIL" and text.startswith("7.") for s, text in res), res)

    def test_granted_credit_change_is_caught(self):
        before, after = grant_pair(2 * U)
        after["a"]["granted"] += 1
        res = t.verify(before, after, 2 * U, "grant")
        self.assertTrue(any(s == "FAIL" and text.startswith("4.") for s, text in res), res)

    def test_open_loan_on_backer_allows_larger_fall_but_not_smaller(self):
        before, after = grant_pair(2 * U)
        before["a"]["available"] = before["a"]["limit"] - U  # A owes 1 USDC
        after["a"]["free_credit"] -= U  # fell by 3
        self.assertNotIn("FAIL", [s for s, text in t.verify(before, after, 2 * U, "grant") if text.startswith("1.")])
        after["a"]["free_credit"] = before["a"]["free_credit"] - U // 2  # fell by 0.5
        self.assertIn("FAIL", [s for s, text in t.verify(before, after, 2 * U, "grant") if text.startswith("1.")])

    def test_stale_provider_fails_only_a_provider_backed_grant(self):
        before, after = grant_pair(2 * U)
        for s in (before, after):
            s["provider"]["fresh"] = False
            s["a"]["override"] = 0
            s["a"]["score"] = 0
        self.assertIn("FAIL", statuses(t.verify(before, after, 2 * U, "grant")))
        sb, sa = stake_pair(2 * U)
        for s in (sb, sa):
            s["provider"]["fresh"] = False
        self.assertNotIn("FAIL", statuses(t.verify(sb, sa, 2 * U, "stake")))

    def test_fresh_provider_backed_grant_names_the_clock(self):
        before, after = grant_pair(2 * U)
        for s in (before, after):
            s["a"]["override"] = 0  # the line comes from the provider's score
        notes = [text for s, text in t.verify(before, after, 2 * U, "grant") if s == "NOTE"]
        self.assertTrue(any("3600 s" in text for text in notes), notes)

    def test_snapshots_from_different_pools_are_refused(self):
        before, after = grant_pair(2 * U)
        after["pool"] = "0x" + "9" * 40
        res = t.verify(before, after, 2 * U, "grant")
        self.assertEqual(statuses(res), ["FAIL"])


class Controls(unittest.TestCase):
    def setUp(self):
        self.reads = {}
        self._orig = (t.read_account, t.read_edge, t.simulate_revert)

    def tearDown(self):
        t.read_account, t.read_edge, t.simulate_revert = self._orig

    def run_controls(self, acct_a, acct_b, verdicts, stage="after"):
        t.read_account = lambda url, pool, who: acct_a if who == A else acct_b
        t.read_edge = lambda url, pool, a, b: {"secured": 0, "unsecured": 0}
        calls = []

        def fake(url, pool, frm, to, amount):
            calls.append((frm, to, amount))
            return verdicts.pop(0)

        t.simulate_revert = fake
        return t.controls("rpc", "pool", A, B, C, stage), calls

    def test_both_controls_pass_on_insufficient_credit(self):
        verdicts = [("revert", t.INSUFFICIENT_CREDIT), ("revert", t.INSUFFICIENT_CREDIT)]
        res, calls = self.run_controls(account(A, free_credit=90 * U), account(B, limit=2 * U), verdicts)
        self.assertEqual(statuses(res), ["PASS", "PASS"])
        self.assertEqual(calls[0], (B, C, U))
        self.assertEqual(calls[1], (A, B, 90 * U + 1))

    def test_a_succeeding_call_fails(self):
        res, _ = self.run_controls(account(A, free_credit=U), account(B, limit=2 * U), [("ok", None), ("revert", t.INSUFFICIENT_CREDIT)])
        self.assertEqual(statuses(res), ["FAIL", "PASS"])

    def test_a_revert_for_another_reason_fails(self):
        res, _ = self.run_controls(account(A, free_credit=U), account(B, limit=2 * U), [("revert", "0xdeadbeef"), ("revert", None)])
        self.assertEqual(statuses(res), ["FAIL", "FAIL"])

    def test_pass_on_control_not_applicable_when_b_holds_capacity(self):
        res, calls = self.run_controls(account(A, free_credit=U), account(B, limit=2 * U, free_credit=U), [("revert", t.INSUFFICIENT_CREDIT)])
        self.assertEqual(statuses(res), ["NOT APPLICABLE", "PASS"])
        self.assertEqual(len(calls), 1)

    def test_pass_on_control_not_applicable_before_the_backing(self):
        res, _ = self.run_controls(account(A, free_credit=U), account(B), [("revert", t.INSUFFICIENT_CREDIT)], stage="before")
        self.assertEqual(statuses(res), ["NOT APPLICABLE", "PASS"])

    def test_raise_control_never_asks_below_the_minimum_backing(self):
        _, calls = self.run_controls(account(A), account(B), [("revert", t.INSUFFICIENT_CREDIT)], stage="before")
        self.assertEqual(calls[-1][2], t.MIN_BACKING)


class Helpers(unittest.TestCase):
    def test_usdc_formatting(self):
        self.assertEqual(t.usdc(2 * U), "2 USDC")
        self.assertEqual(t.usdc(1_500_000), "1.5 USDC")
        self.assertEqual(t.usdc(0), "0 USDC")

    def test_parse_usdc(self):
        self.assertEqual(t.parse_usdc("2"), 2 * U)
        self.assertEqual(t.parse_usdc("1.234567"), 1_234_567)
        for bad in ("0", "-1", "1.2345678"):
            with self.assertRaises(Exception):
                t.parse_usdc(bad)

    def test_revert_selector_reads_error_data(self):
        self.assertEqual(t.revert_selector(t.RpcError("x", "0x8ac4bc73")), "0x8ac4bc73")
        self.assertEqual(t.revert_selector(t.RpcError("x", {"data": "0x8AC4BC73"})), "0x8ac4bc73")
        self.assertIsNone(t.revert_selector(t.RpcError("x", None)))

    def test_word_encoders(self):
        self.assertEqual(t.word_address("0x" + "AB" * 20), "0" * 24 + "ab" * 20)
        self.assertEqual(t.word_uint(255), "0" * 62 + "ff")
        with self.assertRaises(ValueError):
            t.word_address("0x1234")


@unittest.skipUnless(shutil.which("cast"), "cast (Foundry) is not installed")
class Selectors(unittest.TestCase):
    def test_selectors_match_the_signatures(self):
        for name, sig in t.SIGNATURES.items():
            want = subprocess.run(["cast", "sig", sig], capture_output=True, text=True, check=True).stdout.strip()
            have = t.INSUFFICIENT_CREDIT if name == "InsufficientCredit" else t.SEL[name]
            self.assertEqual(have, want, name)

    def test_every_selector_has_a_signature(self):
        self.assertEqual(set(t.SEL) | {"InsufficientCredit"}, set(t.SIGNATURES))


OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "packages", "foundry", "out")
PROVIDER_VIEWS = {"isFresh", "lastReportAt", "maxScoreAge", "epoch"}


def artifact(contract):
    path = os.path.join(OUT, contract + ".sol", contract + ".json")
    if not os.path.exists(path):
        return None
    with open(path) as f:
        return json.load(f)


@unittest.skipUnless(artifact("DecentralizedMicrocredit"), "run forge build first")
class CompiledAbi(unittest.TestCase):
    """The selectors must exist in the compiled contracts, so a renamed function fails here."""

    def test_pool_selectors_are_in_the_compiled_pool(self):
        ids = artifact("DecentralizedMicrocredit")["methodIdentifiers"]
        for name, sig in t.SIGNATURES.items():
            if name in PROVIDER_VIEWS or name == "InsufficientCredit":
                continue
            self.assertEqual("0x" + ids.get(sig, "missing"), t.SEL[name], sig)

    def test_provider_selectors_are_in_the_compiled_provider(self):
        ids = artifact("OracleScoreProvider")["methodIdentifiers"]
        for name in PROVIDER_VIEWS:
            self.assertEqual("0x" + ids.get(t.SIGNATURES[name], "missing"), t.SEL[name], name)

    def test_the_error_is_declared_by_the_pool(self):
        abi = artifact("DecentralizedMicrocredit")["abi"]
        names = {e["name"] for e in abi if e["type"] == "error"}
        self.assertIn("InsufficientCredit", names)


if __name__ == "__main__":
    unittest.main()
