"""Offline falsification of the current CI privacy caller, not a repaired gate.

Runs the extracted workflow shell block with synthetic local Git and a fake gh.
Prints only structured outcomes; never prints the captured diagnostic content.
No network, real credentials, production commits or workflow edits are used.
"""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/lint.yaml"
GUARD = ROOT / "scripts/check-public-content.sh"


def digest(data):
    return hashlib.sha256(data).hexdigest()


def extract_caller(text):
    """Extract exactly one literal run block from the named step; fail on drift."""
    marker = "      - name: Check that nothing private reaches the public repo\n"
    if text.count(marker) != 1:
        raise ValueError("expected one privacy step")
    step = text.split(marker, 1)[1].split("\n      - name:", 1)[0]
    if step.count("        run: |\n") != 1:
        raise ValueError("expected one literal shell block")
    lines = step.split("        run: |\n", 1)[1].splitlines()
    while lines and not lines[-1].strip():
        lines.pop()
    if not lines or any(line and not line.startswith("          ") for line in lines):
        raise ValueError("unsupported shell indentation")
    block = "\n".join(line[10:] if line else "" for line in lines) + "\n"
    expression = "${{ github.repository }}"
    if block.count(expression) != 1:
        raise ValueError("expected one repository interpolation")
    # The sole runner-side interpolation; all other bytes remain the source block.
    return block, block.replace(expression, "synthetic/fixture")


def execute(args, cwd, env):
    return subprocess.run(args, cwd=cwd, env=env, capture_output=True,
                          text=True, timeout=15)


def run_case(block, proposed, name, *, content=False, base="present", head="present", body=None):
    with tempfile.TemporaryDirectory(prefix="ci-caller-synthetic-") as directory:
        repo = Path(directory)
        (repo / "scripts").mkdir()
        shutil.copy2(GUARD, repo / "scripts/check-public-content.sh")
        (repo / "bin").mkdir()
        fake_gh = repo / "bin/gh"
        fake_gh.write_text('#!/bin/sh\nprintf "%s\\n" "$SYNTHETIC_PR_BODY"\n')
        fake_gh.chmod(0o755)
        # No inherited tokens, Git configuration, identity, shell tracing or hooks.
        env = dict(PATH=str(repo / "bin") + os.pathsep + os.defpath,
                   GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull,
                   GIT_AUTHOR_NAME="Synthetic caller fixture",
                   GIT_COMMITTER_NAME="Synthetic caller fixture",
                   GIT_AUTHOR_EMAIL="noreply@example.invalid",
                   GIT_COMMITTER_EMAIL="noreply@example.invalid")

        def git(*args):
            result = execute(["git", *args], repo, env)
            if result.returncode:
                raise RuntimeError("offline fixture setup failed")
            return result.stdout.strip()

        git("init", "--quiet")
        path = repo / "fixture.txt"
        path.write_text("safe base\n")
        git("add", "fixture.txt")
        git("-c", "commit.gpgsign=false", "commit", "--quiet", "-m", "synthetic base")
        base_oid = git("rev-parse", "HEAD")
        synthetic_finding = "ghp" + "_" + "Z" * 24
        path.write_text("safe base\n" + (synthetic_finding if content else "safe head") + "\n")
        git("add", "fixture.txt")
        git("-c", "commit.gpgsign=false", "commit", "--quiet", "-m", "synthetic head")
        head_oid = git("rev-parse", "HEAD")
        env.update(BASE={"present": base_oid, "missing": "unavailable-synthetic-base",
                         "empty": ""}[base],
                   HEAD_SHA={"present": head_oid, "missing": "unavailable-synthetic-head",
                             "equal": base_oid}[head],
                   PR_NUMBER="1" if body is not None else "",
                   SYNTHETIC_PR_BODY=synthetic_finding if body == "finding" else "safe body")
        # The source writes /tmp/pr-body.txt. Sandbox that one literal path inside
        # the disposable fixture; it is not a behavioral rewrite of either check.
        runnable = block.replace("/tmp/pr-body.txt", str(repo / "pr-body.txt"))
        # No shell override appears in the pinned workflow. GitHub documents
        # bash -e for the unspecified Linux default; also check stricter Bash.
        default_shell = ["bash", "-e", "-c"]
        strict_shell = ["bash", "--noprofile", "--norc", "-e", "-o", "pipefail", "-c"]
        caller = execute([*default_shell, runnable], repo, env)
        strict_caller = execute([*strict_shell, runnable], repo, env)
        proposed_runnable = proposed.replace("/tmp/pr-body.txt", str(repo / "pr-body.txt"))
        candidate = execute([*default_shell, proposed_runnable], repo, env)
        strict_candidate = execute([*strict_shell, proposed_runnable], repo, env)
        guard = execute(["bash", str(GUARD), "--range", env["BASE"] + ".." + env["HEAD_SHA"]], repo, env)
        results = (caller, strict_caller, candidate, strict_candidate, guard)
        combined = "".join(result.stdout + result.stderr for result in results)
        if synthetic_finding in combined:
            raise AssertionError("captured diagnostics echoed a synthetic finding")
        return dict(case=name, caller_exit=caller.returncode, direct_guard_exit=guard.returncode,
                    proposed_caller_exit=candidate.returncode,
                    strict_caller_exit=strict_caller.returncode,
                    strict_proposed_caller_exit=strict_candidate.returncode,
                    caller_output_empty=not (caller.stdout + caller.stderr),
                    synthetic_finding_echoed=False)


