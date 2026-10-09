import contextlib, io, json, os, tempfile, unittest
import candidate_evidence_gate as g

HERE = os.path.dirname(os.path.abspath(__file__))


def fixture(*parts):
    with open(os.path.join(HERE, *parts)) as f:
        return f.read()


# Real logs of the two router invariant suites. Forge 1.8.4 (Hermes) prints each campaign as one test with the counts on a suite
# line: FORGE18_DEEP is its unmodified deep run at 3efdb6f (512 x 150, the log the first gate could not read) and FORGE18_REAL its
# earlier run at the suites' own 64 x 80 (2986e23 supplement). Forge 1.5.1 prints one line per invariant: FORGE15_DEEP is the
# stored 512 x 150 run under evidence/, behind a patch header like the one candidate_deep_invariants.sh prints.
PATCH = "== patch applied ==\n" + "+/// forge-config: default.invariant.runs = 512\n+/// forge-config: default.invariant.depth = 150\n" * 2
FORGE18_REAL = fixture("fixtures", "forge184-invariant-deep-2986e23-hermes.txt")
FORGE18_DEEP = fixture("fixtures", "forge184-invariant-deep-512x150-3efdb6f-hermes.txt")
FORGE15_DEEP = PATCH + fixture("..", "evidence", "deep-invariants-512x150-00a04e7.txt")

POOL = "0x" + "11" * 20
GOOD = {
    "exit-codes.txt": "".join(f"{n} 0\n" for n in g.RUNS),
    "forge-test-local.txt": "Ran 30 test suites in 18s: 329 tests passed, 0 failed, 14 skipped (343 total tests)\n",
    "forge-test-fork-routers.txt": "Ran 2 test suites in 20s: 78 tests passed, 0 failed, 0 skipped (78 total tests)\n",
    "invariant-deep.txt": FORGE18_DEEP,
    "tree-status.txt": "",
    "mutants.txt": "pool originator gate inverted: KILLED by 114 test(s)\n18 mutants, 0 survived or did not compile\n",
    "python-tests.txt": "..........\n----------------------------------------------------------------------\nRan 55 tests in 0.1s\n\nOK\n",
    "rehearsal-normal.txt": "- replay refused\nREHEARSAL OK\n",
    "rehearsal-with-default.txt": "- sync attributed the lot\nREHEARSAL OK (with default path)\n",
    "toolchain.txt": "forge Version: 1.5.1-stable\n",
    "build-sizes.txt": "| DecentralizedMicrocredit | 24,439 |\n",
    "fork-block.txt": "41234567 0x" + "ab" * 32 + "\n",
}


def verifier(**over):
    v = {"ok": True, "rpc_chain_id": 84532,
         "contracts": {r: {"address": POOL if r == "pool" else "0x" + "22" * 20, "match_strict": True,
                           "masked_nometa_sha256_build": "ab" * 32, "masked_nometa_sha256_onchain": "ab" * 32} for r in ("pool", "lens", "router")},
         "wiring": {"lens.credit": POOL}, "checks": {g.LENS_CHECK: True, "router.pool == pool": True}}
    v.update(over)
    return v


