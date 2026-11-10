#!/usr/bin/env python3
"""Check tracked/staged agent configuration without printing secret values.

This intentionally narrow guard supplements provider-aware secret scanning. It
reads index blobs (not working-tree contents), never executes configuration, and
uses only the Python standard library and Git.
"""
import argparse
import json
from pathlib import PurePosixPath
import re
import subprocess
import sys

# Match names, not values. This also covers a nested project/worktree directory.
PRIVATE_PARTS = {"projects", "sessions", "debug", "todos"}
SECRET_NAME = re.compile(
    r"(?:^|[_-])(?:api[_-]?key|access[_-]?key|private[_-]?key|client[_-]?secret|"
    r"password|passwd|token|secret|credential)(?:s)?$|^(?:PGPASSWORD|MYSQL_PWD)$", re.I)
PROVIDER = re.compile(
    r"(?:\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,}|"
    r"sk-(?:ant-[A-Za-z0-9_-]{20,}|proj-[A-Za-z0-9_-]{20,}|[A-Za-z0-9]{32,})|"
    r"AKIA[A-Z0-9]{16}|xox[baprs]-[A-Za-z0-9-]{20,})\b|"
    r"-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----)")
ASSIGNMENT = re.compile(r"\b([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(\"[^\"]*\"|'[^']*'|[^\s;,)]+)")
FLAG = re.compile(r"--(?:password|passwd|token|api-key|api_key|secret|private-key)"
                  r"(?:=|\s+)(\"[^\"]*\"|'[^']*'|[^\s;)]+)", re.I)
AUTH = re.compile(r"\b(?:Bearer|Basic)\s+([^\s'\"]+)", re.I)
SHORT_PASSWORD = re.compile(r"\b(?:sshpass|mysql|mariadb)\b[^;\n]*?\s-p\s*(\"[^\"]*\"|'[^']*'|[^\s;)]+)", re.I)
CURL_USER = re.compile(r"\bcurl\s+[^;\n]*?(?:--user(?:=|\s+)|-u\s*)(?:[\"']?[^\s:]+):([^\s\"')]+)", re.I)
URL_PASSWORD = re.compile(r"[a-z][a-z0-9+.-]*://[^\s/:]+:([^\s/@]+)@", re.I)
REFERENCE = re.compile(r"(?:\$[A-Za-z_][A-Za-z0-9_]*|\$\{[A-Za-z_][A-Za-z0-9_]*\}|"
                       r"\$\{\{\s*(?:secrets|env)\.[A-Za-z_][A-Za-z0-9_]*\s*\}\})")


def private_path(path):
    parts = PurePosixPath(path).parts
    name = parts[-1] if parts else ""
    if name == ".claude.json" or name.startswith(".claude.json."):
        return True
    if name == ".env" or (name.startswith(".env.") and not name.endswith((".example", ".sample", ".template"))):
        return True
    for i, part in enumerate(parts[:-1]):
        if part == ".claude":
            rest = parts[i + 1:]
            return (rest[0] in PRIVATE_PARTS or rest[0].startswith("settings.local.json")
                    or rest[0].startswith(".credentials.json") or rest[0] == "history.jsonl")
    return False


def configuration_path(path):
    p = PurePosixPath(path)
    return (p.name == ".mcp.json" or
            (p.parent.name == ".claude" and p.name.startswith("settings") and p.suffix == ".json"))


def literal(value):
    value = value.strip().strip("\"'")
    # Empty entries and whole environment references carry no embedded secret.
    return bool(value) and REFERENCE.fullmatch(value) is None


def string_risks(value):
    risks = set()
    if PROVIDER.search(value):
        risks.add("provider-key-or-private-key")
    if any(SECRET_NAME.search(m[1]) and literal(m[2]) for m in ASSIGNMENT.finditer(value)):
        risks.add("literal-secret-assignment")
    if any(literal(m[1]) for pattern in (FLAG, AUTH, URL_PASSWORD, SHORT_PASSWORD, CURL_USER) for m in pattern.finditer(value)):
        risks.add("literal-command-credential")
    return risks


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate JSON field")
        result[key] = value
    return result


def config_risks(data):
    try:
        config = json.loads(data, object_pairs_hook=unique_object)
    except (UnicodeError, ValueError):
        return {"invalid-json"}
    if not isinstance(config, dict):
        return {"invalid-settings-object"}
    risks = set()
    def walk(value):
        if isinstance(value, dict):
            for key, item in value.items():
                if SECRET_NAME.search(key) and item not in (None, "", False):
                    if not isinstance(item, str) or literal(item):
                        risks.add("literal-secret-field")
                walk(item)
        elif isinstance(value, list):
            # MCP commands commonly split flag and credential into argv entries.
            if value and all(isinstance(item, str) for item in value):
                risks.update(string_risks(" ".join(value)))
            for item in value:
                walk(item)
        elif isinstance(value, str):
            risks.update(string_risks(value))
    walk(config)
    return risks


def git(*args):
    result = subprocess.run(["git", *args], capture_output=True)
    if result.returncode:
        # Git diagnostics may echo input or remote details. Never print them.
        raise RuntimeError("Git read failed; run inside a repository with a readable index")
    return result.stdout


def check_index():
    findings = []
    checked = 0
    for entry in git("ls-files", "--stage", "-z").split(b"\0"):
        if not entry:
            continue
        meta, raw_path = entry.split(b"\t", 1)
        mode, oid, stage = meta.split()
        path = raw_path.decode("utf-8", "surrogateescape")
        if private_path(path):
            findings.append((path, "private-local-file"))
        if not configuration_path(path):
            continue
        checked += 1
        if stage != b"0" or mode != b"100644":
            findings.append((path, "configuration-must-be-regular-resolved-file"))
            continue
        for risk in sorted(config_risks(git("cat-file", "blob", oid.decode("ascii")))):
            findings.append((path, risk))
    return checked, findings


def main():
    argparse.ArgumentParser(description=__doc__).parse_args()
    try:
        checked, findings = check_index()
    except (RuntimeError, ValueError, OSError):
        print("Agent secret guard: Git/index inspection failed (details withheld).", file=sys.stderr)
        return 2
    for path, risk in findings:
        # JSON escaping prevents terminal/CI control sequences in filenames.
        print(f"BLOCK {json.dumps(path, ensure_ascii=True)}: {risk}")
    if findings:
        print("Agent secret guard failed. Remove private files from the index; use environment references.")
        print("If a real secret was already published, revoke/rotate it first. Deletion does not erase history.")
        return 1
    print(f"Agent secret guard passed: {checked} indexed configuration file(s); no blocked local files.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