def experiment():
    workflow = WORKFLOW.read_bytes()
    source, executable = extract_caller(workflow.decode())
    conditional = ('if git cat-file -e "$BASE" 2>/dev/null; then\n'
                   '  scripts/check-public-content.sh --range "$BASE..$HEAD_SHA"\nfi\n')
    if executable.count(conditional) != 1:
        raise ValueError("expected one current range skip")
    proposed = executable.replace(conditional,
                                 'scripts/check-public-content.sh --range "$BASE..$HEAD_SHA"\n')
    specifications = [
        ("clean_valid_range", {}, (0, 0)),
        ("finding_valid_range", {"content": True}, (1, 1)),
        ("equal_range", {"head": "equal"}, (0, 0)),
        ("clean_missing_base", {"base": "missing"}, (0, 2)),
        ("finding_missing_base", {"base": "missing", "content": True}, (0, 2)),
        ("clean_empty_base", {"base": "empty"}, (0, 2)),
        ("finding_empty_base", {"base": "empty", "content": True}, (0, 2)),
        ("missing_head_valid_base", {"head": "missing"}, (2, 2)),
        ("pr_clean_body_finding_missing_base", {"base": "missing", "content": True, "body": "clean"}, (0, 2)),
        ("pr_finding_body_clean_range", {"body": "finding"}, (1, 0)),
    ]
    rows = []
    for name, kwargs, expected in specifications:
        row = run_case(executable, proposed, name, **kwargs)
        if (row["caller_exit"], row["direct_guard_exit"]) != expected:
            raise AssertionError("caller behavior changed: " + name)
        expected_proposed = 1 if kwargs.get("body") == "finding" else expected[1]
        if row["proposed_caller_exit"] != expected_proposed:
            raise AssertionError("proposed caller mismatch: " + name)
        if (row["strict_caller_exit"], row["strict_proposed_caller_exit"]) != (expected[0], expected_proposed):
            raise AssertionError("shell comparison mismatch: " + name)
        rows.append(row)
    return dict(schema="ci-privacy-caller-experiment/v1", workflow_sha256=digest(workflow),
                guard_sha256=digest(GUARD.read_bytes()), source_block_sha256=digest(source.encode()),
                cases=rows, conclusion="CALLER_FALSE_GREEN_WITH_UNAVAILABLE_BASE",
                classification="synthetic offline reproduction; not production exposure or fixed CI",
                transformations=["resolve repository expression to synthetic/fixture",
                                 "redirect PR body temporary file inside disposable fixture"],
                proposed_remedy="unconditional range invocation, synthetic only; workflow unchanged",
                github_api="fake gh emits synthetic body; no live API or credentials")


if __name__ == "__main__":
    print(json.dumps(experiment(), indent=2, sort_keys=True))
