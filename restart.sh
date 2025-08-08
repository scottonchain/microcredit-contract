#!/bin/bash

# Start fresh with no saved state
# ./restart.sh --nostate

# Kill only
# ./restart.sh --kill

# Fresh start and remove old chain state
# ./restart.sh --kill --nostate

# Exit on error
set -e

# Handle flags
KILL_ONLY=false
DELETE_STATE=false
REDEPLOY_USDC=false

for arg in "$@"; do
  case $arg in
    --kill)
      KILL_ONLY=true
      ;;
    --nostate)
      DELETE_STATE=true
      ;;
    --redeploy-usdc|--force-usdc)
      REDEPLOY_USDC=true
      ;;
  esac
done

# Kill existing processes if requested or before fresh start
echo "🔪 Killing existing Hardhat node and frontend processes..."

# Kill Hardhat node processes more specifically
pkill -f "hardhat.*node" || true
pkill -f "bootstrap.js node" || true
pkill -f "yarn.*hardhat.*chain" || true
pkill -f "workspace.*hardhat.*chain" || true
pkill -f "yarn chain" || true

# Kill frontend processes
pkill -f "yarn start" || true
pkill -f "next dev" || true
pkill -f "next-server" || true

# Alternative approach: Kill processes using port 8545 (Hardhat default)
echo "🔍 Checking for processes using port 8545..."
PORT_PIDS=$(netstat -tlnp 2>/dev/null | grep ":8545 " | awk '{print $7}' | cut -d'/' -f1 | grep -v '-' || true)
if [ ! -z "$PORT_PIDS" ]; then
    echo "🎯 Found processes using port 8545: $PORT_PIDS"
    for pid in $PORT_PIDS; do
        if [ ! -z "$pid" ] && [ "$pid" != "-" ]; then
            echo "   Killing PID: $pid"
            kill -9 "$pid" 2>/dev/null || true
        fi
    done
fi

# Give processes time to terminate
sleep 2

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
yarn hardhat:clean || true

# Start local Hardhat blockchain
echo "🚀 Starting Hardhat local blockchain..."
yarn hardhat:chain &

CHAIN_PID=$!

# Start frontend
echo "🖥️ Starting frontend..."
yarn start &

START_PID=$!

# Wait for chain to boot up
echo "⏳ Waiting for Hardhat node to boot up..."
sleep 8

# Deploy contracts using Hardhat
echo "📦 Deploying contracts with Hardhat..."
if [ "$REDEPLOY_USDC" = true ]; then
  echo "🔄 Force redeploying MockUSDC (--redeploy-usdc flag detected)"
  REDEPLOY_USDC=true yarn hardhat:deploy
else
  yarn hardhat:deploy
fi

echo "✅ Deployment complete."
echo "ℹ️ Hardhat Chain PID: $CHAIN_PID, Frontend PID: $START_PID"
echo "🌐 Hardhat node running on http://localhost:8545"
echo "🖥️ Frontend running on http://localhost:3000"
