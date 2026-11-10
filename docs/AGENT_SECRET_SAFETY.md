# Agent configuration and secrets

Written by Codex (AI), November 10, 2026.

Claude Code can save the full text of a remembered shell approval in
`.claude/settings.local.json`, including credentials typed into the command.
A machine-local ignore does not protect every future clone. This repository
therefore ignores local settings, credentials, session data and dotenv values
at any depth. Shared `.claude/settings.json`, skills and instructions remain
tracked and must receive ordinary review.

## Before committing

Use environment references such as `${API_TOKEN}`, a service's credential helper,
or a secret manager. Do not put literal credentials in command arguments,
permission rules, hooks, shared settings or `.mcp.json`. Templates must contain
only unmistakably fake placeholders. Do not commit session transcripts, copied
home directories, local settings backups or debug logs.

Stage only the intended files, then run:

```sh
python -m unittest discover -s tools/security -p 'test_*.py'
python tools/security/check_agent_secrets.py
```

The guard reads staged/index blobs, not the potentially different working copy.
It blocks tracked private local files even after `git add -f`, malformed/shared
configuration symlinks, recognized credential formats, common literal credential
fields, connection-string passwords and shell-command credentials in Claude
settings and `.mcp.json`. It reports paths and rule names, never matched values.
The read-only CI job runs the same tests and guard on pushes and pull requests.
No repository secrets, tokens with write permission or deployment steps are used.

This is a focused guard, not a complete secret scanner or an access boundary.
CI runs **after** a push and cannot undo public disclosure. Run the guard before
committing and retain existing public-content checks. Use provider-aware secret
scanning and push protection as additional layers when available. No account
security settings or required branch checks are changed by this patch. Review
any future requested scanner permission or rule change through the normal gate.
The guard does not inspect arbitrary source files, binary files, obfuscated
credentials, every possible credential spelling, or all Git history in CI.

## If exposure is suspected

Do not paste a value into a public issue, PR, report or scanner log, and do not
try it against a provider. Privately identify the affected service, file and
commit. Revoke/rotate a real secret through the authorized account process first,
then update consumers and review relevant access logs. Removing a file, adding
an ignore or rewriting the latest commit does not remove prior commits, forks,
clones, cached views or logs. Coordinate any history cleanup with repository
owners only after containment; history rewriting is not part of this change.
Never use public development-chain keys for real accounts or assets.

Sources: [Apiiro's research](https://apiiro.com/blog/coding-agents-leaking-secrets-github-dont-ask-again)
and [Claude settings documentation](https://code.claude.com/docs/en/settings).
