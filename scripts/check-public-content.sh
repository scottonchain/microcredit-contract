#!/usr/bin/env bash
# Rejects content that must never reach this public repository: Claude session links or ids,
# "Claude-Session:" trailers, agent or API tokens, seed phrases, and newly introduced private keys.
# Runs from the commit-msg hook (.husky/commit-msg) and from CI (.github/workflows/lint.yaml).
#
#   scripts/check-public-content.sh --message <file>       a commit message
#   scripts/check-public-content.sh --text <file>          any text, e.g. a PR description
#   scripts/check-public-content.sh --range <base>..<head> messages and added lines of a commit range
set -euo pipefail

# Real leaks only: a session link or id with its identifier, a trailer carrying a URL. Writing
# about the rule ("no claude.ai/code/session_... links") must stay allowed.
PATTERNS='claude\.ai/code/session_01[A-Za-z0-9]{10,}|Claude-Session: *https?://|session_01[A-Za-z0-9]{20,}|moltbook_[A-Za-z0-9_-]{10,}|sk-ant-[A-Za-z0-9_-]{10,}|ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|-----BEGIN [A-Z ]*PRIVATE KEY-----|(seed phrase|mnemonic)[^A-Za-z]{0,3}[a-z]+( [a-z]+){11,}'
# A literal key next to a word that says it is one. Transaction hashes have the same shape, so only
# labelled keys are checked, and only ones the base does not already contain (Anvil's published keys).
KEY_LINE='(private[_ -]?key|PRIVATE_KEY|secret)[^\n]{0,40}0x[0-9a-fA-F]{64}'

fail=0
scan() {
  local label=$1 hits
  # Line numbers with the match masked: a finding must not copy the content into a public CI log.
  hits=$(grep -nE "$PATTERNS" | sed -E "s#$PATTERNS#[redacted]#g" || true)
  if [ -n "$hits" ]; then
    echo "$label: forbidden content"
    echo "$hits" | head -20
    fail=1
  fi
}

case "${1:-}" in
  --message | --text)
    scan "$2" < "$2"
    ;;
  --range)
    range=$2
    base=${range%%..*}
    head=${range##*..}
    # scan runs in this shell (no pipe), so its verdict reaches the exit code below
    scan "commit messages in $base..$head" < <(git log --format='%H%n%B' "$base..$head")
    added=$(git diff "$base...$head" | grep -E '^\+[^+]' | cut -c2- || true)
    scan "lines added in $base...$head" <<< "$added"
    while read -r line; do
      [ -n "$line" ] || continue
      key=$(printf '%s' "$line" | grep -oE '0x[0-9a-fA-F]{64}' | head -1)
      if ! git grep -q -- "$key" "$base" 2>/dev/null; then
        echo "lines added in $base...$head: a private key the base does not contain: ${key:0:10}..."
        fail=1
      fi
    done < <(printf '%s\n' "$added" | grep -E "$KEY_LINE" || true)
    ;;
  *)
    echo "usage: $0 --message <file> | --text <file> | --range <base>..<head>" >&2
    exit 2
    ;;
esac

if [ "$fail" -ne 0 ]; then
  echo "This repository is public. Remove the content above (see CLAUDE.md, 'Privacy and security on GitHub')." >&2
  exit 1
fi
