"""Offline synthetic guard diagnostics; no real secrets, remotes or identity probes."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
GUARD = ROOT / "scripts/check-public-content.sh"
SENTINEL = "SYNTHETIC_PRIVATE_CONTEXT_DO_NOT_LOG"
INPUT_ERROR = "Public-content check input unavailable or invalid; inspect it privately.\n"


class PublicContentDiagnosticsTests(unittest.TestCase):
    def run_guard(self, *arguments, cwd=ROOT, env=None):
        return subprocess.run(["bash", str(GUARD), *arguments], cwd=cwd,
                              env=env, capture_output=True, text=True, timeout=10)

    def assert_private(self, result, *values):
        output = result.stdout + result.stderr
        for value in (SENTINEL, *values):
            self.assertNotIn(value, output)

    def test_clean_text_and_message_remain_silent(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "input.txt"
            for text in ("", "Useful review — trabajo, 收入\n", "no session links or credentials\n"):
                path.write_text(text, encoding="utf-8")
                for mode in ("--text", "--message"):
                    result = self.run_guard(mode, str(path))
                    self.assertEqual((result.returncode, result.stdout, result.stderr), (0, "", ""))

    def test_findings_do_not_echo_context_path_or_identifier(self):
        examples = ["ghp" + "_" + "Z" * 24,
                    "https://claude.ai/code/" + "session_" + "01" + "A" * 24,
                    "synthetic-person" + "@" + "gmail" + ".com",
                    "-----BEGIN " + "PRIVATE KEY-----",
                    "seed " + "phrase: " + " ".join(["synthetic"] * 12)]
        with tempfile.TemporaryDirectory(prefix=SENTINEL) as directory:
            path = Path(directory) / (SENTINEL + ".txt")
            for example in examples:
                path.write_text("safe first line\n" + SENTINEL + " " + example + "\n")
                for mode in ("--text", "--message"):
                    with self.subTest(mode=mode, example=examples.index(example)):
                        result = self.run_guard(mode, str(path))
                        self.assertEqual(result.returncode, 1)
                        self.assertIn("input line(s):\n2\n", result.stdout)
                        self.assert_private(result, str(path), example)

    def test_missing_directory_and_argument_errors_are_static(self):
        with tempfile.TemporaryDirectory(prefix=SENTINEL) as directory:
            for mode in ("--text", "--message"):
                for args in ((mode,), (mode, directory), (mode, directory + "/missing"),
                             (mode, directory + "/missing", SENTINEL)):
                    result = self.run_guard(*args)
                    self.assertEqual((result.returncode, result.stdout, result.stderr), (2, "", INPUT_ERROR))
                    self.assert_private(result, directory)
        for args in ((), ("--" + SENTINEL,)):
            result = self.run_guard(*args)
            self.assertEqual(result.returncode, 2)
            self.assertEqual(result.stdout, "")
            self.assertEqual(result.stderr, "usage: check-public-content.sh --message <file> | --text <file> | --range <base>..<head>\n")
            self.assert_private(result, str(GUARD))

    def test_many_findings_are_bounded_numeric_positions_only(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "input.txt"
            path.write_text((SENTINEL + " " + "ghp" + "_" + "Z" * 24 + "\n") * 30)
            result = self.run_guard("--text", str(path))
            self.assertEqual(result.returncode, 1)
            self.assertEqual(result.stdout.splitlines(),
                             ["forbidden public content at input line(s):", *map(str, range(1, 21))])
            self.assert_private(result, str(path))

    def fixture(self, directory, *, base_text="safe base\n", text="safe head\n",
                message="synthetic head", author=None, committer=None):
        repo = Path(directory)
        environment = dict(os.environ, GIT_AUTHOR_NAME="Synthetic guard fixture",
                           GIT_COMMITTER_NAME="Synthetic guard fixture",
                           GIT_AUTHOR_EMAIL="noreply@example.invalid",
                           GIT_COMMITTER_EMAIL="noreply@example.invalid")

        def git(*args):
            result = subprocess.run(["git", *args], cwd=repo, env=environment,
                                    capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, "offline synthetic Git setup failed")
            return result.stdout.strip()

        git("init", "--quiet")
        path = repo / "fixture.txt"
        path.write_text(base_text)
        git("add", "fixture.txt")
        git("-c", "commit.gpgsign=false", "commit", "--quiet", "-m", "synthetic base")
        base = git("rev-parse", "HEAD")
        path.write_text(base_text + text)
        git("add", "fixture.txt")
        if author:
            environment["GIT_AUTHOR_EMAIL"] = author
        if committer:
            environment["GIT_COMMITTER_EMAIL"] = committer
        git("-c", "commit.gpgsign=false", "commit", "--quiet", "-m", message)
        return repo, base + ".." + git("rev-parse", "HEAD")

    def test_clean_and_equal_ranges_remain_silent(self):
        with tempfile.TemporaryDirectory() as directory:
            repo, span = self.fixture(directory)
            for value in (span, "HEAD..HEAD"):
                result = self.run_guard("--range", value, cwd=repo)
                self.assertEqual((result.returncode, result.stdout, result.stderr), (0, "", ""))

    def test_range_checks_added_content_messages_and_both_identities_privately(self):
        identifier = "ghp" + "_" + "Z" * 24
        private_email = "synthetic-person" + "@" + "gmail" + ".com"
        cases = [{"text": SENTINEL + " " + identifier},
                 {"message": SENTINEL + " " + identifier},
                 {"author": private_email}, {"committer": private_email}]
        for kwargs in cases:
            with self.subTest(kind=next(iter(kwargs))), tempfile.TemporaryDirectory(prefix=SENTINEL) as directory:
                repo, span = self.fixture(directory, **kwargs)
                result = self.run_guard("--range", span, cwd=repo)
                self.assertEqual(result.returncode, 1)
                self.assert_private(result, str(repo), identifier, private_email, span)

    def test_new_labelled_key_rejects_without_prefix_and_base_fixture_still_passes(self):
        key = "0x" + "ab" * 32
        line = "private" + "_key = " + key + "\n"
        for known in (False, True):
            with self.subTest(known=known), tempfile.TemporaryDirectory(prefix=SENTINEL) as directory:
                repo, span = self.fixture(directory, base_text=line if known else "safe base\n",
                                          text=line)
                result = self.run_guard("--range", span, cwd=repo)
                self.assertEqual(result.returncode, 0 if known else 1)
                self.assert_private(result, key, key[:10], span, str(repo))
                if known:
                    self.assertEqual(result.stdout + result.stderr, "")

    def test_bad_ranges_and_nonrepository_fail_closed_without_echo(self):
        with tempfile.TemporaryDirectory(prefix=SENTINEL) as directory:
            repo, _ = self.fixture(directory)
            for value in (SENTINEL + "..HEAD", "HEAD.." + SENTINEL, "HEAD", "..HEAD",
                          "HEAD..", "HEAD...HEAD", "--output=" + SENTINEL + "..HEAD"):
                result = self.run_guard("--range", value, cwd=repo)
                self.assertEqual((result.returncode, result.stdout, result.stderr), (2, "", INPUT_ERROR))
                self.assert_private(result, value)
        with tempfile.TemporaryDirectory() as directory:
            result = self.run_guard("--range", "HEAD..HEAD", cwd=directory)
            self.assertEqual((result.returncode, result.stdout, result.stderr), (2, "", INPUT_ERROR))

    def test_input_metacharacters_are_not_commands(self):
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory)
            path = repo / '$(touch executed) `touch executed` input.txt'
            path.write_text('$(touch executed) `touch executed` " ; exit 99 #\n')
            result = self.run_guard("--text", str(path), cwd=repo)
            self.assertEqual((result.returncode, result.stdout, result.stderr), (0, "", ""))
            self.assertFalse((repo / "executed").exists())


if __name__ == "__main__":
    unittest.main()
