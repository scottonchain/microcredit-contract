#!/usr/bin/env bash
# One local lifecycle: restart delegates startup, deployment and cleanup to demo.sh.
# yarn restart [--keep-state | --tag NAME]   reset the default state unless preservation is requested
# yarn restart --kill                      stop only this repository's managed demo
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KEEP=false
KILL_ONLY=false
STATE="$REPO/chain-state.json"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --kill) KILL_ONLY=true; shift ;;
    --keep-state) KEEP=true; shift ;;
    --tag)
      [[ $# -ge 2 ]] || { echo "--tag needs a name" >&2; exit 1; }
      TAG="$2"; shift 2
      [[ "$TAG" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || { echo "Invalid state tag" >&2; exit 1; }
      STATE="$REPO/chain-state-$TAG.json"; KEEP=true ;;
    --tag=*)
      TAG="${1#*=}"; shift
      [[ "$TAG" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || { echo "Invalid state tag" >&2; exit 1; }
      STATE="$REPO/chain-state-$TAG.json"; KEEP=true ;;
    *) echo "Unknown restart argument: $1" >&2; exit 1 ;;
  esac
done

PIDFILE="$REPO/logs/demo.pid"
if [[ -f "$PIDFILE" ]]; then
  read -r demo_pid < "$PIDFILE" || true
  if [[ "${demo_pid:-}" =~ ^[1-9][0-9]*$ ]] && [[ "$(ps -p "$demo_pid" -o args= 2>/dev/null || true)" == *"$REPO/scripts/demo.sh"* ]]; then
    echo "Stopping this repository's demo ($demo_pid)…"
    kill -TERM "$demo_pid"
    for ((attempt=0; attempt<60; attempt++)); do
      [[ "$(ps -p "$demo_pid" -o args= 2>/dev/null || true)" == *"$REPO/scripts/demo.sh"* ]] || break
      sleep 0.25
    done
    if [[ "$(ps -p "$demo_pid" -o args= 2>/dev/null || true)" == *"$REPO/scripts/demo.sh"* ]]; then
      echo "The recorded demo is still stopping; inspect logs before restarting." >&2
      exit 1
    fi
  fi
  rm -f "$PIDFILE"
fi
if [[ "$KILL_ONLY" == true ]]; then
  echo "No managed demo remains. Independently started servers are left to their own terminal."
  exit 0
fi

args=(--manual)
[[ "$KEEP" == false ]] || args+=(--reuse)
exec env ANVIL_STATE_FILE="$STATE" bash "$REPO/scripts/demo.sh" "${args[@]}"
