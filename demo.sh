#!/usr/bin/env bash
# demo.sh — Full lending scenario demo: starts chain + app, then runs browser automation.
# Usage:
#   ./demo.sh            # uses existing chain state
#   ./demo.sh --fresh    # wipes chain state for a clean run
set -e

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO"

CHAIN_PORT=8545
NEXT_PORT=3000
DEMO_DIR="$REPO/scripts/demo"
CHAIN_PID="" NEXT_PID=""

# ── Cleanup on exit / Ctrl-C ─────────────────────────────────────────────────
cleanup() {
  echo ""
  echo "Stopping servers…"
  [[ -n "$CHAIN_PID" ]] && kill "$CHAIN_PID" 2>/dev/null || true
  [[ -n "$NEXT_PID"  ]] && kill "$NEXT_PID"  2>/dev/null || true
  exit 0
}
trap cleanup EXIT INT TERM

echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║   Microcredit Protocol — Live Demo           ║"
echo "╚══════════════════════════════════════════════╝"
echo ""

# ── Optional fresh start ──────────────────────────────────────────────────────
if [[ "${1:-}" == "--fresh" ]]; then
  echo "🗑  Wiping chain state for a fresh demo…"
  rm -f chain-state-demo.json
  echo ""
fi

# ── Kill anything already on these ports ──────────────────────────────────────
for port in $CHAIN_PORT $NEXT_PORT; do
  pid=$(lsof -ti "tcp:$port" 2>/dev/null || true)
  if [[ -n "$pid" ]]; then
    echo "  Killing existing process on port $port (PID $pid)"
    kill "$pid" 2>/dev/null || true
    sleep 0.5
  fi
done

# ── Start Anvil ───────────────────────────────────────────────────────────────
echo "▶ Starting local Anvil chain…"
ANVIL_STATE_FILE="./chain-state-demo.json" yarn chain >"$REPO/logs/anvil-demo.log" 2>&1 &
CHAIN_PID=$!

echo -n "  Waiting for port $CHAIN_PORT"
until curl -sf -X POST "http://localhost:$CHAIN_PORT" \
    -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' >/dev/null 2>&1; do
  echo -n "."; sleep 0.4
done
echo " ✓"

# ── Deploy contracts ──────────────────────────────────────────────────────────
echo ""
echo "▶ Deploying contracts…"
yarn deploy 2>&1 | grep -E "deployed|USDC|Error|error" || true
echo "  ✓ Contracts deployed"

# ── Start Next.js ─────────────────────────────────────────────────────────────
echo ""
echo "▶ Starting Next.js dev server…"
yarn start >"$REPO/logs/nextjs-demo.log" 2>&1 &
NEXT_PID=$!

echo -n "  Waiting for port $NEXT_PORT"
until curl -sf "http://localhost:$NEXT_PORT" >/dev/null 2>&1; do
  echo -n "."; sleep 1
done
echo " ✓"

# ── Install demo dependencies (first run only) ────────────────────────────────
echo ""
echo "▶ Preparing demo runner…"
mkdir -p "$REPO/logs"
cd "$DEMO_DIR"
if [[ ! -d node_modules ]]; then
  echo "  Installing Playwright…"
  npm install --silent
fi
# Install browser binary if not already cached
if ! npx playwright install --list 2>/dev/null | grep -q "chromium"; then
  echo "  Downloading Chromium browser…"
  npx playwright install chromium --with-deps --quiet 2>/dev/null || true
fi
cd "$REPO"

# ── Run the Playwright demo ───────────────────────────────────────────────────
echo ""
echo "▶ Launching browser demo…"
echo ""
node "$DEMO_DIR/lending-demo.mjs"

echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║  Demo complete!                              ║"
echo "║  Chain still running: http://localhost:8545  ║"
echo "║  App  still running:  http://localhost:3000  ║"
echo "║  Press Ctrl-C to stop both servers.          ║"
echo "╚══════════════════════════════════════════════╝"
echo ""
wait
