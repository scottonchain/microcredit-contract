#!/usr/bin/env bash
set -e

# scripts/start-anvil.sh
# --------------------------------------------
# Simple wrapper that persistently stores the
# local Anvil chain state between restarts.
# If a snapshot already exists we load it; if
# not, we run anvil and dump state on exit.
# --------------------------------------------

STATE_FILE="./chain-state.json"
PORT=${ANVIL_PORT:-8545}

# Add any extra anvil flags you normally use here
EXTRA_FLAGS="${ANVIL_FLAGS:-}" # allow override via env

# Set gas price and base fee to 0 for free transactions (matching foundry.toml)
GAS_ARGS=(--gas-price 0 --base-fee 0)

BASE_ARGS=(--port "$PORT" "${GAS_ARGS[@]}" $EXTRA_FLAGS)

if [ -f "$STATE_FILE" ]; then
  echo "🔄 Loading chain state from $STATE_FILE (and will dump on exit)"
  exec anvil "${BASE_ARGS[@]}" --load-state "$STATE_FILE" --dump-state "$STATE_FILE"
else
  echo "💾 First run: dumping chain state to $STATE_FILE on exit"
  exec anvil "${BASE_ARGS[@]}" --dump-state "$STATE_FILE"
fi 