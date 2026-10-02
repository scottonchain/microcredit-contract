#!/bin/bash

# scripts/restart.sh
# --------------------------------------------
# DEFAULT: reset local chain state and redeploy (removes ./chain-state.json)
#   yarn restart
# Start from a previously saved state tag (keeps ./chain-state-<tag>.json):
#   yarn restart --tag myteam
# Preserve default state without reset:
#   yarn restart --keep-state
# Kill processes only:
#   yarn restart --kill
# Kill and keep state:
#   yarn restart --kill --keep-state

# Exit on error
set -e

cd "$(dirname "${BASH_SOURCE[0]}")/.."

# Handle flags (default: DELETE_STATE=true)
KILL_ONLY=false
DELETE_STATE=true
TAG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --kill)
      KILL_ONLY=true
      shift
      ;;
    --keep-state)
      DELETE_STATE=false
      shift
      ;;
    --tag)
      TAG="$2"
      shift 2
      ;;
    --tag=*)
      TAG="${1#*=}"
      shift
      ;;
    *)
      echo "⚠️  Unknown argument: $1" >&2
      shift
      ;;
  esac
done

# Kill existing processes if requested or before fresh start
echo "🔪 Killing existing yarn chain and yarn start processes..."
pkill -f "yarn chain" || true
pkill -f "yarn start" || true

# If --kill was passed, exit immediately
if [ "$KILL_ONLY" = true ]; then
  echo "✅ All processes killed. Exiting (--kill)."
  exit 0
fi

# Determine state file (default or by tag)
STATE_FILE="chain-state.json"
if [ -n "$TAG" ]; then
  STATE_FILE="chain-state-${TAG}.json"
  # when a tag is specified, we implicitly keep state unless user passes explicit reset via DELETE_STATE=true
  # Users can force reset of the tagged file by combining with no --keep-state and manually removing if desired
  DELETE_STATE=false
  echo "🏷️  Using tagged state file: $STATE_FILE"
fi

# Remove chain state by default (unless --keep-state or --tag)
if [ "$DELETE_STATE" = true ]; then
  echo "🗑️  Removing $STATE_FILE (default reset)..."
  rm -f "$STATE_FILE" || true
else
  echo "♻️  Keeping $STATE_FILE (preserve state)"
fi

# Start local blockchain
echo "🚀 Starting local blockchain..."
# Ensure high code size limit is applied to anvil
export ANVIL_CODE_SIZE_LIMIT=${ANVIL_CODE_SIZE_LIMIT:-100000000}

# Pass the chosen state file to the anvil wrapper
ANVIL_STATE_FILE="./$STATE_FILE" yarn chain &

CHAIN_PID=$!

# Start frontend
echo "🖥️ Starting frontend..."
yarn start &

START_PID=$!

# Wait for chain to accept RPC calls
echo "⏳ Waiting for chain to boot up..."
for _ in $(seq 1 60); do
  if curl -sf -X POST http://localhost:8545 -H "Content-Type: application/json" \
      -d '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' >/dev/null 2>&1; then
    break
  fi
  sleep 0.5
done

# Deploy contracts
echo "📦 Deploying contracts..."
# Set environment variables to avoid password prompt
RPC_URL=localhost ETH_KEYSTORE_ACCOUNT="scaffold-eth-default" yarn deploy

echo "✅ Deployment complete."
echo "ℹ️ Chain PID: $CHAIN_PID, Frontend PID: $START_PID"
