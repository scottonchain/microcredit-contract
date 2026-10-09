"""Exercise local lifecycle failures with fake tools, no chain or network access."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parent


class DevScriptsTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        (self.root / "scripts").mkdir()
        self.bin = self.root / "bin"
        self.bin.mkdir()
        for name in ("demo.sh", "restart.sh", "start-anvil.sh", "candidate_evidence.sh"):
            shutil.copyfile(SCRIPTS / name, self.root / "scripts" / name)
        dependency = self.root / "lib/openzeppelin-contracts/lib/forge-std/src/Script.sol"
        dependency.parent.mkdir(parents=True)
        dependency.touch()
        self.tool("node", "exit 1\n")  # Port probes say both ports are free.
        self.tool("anvil", "exec sleep 60\n")  # Cleanup must stop this exact child on a deployment failure.
        self.tool("curl", "echo '{}'; exit 0\n")
        self.tool("yarn", 'case "$1" in install) exit "${TEST_INSTALL_EXIT:-0}";; deploy) exit "${TEST_DEPLOY_EXIT:-0}";; esac\n')
        self.env = {**os.environ, "PATH": str(self.bin) + os.pathsep + os.environ["PATH"]}
        self.env.pop("ANVIL_STATE_FILE", None)
        self.env.pop("MICROCREDIT_DEMO_ROOT", None)

    def tool(self, name, body):
        path = self.bin / name
        path.write_text("#!/usr/bin/env bash\n" + body)
        path.chmod(0o755)

    def run_script(self, script, *args, **env):
        return subprocess.run(["bash", str(self.root / "scripts" / script), *args], cwd=self.root,
                              env={**self.env, **env}, capture_output=True, text=True, timeout=10)

    def test_install_failure_keeps_its_status_and_preserves_saved_state(self):
        state = self.root / "chain-state-demo.json"
        state.write_text("saved state")
        result = self.run_script("demo.sh", "--manual", TEST_INSTALL_EXIT="23")
        self.assertEqual(result.returncode, 23, result.stdout + result.stderr)
        self.assertNotIn("Dependencies ready", result.stdout)
        self.assertEqual(state.read_text(), "saved state")
        self.assertFalse((self.root / "logs/demo.pid").exists())

    def test_deploy_failure_is_not_reported_as_a_success(self):
        result = self.run_script("demo.sh", "--manual", TEST_DEPLOY_EXIT="27")
        self.assertEqual(result.returncode, 27, result.stdout + result.stderr)
        self.assertNotIn("Contracts deployed", result.stdout)
        self.assertNotIn("Starting Next.js", result.stdout)
        self.assertFalse((self.root / "logs/demo.pid").exists())

    def test_restart_and_demo_reject_incomplete_or_unknown_flags(self):
        for script, args in (("demo.sh", ["--typo"]), ("restart.sh", ["--tag"]),
                             ("restart.sh", ["--tag", "../escape"]), ("restart.sh", ["--typo"])):
            with self.subTest(script=script, args=args):
                self.assertNotEqual(self.run_script(script, *args).returncode, 0)

    def test_evidence_rerun_cannot_erase_an_existing_packet(self):
        self.tool("git", 'if [[ "$1" == rev-parse ]]; then echo abcdef1; fi\n')
        evidence = self.root / "evidence/existing"
        evidence.mkdir(parents=True)
        (evidence / "receipt.txt").write_text("original receipt")
        result = self.run_script("candidate_evidence.sh", str(evidence))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("output already exists", result.stderr)
        self.assertEqual((evidence / "receipt.txt").read_text(), "original receipt")
        self.assertEqual([p.name for p in evidence.iterdir()], ["receipt.txt"])


if __name__ == "__main__":
    unittest.main()
