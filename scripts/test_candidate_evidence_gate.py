import json, os, tempfile, unittest
import candidate_evidence_gate as g

POOL = "0x" + "11" * 20
GOOD = {
    "exit-codes.txt": "".join(f"{n} 0\n" for n in g.RUNS),
    "forge-test-local.txt": "Ran 30 test suites in 18s: 329 tests passed, 0 failed, 14 skipped (343 total tests)\n",
    "forge-test-fork-routers.txt": "Ran 2 test suites in 20s: 78 tests passed, 0 failed, 0 skipped (78 total tests)\n",
    "invariant-deep.txt": "Ran 2 test suites in 7s: 14 tests passed, 0 failed, 0 skipped (14 total tests)\n",
    "mutants.txt": "pool originator gate inverted: KILLED by 114 test(s)\n18 mutants, 0 survived or did not compile\n",
    "python-tests.txt": "..........\n----------------------------------------------------------------------\nRan 55 tests in 0.1s\n\nOK\n",
    "rehearsal-normal.txt": "- replay refused\nREHEARSAL OK\n",
    "rehearsal-with-default.txt": "- sync attributed the lot\nREHEARSAL OK (with default path)\n",
    "toolchain.txt": "forge Version: 1.5.1-stable\n",
    "build-sizes.txt": "| DecentralizedMicrocredit | 24,439 |\n",
}


def verifier(**over):
    v = {"ok": True, "rpc_chain_id": 84532,
         "contracts": {r: {"address": POOL if r == "pool" else "0x" + "22" * 20, "match_strict": True} for r in ("pool", "lens", "router")},
         "wiring": {"lens.credit": POOL}, "checks": {g.LENS_CHECK: True, "router.pool == pool": True}}
    v.update(over)
    return v


class GateTest(unittest.TestCase):
    def packet(self, files=None, ver=None):
        d = tempfile.mkdtemp()
        os.makedirs(os.path.join(d, "logs"))
        for n, t in {**GOOD, **(files or {})}.items():
            if t is not None:
                open(os.path.join(d, "logs", n), "w").write(t)
        open(os.path.join(d, "logs", "verifier.json"), "w").write(json.dumps(ver if ver is not None else verifier()))
        return d

    def test_a_clean_packet_passes(self):
        self.assertEqual(g.gate(self.packet()), [])

    def test_a_nonzero_exit_code_fails_even_when_the_summary_reads_green(self):
        codes = GOOD["exit-codes.txt"].replace("mutants 0", "mutants 1")
        self.assertTrue(any("mutants: exited 1" in b for b in g.gate(self.packet({"exit-codes.txt": codes}))))

    def test_a_missing_exit_code_fails(self):
        codes = "".join(f"{n} 0\n" for n in g.RUNS if n != "rehearsal-normal")
        self.assertTrue(any("rehearsal-normal: no exit code" in b for b in g.gate(self.packet({"exit-codes.txt": codes}))))

    def test_failed_or_skipped_tests_fail(self):
        for name, text, word in (
            ("forge-test-local.txt", "329 tests passed, 1 failed, 14 skipped", "1 failed"),
            ("forge-test-fork-routers.txt", "78 tests passed, 0 failed, 3 skipped", "3 skipped"),
            ("invariant-deep.txt", "0 tests passed, 0 failed, 0 skipped", "no test passed"),
            ("forge-test-local.txt", "no summary at all", "no 'N tests passed"),
        ):
            self.assertTrue(any(word in b for b in g.gate(self.packet({name: text}))), (name, word))

    def test_local_skips_are_allowed_because_the_fork_suites_are_gated_off(self):
        self.assertEqual(g.gate(self.packet({"forge-test-local.txt": "329 tests passed, 0 failed, 14 skipped"})), [])

    def test_a_surviving_mutant_or_a_truncated_log_fails(self):
        self.assertTrue(g.gate(self.packet({"mutants.txt": "18 mutants, 1 survived or did not compile\n"})))
        self.assertTrue(g.gate(self.packet({"mutants.txt": "pool originator gate inverted: KILLED by 114 test(s)\n"})))
        self.assertTrue(g.gate(self.packet({"mutants.txt": ""})))

    def test_a_rehearsal_that_did_not_finish_fails(self):
        self.assertTrue(g.gate(self.packet({"rehearsal-normal.txt": "- replay refused\nTraceback ...\n"})))
        self.assertTrue(g.gate(self.packet({"rehearsal-with-default.txt": "REHEARSAL OK\n"})))

    def test_python_test_failures_fail(self):
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

    def test_main_writes_failed_txt_and_nothing_else_on_failure_and_clears_it_on_success(self):
        d = self.packet({"mutants.txt": "18 mutants, 2 survived or did not compile\n"})
        self.assertEqual(g.sys.argv.__class__, list)
        g.sys.argv = ["gate", d]
        self.assertEqual(g.main(), 1)
        self.assertTrue(os.path.exists(os.path.join(d, "FAILED.txt")))
        self.assertFalse(os.path.exists(os.path.join(d, "README.md")))
        open(os.path.join(d, "logs", "mutants.txt"), "w").write(GOOD["mutants.txt"])
        self.assertEqual(g.main(), 0)
        self.assertFalse(os.path.exists(os.path.join(d, "FAILED.txt")))


if __name__ == "__main__":
    unittest.main()
