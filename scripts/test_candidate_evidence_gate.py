import contextlib, io, json, os, tempfile, unittest
import candidate_evidence_gate as g

POOL = "0x" + "11" * 20
GOOD = {
    "exit-codes.txt": "".join(f"{n} 0\n" for n in g.RUNS),
    "forge-test-local.txt": "Ran 30 test suites in 18s: 329 tests passed, 0 failed, 14 skipped (343 total tests)\n",
    "forge-test-fork-routers.txt": "Ran 2 test suites in 20s: 78 tests passed, 0 failed, 0 skipped (78 total tests)\n",
    "invariant-deep.txt": "== patch applied ==\n+/// forge-config: default.invariant.runs = 512\n+/// forge-config: default.invariant.depth = 150\n"
                          "+/// forge-config: default.invariant.runs = 512\n+/// forge-config: default.invariant.depth = 150\n"
                          + "".join(f"[PASS] invariant_{n}() (runs: 512, calls: 76800, reverts: 0)\n" for n in range(14))
                          + "Ran 2 test suites in 120s: 14 tests passed, 0 failed, 0 skipped (14 total tests)\n",
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

    def test_failed_or_skipped_tests_fail(self):
        for name, text, word in (
            ("forge-test-local.txt", "329 tests passed, 1 failed, 14 skipped", "1 failed"),
            ("forge-test-fork-routers.txt", "78 tests passed, 0 failed, 3 skipped", "3 skipped"),
            ("invariant-deep.txt", "0 tests passed, 0 failed, 0 skipped", "no test passed"),
            ("forge-test-local.txt", "no summary at all", "no 'N tests passed"),
        ):
            self.assertTrue(any(word in b for b in g.gate(self.packet({name: text}))), (name, word))

    def test_the_deep_campaign_is_judged_by_what_ran_not_by_what_was_requested(self):
        # Codex, PR 28 comment 6074015618: the environment variables were overridden by inline annotations; 64 runs / 5120 calls
        base = GOOD["invariant-deep.txt"]
        env_only = "".join(f"[PASS] invariant_{n}() (runs: 64, calls: 5120, reverts: 0)\n" for n in range(14))
        cases = {
            "env variables only, no patch recorded": ("Ran 2 test suites: 14 tests passed, 0 failed, 0 skipped\n" + env_only, "no patch"),
            "patch asks 512x150 but 64 runs happened": (base.split("[PASS]")[0] + env_only + "14 tests passed, 0 failed, 0 skipped\n", "not all at runs"),
            "calls below runs times depth": (base.replace("calls: 76800", "calls: 5120"), "not all at runs"),
            "too few invariants": (base.replace("[PASS] invariant_13", "[SKIP] invariant_13"), "13 PASS lines"),
            "shallow request": (base.replace("runs = 512", "runs = 64"), "below 512"),
        }
        for label, (text, word) in cases.items():
            self.assertTrue(any(word in b for b in g.gate(self.packet({"invariant-deep.txt": text}))), label)

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
