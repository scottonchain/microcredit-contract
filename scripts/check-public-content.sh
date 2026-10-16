#!/usr/bin/env bash
# Rejects content that must never reach this public repository: Claude session links or ids,
# "Claude-Session:" trailers, personal email addresses (in content and in commit authorship), agent or
# API tokens, seed phrases, and newly introduced private keys.
# Runs from the commit-msg hook (.husky/commit-msg) and from CI (.github/workflows/lint.yaml).
#
#   scripts/check-public-content.sh --message <file>       a commit message
#   scripts/check-public-content.sh --text <file>          any text, e.g. a PR description
#   scripts/check-public-content.sh --range <base>..<head> messages and added lines of a commit range
set -euo pipefail

# Real leaks only: a session link or id with its identifier, a trailer carrying a URL. Writing
# about the rule ("no claude.ai/code/session_... links") must stay allowed.
PATTERNS='claude\.ai/code/session_01[A-Za-z0-9]{10,}|Claude-Session: *https?://|session_01[A-Za-z0-9]{20,}|moltbook_[A-Za-z0-9_-]{10,}|sk-ant-[A-Za-z0-9_-]{10,}|ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|-----BEGIN [A-Z ]*PRIVATE KEY-----|(seed phrase|mnemonic)[^A-Za-z]{0,3}[a-z]+( [a-z]+){11,}|[A-Za-z0-9._%+-]+@(gmail|googlemail|yahoo|hotmail|outlook|live|icloud|protonmail|proton|aol|gmx|yandex)\.[a-z]{2,3}'
# A literal key next to a word that says it is one. Transaction hashes have the same shape, so only
# labelled keys are checked, and only ones the base does not already contain (Anvil's published keys).
KEY_LINE='(private[_ -]?key|PRIVATE_KEY|secret)[^\n]{0,40}0x[0-9a-fA-F]{64}'

fail=0
scan() {
  local hits status
  # Never print matched lines: their surrounding text may also be private.
  if hits=$(grep -nE "$PATTERNS"); then
    echo "forbidden public content at input line(s):"
    printf '%s\n' "$hits" | cut -d: -f1 | head -20
    fail=1
  else
    status=$?
    [ "$status" -eq 1 ] || return 2
  fi
  return 0
}

input_error() {
  echo "Public-content check input unavailable or invalid; inspect it privately." >&2
  exit 2
}

case "${1:-}" in
  --message | --text)
    [ "$#" -eq 2 ] || input_error
    [ -f "$2" ] && [ -r "$2" ] || input_error
    if ! { scan < "$2"; } 2>/dev/null; then input_error; fi
    ;;
  --range)
    [ "$#" -eq 2 ] || input_error
    range=$2
    base=${range%%..*}
    head=${range##*..}
    [ -n "$base" ] && [ -n "$head" ] && [ "$range" = "$base..$head" ] || input_error
    # Resolve each endpoint once, treating it as data, not a Git option. Failed
    # reads must not become a successful empty scan or echo a supplied revision.
    if ! base_oid=$(git rev-parse --verify --quiet --end-of-options "$base^{commit}" 2>/dev/null); then input_error; fi
    if ! head_oid=$(git rev-parse --verify --quiet --end-of-options "$head^{commit}" 2>/dev/null); then input_error; fi
    if ! messages=$(git log --format='%H %an <%ae> %cn <%ce>%n%B' "$base_oid..$head_oid" 2>/dev/null); then input_error; fi
    if ! changes=$(git diff "$base_oid...$head_oid" 2>/dev/null); then input_error; fi
    # scan runs in this shell (no pipe), so its verdict reaches the exit code below. Authorship is
    # scanned too: a merge made on GitHub carries the account's email unless it is set to private.
    if ! scan <<< "$messages" 2>/dev/null; then input_error; fi
    added=$(printf '%s\n' "$changes" | grep -E '^\+[^+]' | cut -c2- || true)
    if ! scan <<< "$added" 2>/dev/null; then input_error; fi
    while read -r line; do
      [ -n "$line" ] || continue
      key=$(printf '%s' "$line" | grep -oE '0x[0-9a-fA-F]{64}' | head -1)
      if git grep -q -- "$key" "$base_oid" 2>/dev/null; then
        : # Existing published fixture exception is unchanged.
      else
        status=$?
        [ "$status" -eq 1 ] || input_error
        echo "lines added: a new labelled private key was detected"
        fail=1
      fi
    done < <(printf '%s\n' "$added" | grep -E "$KEY_LINE" || true)
    ;;
  *)
    echo "usage: check-public-content.sh --message <file> | --text <file> | --range <base>..<head>" >&2
    exit 2
    ;;
esac

if [ "$fail" -ne 0 ]; then
  echo "This repository is public. Remove the content above (see CLAUDE.md, 'Privacy and security on GitHub')." >&2
  exit 1
fi
