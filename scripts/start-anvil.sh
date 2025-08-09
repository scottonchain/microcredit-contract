#!/usr/bin/env bash
set -e

# scripts/start-anvil.sh
# --------------------------------------------
# Simple wrapper that persistently stores the
# local Anvil chain state between restarts.
# If a snapshot already exists and is valid we
# load it; if not, we run anvil and dump state
# on exit. Invalid/malformed state files are
# backed up and ignored.
# --------------------------------------------

STATE_FILE="./chain-state.json"
PORT=${ANVIL_PORT:-8545}
# Default high code size limit to avoid local EIP-170 prompts
CODE_SIZE_LIMIT=${ANVIL_CODE_SIZE_LIMIT:-100000000}

# Add any extra anvil flags you normally use here
EXTRA_FLAGS="${ANVIL_FLAGS:-}" # allow override via env

# Set gas price and base fee to 0 for free transactions (matching foundry.toml)
GAS_ARGS=(--gas-price 0 --base-fee 0)

BASE_ARGS=(--port "$PORT" --code-size-limit "$CODE_SIZE_LIMIT" "${GAS_ARGS[@]}" $EXTRA_FLAGS)

# Validate state JSON (must parse and contain top-level 'accounts') using Node
validate_state() {
  node -e '
    const fs = require("fs");
    const p = process.argv[1];
    try {
      const d = JSON.parse(fs.readFileSync(p, "utf8"));
      // Anvil --dump-state produces an object with top-level keys like
      // { block: {...}, accounts: {"0x..": {...}}, best_block_number: "0x..", ... }
      // Accept either an array or an object for compatibility
      if (
        d &&
        Object.prototype.hasOwnProperty.call(d, "accounts") &&
        (
          Array.isArray(d.accounts) ||
          (typeof d.accounts === "object" && d.accounts !== null)
        )
      ) {
        process.exit(0);
      }
      process.exit(2);
    } catch (e) {
      process.exit(1);
    }
  ' "$STATE_FILE"
}

backup_invalid_state() {
  local ts
  ts=$(date +%Y%m%d-%H%M%S)
  local backup_file
  backup_file="${STATE_FILE%.json}.invalid-${ts}.json"
  echo "🗂️  Backing up invalid state to ${backup_file}"
  mv -f "$STATE_FILE" "$backup_file" || true
}

if [ -f "$STATE_FILE" ]; then
  if validate_state; then
    echo "🔄 Loading chain state from $STATE_FILE (and will dump on exit)"
    exec anvil "${BASE_ARGS[@]}" --load-state "$STATE_FILE" --dump-state "$STATE_FILE"
  else
    echo "⚠️  Detected missing/invalid $STATE_FILE. Starting fresh without --load-state."
    backup_invalid_state
    exec anvil "${BASE_ARGS[@]}" --dump-state "$STATE_FILE"
  fi
else
  echo "💾 First run: dumping chain state to $STATE_FILE on exit"
  exec anvil "${BASE_ARGS[@]}" --dump-state "$STATE_FILE"
fi