class GateTest(unittest.TestCase):
    def packet(self, files=None, ver=None):
        d = tempfile.mkdtemp()
        os.makedirs(os.path.join(d, "logs"))
        for n, t in {**GOOD, **(files or {})}.items():
            if t is not None:
                self.write(d, n, t)
        self.write(d, "verifier.json", json.dumps(ver if ver is not None else verifier()))
        return d

    @staticmethod
    def write(d, name, text):
        with open(os.path.join(d, "logs", name), "w") as f:
            f.write(text)

    def test_a_clean_packet_passes(self):
        self.assertEqual(g.gate(self.packet()), [])

    def test_a_nonzero_exit_code_fails_even_when_the_summary_reads_green(self):
        codes = GOOD["exit-codes.txt"].replace("mutants 0", "mutants 1")
        self.assertTrue(any("mutants: exited 1" in b for b in g.gate(self.packet({"exit-codes.txt": codes}))))

    def test_a_missing_exit_code_fails(self):
        codes = "".join(f"{n} 0\n" for n in g.RUNS if n != "rehearsal-normal")
        self.assertTrue(any("rehearsal-normal: no exit code" in b for b in g.gate(self.packet({"exit-codes.txt": codes}))))

    def test_duplicate_or_malformed_exit_codes_cannot_hide_a_failure(self):
        for extra in ("mutants 0\n", "mutants ---1\n", "unexpected 0\n", "bad record with extras\n"):
            codes = GOOD["exit-codes.txt"].replace("mutants 0", "mutants 1") + extra
            problems = g.gate(self.packet({"exit-codes.txt": codes}))
            self.assertTrue(any("mutants: exited 1" in p for p in problems))
            self.assertTrue(any("exit-codes.txt:" in p for p in problems))

    def test_two_forge_summaries_are_not_one_run(self):
        text = "4 tests passed, 1 failed, 0 skipped\n4 tests passed, 0 failed, 0 skipped\n"
        self.assertTrue(g.gate(self.packet({"forge-test-local.txt": text})))

    def test_failed_or_skipped_tests_fail(self):
        for name, text, word in (
            ("forge-test-local.txt", "329 tests passed, 1 failed, 14 skipped", "1 failed"),
            ("forge-test-fork-routers.txt", "78 tests passed, 0 failed, 3 skipped", "3 skipped"),
            ("invariant-deep.txt", "0 tests passed, 0 failed, 0 skipped", "no test passed"),
            ("forge-test-local.txt", "no summary at all", "no 'N tests passed"),
        ):
            self.assertTrue(any(word in b for b in g.gate(self.packet({name: text}))), (name, word))

    def deep(self, text):
        return [b for b in g.gate(self.packet({"invariant-deep.txt": text})) if b.startswith("invariant-deep")]

    def test_both_real_forge_output_forms_pass_and_the_readme_line_comes_from_the_same_parser(self):
        for label, text, tail in (("forge 1.8", FORGE18_DEEP, "reverts: 0"), ("forge 1.5", FORGE15_DEEP, "reverts: 0")):
            self.assertEqual(self.deep(text), [], label)
            line = g.deep_summary(text)
            self.assertIn("14 distinct invariants (O1 to O7, R1 to R7) in 2 suites", line, label)
            self.assertIn("runs: 512, calls: 76800", line, label)
        self.assertEqual(g.deep_summary("nothing parseable"), "see the log")

    def test_the_deep_campaign_is_judged_by_what_ran_not_by_what_was_requested(self):
        # Codex, PR 28 comment 6074015618: the environment variables were overridden by inline annotations; 64 runs / 5120 calls
        for label, text, word in (
            ("env variables only, no patch recorded", FORGE18_REAL, "no patch"),
            ("patch asks 512x150 but the real 64x80 log ran", PATCH + FORGE18_REAL, "observed runs/calls/reverts (64, 5120, 0)"),
            ("calls below runs times depth", FORGE18_DEEP.replace("calls: 76800", "calls: 5120"), "(512, 5120, 0)"),
            ("shallow request", FORGE18_DEEP.replace("runs = 512", "runs = 64"), "below 512"),
            ("reverts under fail-on-revert", FORGE18_DEEP.replace("calls: 76800, reverts: 0", "calls: 76800, reverts: 3", 1), "(512, 76800, 3)"),
        ):
            self.assertTrue(any(word in b for b in self.deep(text)), (label, self.deep(text)))

    def test_forge_18_counts_must_exist_and_belong_to_their_own_suite(self):
        first = "BootstrapOrderRouterInvariantTest invariants (runs: 512, calls: 76800, reverts: 0)"
        second = "TransitiveStakeRouterInvariantTest invariants (runs: 512, calls: 76800, reverts: 0)"
        self.assertIn(first, FORGE18_DEEP)
        no_counts = FORGE18_DEEP.replace(first, "").replace(second, "")
        swapped = FORGE18_DEEP.replace(first, "TransitiveStakeRouterInvariantTest invariants (runs: 512, calls: 76800, reverts: 0)", 1)
        for label, text, word in (
            ("no suite count line at all", no_counts, "no observed runs and calls"),
            ("one suite's count line missing", FORGE18_DEEP.replace(second, ""), "TransitiveStakeRouterInvariantTest R1 has no observed"),
            ("a count line naming the other suite", swapped, "counts for TransitiveStakeRouterInvariantTest inside the BootstrapOrderRouterInvariantTest"),
        ):
            self.assertTrue(any(word in b for b in self.deep(text)), (label, self.deep(text)))

    def test_a_count_of_arbitrary_pass_lines_is_not_enough(self):
        fourteen = PATCH + "".join(f"[PASS] invariant_{n}() (runs: 512, calls: 76800, reverts: 0)\n" for n in range(14)) + \
            "Ran 2 test suites in 120s: 14 tests passed, 0 failed, 0 skipped (14 total tests)\n"
        out = self.deep(fourteen)
        self.assertTrue(any("suite BootstrapOrderRouterInvariantTest is missing" in b for b in out), out)
        self.assertTrue(any("suite TransitiveStakeRouterInvariantTest is missing" in b for b in out), out)

    def test_every_named_invariant_must_appear_exactly_once_and_pass_in_either_form(self):
        for form, base in (("1.8", FORGE18_DEEP), ("1.5", FORGE15_DEEP)):
            o1 = [l for l in base.splitlines() if "invariant_O1_" in l and l.startswith("[PASS]")][0]
            o7 = [l for l in base.splitlines() if "invariant_O7_" in l and l.startswith("[PASS]")][0]
            r3 = [l for l in base.splitlines() if "invariant_R3_" in l and l.startswith("[PASS]")][0]
            cases = {
                "a duplicate replacing a required name": (base.replace(o7, o1), ("has 2 results for O1", "has 0 results for O7")),
                "a partial suite": (base.replace(o7 + "\n", ""), ("has 0 results for O7",)),
                "a failed invariant": (base.replace(r3, r3.replace("[PASS]", "[FAIL: assertion failed]", 1)), ("failed or skipped lines",)),
                "a skipped invariant": (base.replace(r3, r3.replace("[PASS]", "[SKIP]", 1)), ("failed or skipped lines",)),
                "an unexpected extra invariant": (base.replace(o7, o7 + "\n" + o7.replace("invariant_O7_", "invariant_O8_")), ("unexpected invariant O8",)),
                "a suite that did not report ok": (base.replace("Suite result: ok.", "Suite result: FAILED.", 1), ("no 'Suite result: ok'",)),
            }
            for label, (text, words) in cases.items():
                out = self.deep(text)
                for word in words:
                    self.assertTrue(any(word in b for b in out), (form, label, word, out))

    def test_a_missing_suite_or_a_log_with_only_one_suite_fails(self):
        half = FORGE18_DEEP.split("Ran 1 test for test/invariant/TransitiveStakeRouter")[0]
        out = self.deep(half + "Ran 1 test suites in 20s: 1 tests passed, 0 failed, 0 skipped (1 total tests)\n")
        self.assertTrue(any("suite TransitiveStakeRouterInvariantTest is missing" in b for b in out), out)

    def test_a_dirty_tree_after_the_runs_fails(self):
        self.assertTrue(any("tree-status" in b for b in g.gate(self.packet({"tree-status.txt": " M packages/foundry/test/x.sol\n"}))))
        self.assertTrue(any("tree-status" in b for b in g.gate(self.packet({"tree-status.txt": None}))))

    def test_local_skips_are_allowed_because_the_fork_suites_are_gated_off(self):
        self.assertEqual(g.gate(self.packet({"forge-test-local.txt": "329 tests passed, 0 failed, 14 skipped"})), [])

    def test_a_surviving_mutant_or_a_truncated_log_fails(self):
        self.assertTrue(g.gate(self.packet({"mutants.txt": "18 mutants, 1 survived or did not compile\n"})))
        self.assertTrue(g.gate(self.packet({"mutants.txt": "pool originator gate inverted: KILLED by 114 test(s)\n"})))
        self.assertTrue(g.gate(self.packet({"mutants.txt": ""})))

    def test_a_rehearsal_that_did_not_finish_fails(self):
        self.assertTrue(g.gate(self.packet({"rehearsal-normal.txt": "- replay refused\nTraceback ...\n"})))
        self.assertTrue(g.gate(self.packet({"rehearsal-with-default.txt": "REHEARSAL OK\n"})))

    def test_harmless_output_after_a_passing_unittest_summary_does_not_fail_the_suite(self):
        # Codex review 5463115207: the suite includes the gate's own tests, which print after the summary of an earlier module
        log = "Ran 55 tests in 0.1s\n\nOK\nEVIDENCE GATE FAILED:\n- mutants: exited 1\nResourceWarning: unclosed file\n"
        self.assertEqual(g.gate(self.packet({"python-tests.txt": log})), [])
        self.assertEqual(g.gate(self.packet({"python-tests.txt": "..\nRan 3 tests in 0.1s\n\nOK\n\n"})), [])

    def test_python_test_failures_fail(self):
        self.assertTrue(g.gate(self.packet({"python-tests.txt": "Ran 55 tests in 0.1s\n\nNOT OK\n"})))
        self.assertTrue(g.gate(self.packet({"python-tests.txt": "OK\nRan 0 tests in 0.0s\n"})))
        self.assertTrue(g.gate(self.packet({"python-tests.txt": "Ran 55 tests in 0.1s\n\nFAILED (failures=1)\n"})))
        self.assertTrue(g.gate(self.packet({"python-tests.txt": "ERROR: test_x\nRan 3 tests in 0.1s\n\nOK\n"})))

    def test_the_verifier_must_be_ok_strict_and_link_the_lens_to_the_verified_pool(self):
        self.assertTrue(g.gate(self.packet(ver=verifier(ok=False))))
        self.assertTrue(any("lens.credit" in b for b in g.gate(self.packet(ver=verifier(wiring={"lens.credit": "0x" + "99" * 20})))))
        self.assertTrue(any("lens.credit" in b for b in g.gate(self.packet(ver=verifier(wiring={"lens.credit": None})))))
        self.assertTrue(any("absent" in b for b in g.gate(self.packet(ver=verifier(checks={"router.pool == pool": True})))))
        self.assertTrue(g.gate(self.packet(ver=verifier(checks={g.LENS_CHECK: False}))))
        self.assertTrue(g.gate(self.packet(ver=verifier(rpc_chain_id=31337))))
        weak = verifier()
        weak["contracts"]["router"]["match_strict"] = False
        self.assertTrue(any("strict" in b for b in g.gate(self.packet(ver=weak))))
        odd = verifier()
        odd["contracts"]["lens"]["masked_nometa_sha256_onchain"] = "cd" * 32
        self.assertTrue(any("metadata-free" in b for b in g.gate(self.packet(ver=odd))))
        gone = verifier()
        del gone["contracts"]["pool"]["masked_nometa_sha256_build"]
        self.assertTrue(any("metadata-free" in b for b in g.gate(self.packet(ver=gone))))

    def test_malformed_verifier_shapes_return_problems_instead_of_crashing(self):
        for value in (True, [1], "ok"):
            self.assertTrue(g.gate(self.packet(ver=value)))
        for field in ("contracts", "checks", "wiring"):
            self.assertTrue(g.gate(self.packet(ver=verifier(**{field: None}))))
        self.assertTrue(g.gate(self.packet(ver=verifier(contracts={"pool": 1}))))

    def test_read_only_check_preserves_the_original_gate_record(self):
        d = self.packet()
        path = os.path.join(d, "FAILED.txt")
        with open(path, "w") as f:
            f.write("original outcome\n")
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(g.main([d, "--check"]), 0)
            self.write(d, "mutants.txt", "failed")
            self.assertEqual(g.main([d, "--check"]), 1)
        with open(path) as f:
            self.assertEqual(f.read(), "original outcome\n")

    def test_the_pinned_fork_block_must_be_recorded(self):
        for text in ("", "41234567\n", "0 0x" + "ab" * 32, "41234567 nothex"):
            self.assertTrue(any("fork-block" in b for b in g.gate(self.packet({"fork-block.txt": text}))), text)

    def test_main_writes_failed_txt_and_nothing_else_on_failure_and_clears_it_on_success(self):
        d = self.packet({"mutants.txt": "18 mutants, 2 survived or did not compile\n"})
        argv, self.saved = g.sys.argv, g.sys.argv
        self.addCleanup(setattr, g.sys, "argv", argv)
        g.sys.argv = ["gate", d]
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):  # the gate's messages are not test output
            self.assertEqual(g.main(), 1)
            self.assertTrue(os.path.exists(os.path.join(d, "FAILED.txt")))
            self.assertFalse(os.path.exists(os.path.join(d, "README.md")))
            self.write(d, "mutants.txt", GOOD["mutants.txt"])
            self.assertEqual(g.main(), 0)
        self.assertFalse(os.path.exists(os.path.join(d, "FAILED.txt")))


if __name__ == "__main__":
    unittest.main()
