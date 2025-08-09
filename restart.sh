#!/bin/bash

# Start fresh with no saved state
# ./restart_chain_and_deploy.sh --nostate

# Kill only
# ./restart_chain_and_deploy.sh --kill

# Fresh start and remove old chain state
# ./restart_chain_and_deploy.sh --kill --nostate



# Exit on error
set -e

# Handle flags
KILL_ONLY=false
DELETE_STATE=false

for arg in "$@"; do
  case $arg in
    --kill)
      KILL_ONLY=true
      ;;
    --nostate)
      DELETE_STATE=true
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

# Remove chain state if --nostate passed
if [ "$DELETE_STATE" = true ]; then
  echo "🗑️ Removing chain-state.json..."
  rm -f chain-state.json
fi

# Clean build artifacts
echo "🧹 Cleaning previous build artifacts..."
rm -rf out cache artifacts deployments || true

# Start local blockchain
echo "🚀 Starting local blockchain..."
# Ensure high code size limit is applied to anvil
export ANVIL_CODE_SIZE_LIMIT=${ANVIL_CODE_SIZE_LIMIT:-100000000}
yarn chain &

CHAIN_PID=$!

# Start frontend
echo "🖥️ Starting frontend..."
yarn start &

START_PID=$!

# Wait for chain to boot up
echo "⏳ Waiting for chain to boot up..."
sleep 5

# Deploy contracts
echo "📦 Deploying contracts..."
# Set environment variables to avoid password prompt
RPC_URL=localhost ETH_KEYSTORE_ACCOUNT="scaffold-eth-default" yarn deploy

echo "✅ Deployment complete."
echo "ℹ️ Chain PID: $CHAIN_PID, Frontend PID: $START_PID"
