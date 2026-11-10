"""Regression tests use synthetic values only, never real credentials."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock

spec = importlib.util.spec_from_file_location("check_agent_secrets", Path(__file__).with_name("check_agent_secrets.py"))
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)


class Patterns(unittest.TestCase):
    def test_private_paths(self):
        for path in (".claude/settings.local.json", "nested/.claude/settings.local.json.bak",
                     ".claude/.credentials.json", ".claude/history.jsonl", "x/.claude/projects/a.jsonl",
                     ".claude/sessions/a.jsonl", ".claude.json", "x/.claude.json.backup", ".env", "x/.env.production"):
            with self.subTest(path=path):
                self.assertTrue(guard.private_path(path))

    def test_shared_and_templates_remain_allowed(self):
        for path in (".claude/settings.json", ".claude/skills/test.md", "CLAUDE.md", "AGENTS.md",
                     "nested/.env.example", ".env.sample", ".env.production.template"):
            with self.subTest(path=path):
                self.assertFalse(guard.private_path(path))

    def test_current_shared_settings(self):
        config = {"permissions": {"allow": ["Bash(git push *)"]}, "attribution": {
            "commit": "Co-Authored-By: Claude <noreply@anthropic.com>", "pr": "Generated with Claude Code", "sessionUrl": False}}
        self.assertEqual(guard.config_risks(json.dumps(config)), set())

    def test_literal_credential_fields(self):
        for name in ("ANTHROPIC_API_KEY", "api_key", "password", "ACCESS_TOKEN", "CLIENT_SECRET", "PRIVATE_KEY"):
            with self.subTest(name=name):
                self.assertIn("literal-secret-field", guard.config_risks(json.dumps({"env": {name: "synthetic-only"}})))

    def test_reference_fields(self):
        for value in ("", "$API_TOKEN", "${API_TOKEN}", "${{ secrets.API_TOKEN }}"):
            with self.subTest(value=value):
                self.assertFalse(guard.config_risks(json.dumps({"env": {"API_TOKEN": value}})))

    def test_literal_command_credentials(self):
        for command in ("Bash(API_TOKEN=synthetic-value curl https://example.invalid)",
                        "Bash(PGPASSWORD='synthetic-value' psql)",
                        "Bash(curl -H 'Authorization: Bearer synthetic-value' https://example.invalid)",
                        "Bash(client --password synthetic-value)",
                        "Bash(client --token=synthetic-value)",
                        "Bash(sshpass -p synthetic-value ssh user@example.invalid)",
                        "Bash(mysql -h example.invalid -psynthetic-value)",
                        "Bash(curl -u user:synthetic-value https://example.invalid)",
                        "Bash(client postgres://user:synthetic-value@example.invalid/db)"):
            with self.subTest(command=command):
                self.assertTrue(guard.config_risks(json.dumps({"permissions": {"allow": [command]}})))

    def test_reference_commands(self):
        for command in ("Bash(API_TOKEN=$API_TOKEN client)", "Bash(client --password ${DB_PASSWORD})",
                        "Bash(client -H 'Authorization: Bearer ${API_TOKEN}')",
                        "Bash(client postgres://user:${DB_PASSWORD}@example.invalid/db)"):
            with self.subTest(command=command):
                self.assertFalse(guard.config_risks(json.dumps({"permissions": {"allow": [command]}})))

    def test_duplicate_json_fields_fail_closed(self):
        data = '{"env":{"API_KEY":"synthetic-secret"},"env":{}}'
        self.assertIn("invalid-json", guard.config_risks(data))

    def test_expression_literal_is_not_a_reference(self):
        self.assertTrue(guard.config_risks(json.dumps({"env": {
            "API_TOKEN": "${{ 'synthetic-secret' }}"}})))

    def test_mcp_argv_literals(self):
        for args in (["--api-key", "synthetic-secret"], ["--password", "synthetic-secret"],
                     ["sshpass", "-p", "synthetic-secret", "ssh"],
                     ["curl", "-u", "user:synthetic-secret"]):
            self.assertTrue(guard.config_risks(json.dumps({"mcpServers": {"server": {"args": args}}})))

    def test_known_format_is_detected(self):
        self.assertIn("provider-key-or-private-key", guard.string_risks("ghp_" + "Q" * 36))
        self.assertIn("provider-key-or-private-key", guard.string_risks("-----BEGIN " + "PRIVATE KEY-----"))

    def test_bad_json_fails_closed(self):
        for data in (b"{broken", b"\xff", b"[]"):
            self.assertTrue(guard.config_risks(data))


class IndexTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.original = Path.cwd()
        os.chdir(self.temp.name)
        subprocess.run(["git", "init", "-q"], check=True)

    def tearDown(self):
        os.chdir(self.original)
        self.temp.cleanup()

    def stage(self, path, content):
        p = Path(path)
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(content)
        subprocess.run(["git", "add", "-f", "--", path], check=True)

    def test_staged_not_worktree_bytes(self):
        self.stage(".claude/settings.json", json.dumps({"env": {"API_KEY": "synthetic-secret"}}))
        Path(".claude/settings.json").write_text("{}")
        checked, findings = guard.check_index()
        self.assertEqual(checked, 1)
        self.assertIn((".claude/settings.json", "literal-secret-field"), findings)

    def test_force_added_private_file(self):
        Path(".gitignore").write_text("**/.claude/settings.local.json*\n")
        self.stage("nested/.claude/settings.local.json", "{}")
        self.assertTrue(guard.check_index()[1])

    def test_symlink_configuration_blocked(self):
        Path(".claude").mkdir()
        Path(".claude/settings.json").symlink_to("../untracked.json")
        subprocess.run(["git", "add", ".claude/settings.json"], check=True)
        self.assertTrue(guard.check_index()[1])

    def test_output_never_contains_secret(self):
        self.stage(".claude/settings.json", json.dumps({"env": {"API_KEY": "synthetic-secret-never-print"}}))
        output = io.StringIO()
        with contextlib.redirect_stdout(output), unittest.mock.patch("sys.argv", ["guard"]):
            self.assertEqual(guard.main(), 1)
        self.assertNotIn("synthetic-secret-never-print", output.getvalue())

    def test_clean_index(self):
        self.stage(".claude/settings.json", "{}")
        self.assertEqual(guard.check_index(), (1, []))


if __name__ == "__main__":
    unittest.main()
