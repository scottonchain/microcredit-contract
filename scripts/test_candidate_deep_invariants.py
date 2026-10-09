"""candidate_deep_invariants.sh: patches the two inline annotations for the run, passes forge's exit code on, and leaves the tree clean on
every exit path (Hermes found the restore failing on 36c32d8 because forge ran in packages/foundry and the paths are repo-root relative).
A fake `forge` on PATH records what it saw; the script is copied into a throwaway git repository so the real tree is never touched."""
import os, shutil, subprocess, tempfile, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
FILES = ("packages/foundry/test/invariant/BootstrapOrderRouter.invariant.t.sol", "packages/foundry/test/invariant/TransitiveStakeRouter.invariant.t.sol")
BODY = "/// forge-config: default.invariant.runs = 64\n/// forge-config: default.invariant.depth = 80\ncontract T {}\n"


class DeepInvariantsScriptTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.repo = os.path.join(self.tmp, "repo")
        os.makedirs(os.path.join(self.repo, "scripts"))
        shutil.copy(os.path.join(HERE, "candidate_deep_invariants.sh"), os.path.join(self.repo, "scripts"))
        for f in FILES:
            os.makedirs(os.path.dirname(os.path.join(self.repo, f)), exist_ok=True)
            with open(os.path.join(self.repo, f), "w") as fh:
                fh.write(BODY)
        for cmd in (["init", "-q"], ["add", "-A"], ["-c", "user.name=t", "-c", "user.email=t@example.invalid", "commit", "-q", "-m", "x"]):
            subprocess.run(["git", "-C", self.repo] + cmd, check=True)
        self.bin = os.path.join(self.tmp, "bin")
        os.makedirs(self.bin)
        self.seen = os.path.join(self.tmp, "seen.txt")
        with open(os.path.join(self.bin, "forge"), "w") as fh:
            fh.write('#!/bin/sh\npwd >> "$SEEN"\ngrep -h forge-config test/invariant/*.sol >> "$SEEN"\nexit "${FAKE_RC:-0}"\n')
        os.chmod(os.path.join(self.bin, "forge"), 0o755)

    def run_script(self, rc=0, cwd=None, **env):
        e = dict(os.environ, PATH=self.bin + os.pathsep + os.environ["PATH"], SEEN=self.seen, FAKE_RC=str(rc), **env)
        return subprocess.run(["bash", os.path.join(self.repo, "scripts", "candidate_deep_invariants.sh")], cwd=cwd or self.tmp, env=e,
                              capture_output=True, text=True)

    def status(self):
        return subprocess.run(["git", "-C", self.repo, "status", "--porcelain"], capture_output=True, text=True, check=True).stdout.strip()

    def seen_text(self):
        with open(self.seen) as fh:
            return fh.read()

    def test_forge_sees_the_deep_annotations_in_packages_foundry_and_the_tree_is_clean_afterwards(self):
        r = self.run_script()
        self.assertEqual(r.returncode, 0, r.stderr)
        seen = self.seen_text()
        self.assertTrue(seen.splitlines()[0].endswith("packages/foundry"), seen)
        self.assertEqual(seen.count("invariant.runs = 512"), 2)
        self.assertEqual(seen.count("invariant.depth = 150"), 2)
        self.assertIn("+/// forge-config: default.invariant.runs = 512", r.stdout)
        self.assertEqual(self.status(), "")
        for f in FILES:
            with open(os.path.join(self.repo, f)) as fh:
                self.assertEqual(fh.read(), BODY)

    def test_a_failing_forge_run_passes_its_exit_code_on_and_still_restores(self):
        r = self.run_script(rc=3)
        self.assertEqual(r.returncode, 3)
        self.assertEqual(self.status(), "")

    def test_the_size_can_be_chosen(self):
        r = self.run_script(DEEP_RUNS="1024", DEEP_DEPTH="200")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("invariant.runs = 1024", self.seen_text())
        self.assertIn("invariant.depth = 200", self.seen_text())
        self.assertEqual(self.status(), "")

    def test_a_restore_that_fails_fails_the_script(self):
        # a tracked file that was never committed cannot be restored: the script must say so and exit non-zero
        subprocess.run(["git", "-C", self.repo, "rm", "-q", "--cached", FILES[0]], check=True)
        r = self.run_script()
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("could not restore", r.stderr)


if __name__ == "__main__":
    unittest.main()
