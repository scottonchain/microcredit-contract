import argparse, contextlib, hashlib, io, json, os, shutil, tempfile, unittest
import candidate_evidence_gate as gate
import candidate_evidence_readme as readme
import candidate_package_run as pk
import test_candidate_evidence_gate as tg

REV = "3" * 40


def read(path):
    with open(path) as f:
        return f.read()


def sha(path):
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


class PackageRunTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.src = os.path.join(self.tmp, "src")
        os.makedirs(os.path.join(self.src, "logs"))
        files = dict(tg.GOOD)
        files["toolchain.txt"] = "forge Version: 1.8.4\nanvil Version: 1.8.4-dev\n"
        for name, text in files.items():
            with open(os.path.join(self.src, "logs", name), "w") as f:
                f.write(text)
        v = tg.verifier()
        for c in v["contracts"].values():
            c.setdefault("onchain_bytes", 24439), c.setdefault("eip170_margin", 137), c.setdefault("abi_sha256", "ab" * 32)
        with open(os.path.join(self.src, "logs", "verifier.json"), "w") as f:
            json.dump(v, f)
        self.index = os.path.join(self.tmp, "INDEX.txt")
        self.write_index()
        self.failed = os.path.join(self.tmp, "FAILED.txt")
        with open(self.failed, "w") as f:
            f.write("The evidence run did not pass; no README.md or SHA256SUMS was written.\n- invariant-deep: 0 PASS lines\n")

    def write_index(self):
        logs = os.path.join(self.src, "logs")
        with open(self.index, "w") as f:
            for name in sorted(os.listdir(logs)):
                f.write(f"{sha(os.path.join(logs, name))}  {name}\n")

    def args(self, **over):
        a = argparse.Namespace(src=self.src, out=os.path.join(self.tmp, "out"), tested_head=REV, parser_rev="5d17e2c", reeval_rev="1803b40",
                               packaging_rev="abcdef1", run_by="Hermes (AI agent)", input_ref="testbed commit 8f80978 (evidence/pr28-clean-rerun-3efdb6f-hermes)",
                               failed_ref="testbed commit 8f80978", source_index=self.index, original_failed=self.failed,
                               selection="The designated reviewer chose this run as the evidence of record.")
        for k, v in over.items():
            setattr(a, k, v)
        return a

    def test_the_packet_names_whose_run_it_is_keeps_the_limits_and_checksums_verify(self):
        a = self.args()
        n = pk.package(a)
        md = read(os.path.join(a.out, "README.md"))
        for needle in (REV, "Hermes (AI agent)", "5d17e2c", "1803b40", "abcdef1", "The script exited 1", "failed on the output format", "only the retrospective evaluation", "Reproducing takes two steps", "git checkout 5d17e2c", "still meets the old parser",
                       "One host, one run", "skipped tests", "no readiness is claimed", "sha256 `" + sha(self.failed) + "`",
                       "41234567", "14 distinct invariants", "git checkout " + REV):
            self.assertIn(needle, md, needle)
        self.assertNotIn("was produced by `scripts/candidate_evidence.sh` from a clean checkout", md)
        self.assertFalse(os.path.exists(os.path.join(a.out, "FAILED.txt")))
        sums = read(os.path.join(a.out, "SHA256SUMS")).splitlines()
        self.assertEqual(len(sums), n)
        for line in sums:
            digest, rel = line.split("  ")
            self.assertEqual(sha(os.path.join(a.out, rel[2:])), digest)
        for name in os.listdir(os.path.join(self.src, "logs")):  # byte for byte
            self.assertEqual(sha(os.path.join(self.src, "logs", name)), sha(os.path.join(a.out, "logs", name)))
        self.assertEqual(gate.gate(a.out), [])

    def test_a_log_that_does_not_match_the_publishers_index_stops_the_packet(self):
        with open(os.path.join(self.src, "logs", "mutants.txt"), "a") as f:
            f.write("tampered\n")
        a = self.args()
        with self.assertRaises(pk.PackageError):
            pk.package(a)
        self.assertFalse(os.path.exists(a.out))

    def test_a_log_missing_from_the_index_or_an_index_entry_without_a_log_stops_the_packet(self):
        with open(self.index, "a") as f:
            f.write("0" * 64 + "  extra.txt\n")
        with self.assertRaises(pk.PackageError):
            pk.package(self.args())
        self.write_index()
        with open(os.path.join(self.src, "logs", "unlisted.txt"), "w") as f:
            f.write("x")
        with self.assertRaises(pk.PackageError):
            pk.package(self.args())

    def test_a_run_the_gate_refuses_leaves_no_packet_at_all(self):
        with open(os.path.join(self.src, "logs", "exit-codes.txt"), "w") as f:
            f.write("".join(f"{n} {1 if n == 'mutants' else 0}\n" for n in gate.RUNS))
        self.write_index()
        a = self.args()
        with self.assertRaises(pk.PackageError) as cm:
            pk.package(a)
        self.assertIn("mutants: exited 1", str(cm.exception))
        self.assertFalse(os.path.exists(a.out))

    def test_the_packet_is_written_once(self):
        a = self.args()
        pk.package(a)
        with self.assertRaises(pk.PackageError):
            pk.package(self.args())

    def test_main_rejects_a_value_that_is_not_a_revision(self):
        argv = ["--src", self.src, "--out", os.path.join(self.tmp, "o2"), "--tested-head", "main", "--parser-rev", "5d17e2c", "--reeval-rev", "1803b40",
                "--packaging-rev", "abcdef1", "--run-by", "x", "--input-ref", "y", "--failed-ref", "z"]
        import sys
        old = sys.argv
        sys.argv = ["candidate_package_run.py"] + argv
        try:
            with contextlib.redirect_stderr(io.StringIO()) as err:
                self.assertEqual(pk.main(), 1)
        finally:
            sys.argv = old
        self.assertIn("not a git revision", err.getvalue())


class ReadmeRenderTest(unittest.TestCase):
    def test_the_default_text_is_what_the_evidence_script_has_always_claimed(self):
        tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, tmp, True)
        os.makedirs(os.path.join(tmp, "logs"))
        for name, text in dict(tg.GOOD).items():
            with open(os.path.join(tmp, "logs", name), "w") as f:
                f.write(text)
        v = tg.verifier()
        for c in v["contracts"].values():
            c.setdefault("onchain_bytes", 1), c.setdefault("eip170_margin", 1), c.setdefault("abi_sha256", "ab" * 32)
        with open(os.path.join(tmp, "logs", "verifier.json"), "w") as f:
            json.dump(v, f)
        md = readme.render(tmp, REV)
        self.assertIn("This directory was produced by `scripts/candidate_evidence.sh` from a clean checkout of that head", md)
        self.assertTrue(md.endswith("```\n"))


if __name__ == "__main__":
    unittest.main()
