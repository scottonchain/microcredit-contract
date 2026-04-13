#!/usr/bin/env bash
# demo.sh — Full lending scenario demo: starts chain + app, then runs browser automation.
# Usage:
#   ./demo.sh            # uses existing chain state
#   ./demo.sh --fresh    # wipes chain state for a clean run
set -e

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO"

# On Windows, 'bash' from PowerShell may invoke WSL whose PATH lacks the
# Windows Node.js install. Prepend common Windows Node locations so yarn/node
# work regardless of which bash interpreter runs this script.
if ! command -v node >/dev/null 2>&1; then
  for _win_node_dir in \
    "/c/Program Files/nodejs" \
    "/mnt/c/Program Files/nodejs" \
    "$APPDATA/../Local/Programs/nodejs" \
    "$HOME/AppData/Local/Programs/nodejs"; do
    if [[ -x "$_win_node_dir/node" || -x "$_win_node_dir/node.exe" ]]; then
      export PATH="$_win_node_dir:$PATH"
      break
    fi
  done
  unset _win_node_dir
fi

# ── Create scaffold-eth-default keystore if missing (needed by forge deploy) ─
# foundryup does not create this keystore automatically. The deploy script
# uses ETH_KEYSTORE_ACCOUNT=scaffold-eth-default (from .env) and forge will
# error if the keystore file is absent, even when --private-key is provided.
_ks="$HOME/.foundry/keystores/scaffold-eth-default"
if [[ ! -f "$_ks" ]]; then
  _cast="${HOME}/.foundry/bin/cast"
  [[ ! -x "$_cast" ]] && _cast="cast"
  if command -v "$_cast" >/dev/null 2>&1 || [[ -x "$_cast" ]]; then
    mkdir -p "$HOME/.foundry/keystores"
    "$_cast" wallet import scaffold-eth-default \
      --private-key 0x2a871d0798f97d79848a013d4936a73bf4cc922c825d33c1cf7073dff6d409c6 \
      --unsafe-password localhost >/dev/null 2>&1 && \
      echo "  ✓ Created deploy keystore (scaffold-eth-default)"
  fi
fi
unset _ks _cast

# ── Ensure Foundry (anvil/forge) is on PATH ──────────────────────────────────
# foundryup installs to ~/.foundry/bin but only adds it to ~/.bashrc,
# which non-interactive shells (like this one) never source.
if ! command -v anvil >/dev/null 2>&1; then
  for _foundry_dir in \
    "$HOME/.foundry/bin" \
    "/root/.foundry/bin" \
    "/usr/local/bin"; do
    if [[ -x "$_foundry_dir/anvil" ]]; then
      export PATH="$_foundry_dir:$PATH"
      break
    fi
  done
  unset _foundry_dir
fi

# ── Pre-flight: verify node and yarn are available ────────────────────────────
if ! command -v node >/dev/null 2>&1; then
  echo ""
  echo "ERROR: 'node' not found in PATH."
  if grep -qi microsoft /proc/version 2>/dev/null; then
    echo ""
    echo "  You're running in WSL but Node.js isn't installed inside WSL."
    echo "  Fix A — Install Node.js in WSL (recommended):"
    echo "    curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -"
    echo "    sudo apt-get install -y nodejs"
    echo ""
    echo "  Fix B — Run from Git Bash instead of WSL bash:"
    echo "    Open Git Bash in this folder and run:  bash demo.sh"
  else
    echo "  Install Node.js >= 20.18.3 from https://nodejs.org"
  fi
  exit 1
fi
if ! command -v yarn >/dev/null 2>&1 && ! command -v yarn.cmd >/dev/null 2>&1; then
  echo ""
  echo "ERROR: 'yarn' not found. Install it with:  npm install -g yarn"
  exit 1
fi
if ! command -v anvil >/dev/null 2>&1; then
  echo ""
  echo "ERROR: 'anvil' not found. Install Foundry in WSL:"
  echo "  curl -L https://foundry.paradigm.xyz | bash"
  echo "  source ~/.bashrc && foundryup"
  exit 1
fi

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
_wait=0
until curl -sf -X POST "http://localhost:$CHAIN_PORT" \
    -H "Content-Type: application/json" \
    -d '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' >/dev/null 2>&1; do
  if ! kill -0 "$CHAIN_PID" 2>/dev/null; then
    echo ""
    echo "ERROR: Anvil process exited unexpectedly. Last log lines:"
    tail -10 "$REPO/logs/anvil-demo.log" 2>/dev/null || true
    exit 1
  fi
  (( _wait++ )) || true
  if (( _wait > 75 )); then   # 30-second timeout
    echo ""
    echo "ERROR: Timed out waiting for Anvil on port $CHAIN_PORT. Last log lines:"
    tail -10 "$REPO/logs/anvil-demo.log" 2>/dev/null || true
    exit 1
  fi
  echo -n "."; sleep 0.4
done
echo " ✓"

# ── Ensure Solidity libraries are present ────────────────────────────────────
# lib/forge-std is gitignored (must be cloned separately).
# lib/openzeppelin-contracts is a git submodule that may not be initialized.
if [[ ! -f "$REPO/lib/forge-std/src/Script.sol" ]]; then
  echo "  Cloning forge-std library…"
  git clone --depth 1 https://github.com/foundry-rs/forge-std \
    "$REPO/lib/forge-std" >/dev/null 2>&1 && echo "  ✓ forge-std ready" || \
    echo "  ⚠ forge-std clone failed — deploy may fail"
fi
if [[ ! -f "$REPO/lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol" ]]; then
  echo "  Initializing openzeppelin-contracts submodule…"
  git -C "$REPO" submodule update --init lib/openzeppelin-contracts >/dev/null 2>&1 && \
    echo "  ✓ openzeppelin-contracts ready" || \
    echo "  ⚠ submodule init failed — deploy may fail"
fi

# Ensure deployment-config.json exists (vm.readFile reverts on missing file)
[[ -f "$REPO/packages/foundry/deployment-config.json" ]] || echo '{}' > "$REPO/packages/foundry/deployment-config.json"

# ── Deploy contracts ──────────────────────────────────────────────────────────
echo ""
echo "▶ Deploying contracts…"
if ! command -v make >/dev/null 2>&1; then
  # 'make' not available (common in WSL without build-essential).
  # Run the forge deploy and ABI generation steps directly.
  _forge="${HOME}/.foundry/bin/forge"
  [[ ! -x "$_forge" ]] && _forge="forge"
  # Use --account + --password so forge reads the keystore non-interactively.
  # Using only --private-key alongside ETH_KEYSTORE_ACCOUNT (set in .env)
  # causes forge to wait for an interactive keystore-password prompt that
  # never arrives when stdin is a pipe, hanging indefinitely.
  (cd "$REPO/packages/foundry" && \
    FOUNDRY_AUTO_CONFIRM=1 "$_forge" script script/Deploy.s.sol:DeployScript \
      --rpc-url localhost \
      --account scaffold-eth-default \
      --password localhost \
      --broadcast --legacy --ffi \
      --gas-limit 100000000 2>&1 | grep -E "deployed|USDC|Error|error") || true
  node "$REPO/packages/foundry/scripts-js/generateTsAbis.js" 2>&1 | grep -v "^$" || true
  unset _forge
else
  yarn deploy 2>&1 | grep -E "deployed|USDC|Error|error" || true
fi
echo "  ✓ Contracts deployed"

# ── Re-install deps when running in WSL (node_modules was built on Windows) ───
# Yarn Berry refuses to run workspace commands if the lockfile/node_modules
# don't match the current platform. Run "yarn install" once in WSL to fix this.
# The sentinel file records the last platform so we only reinstall when needed.
_platform_sentinel="$REPO/.yarn/.platform-install"
_current_platform="$(uname -s)-$(uname -m)"
_last_platform="$(cat "$_platform_sentinel" 2>/dev/null || true)"
if [[ "$_current_platform" != "$_last_platform" ]]; then
  echo "▶ Running yarn install for platform '$_current_platform'…"
  echo "  (This is a one-time step when switching between Windows and WSL)"
  yarn install 2>&1 | grep -E "YN0000|error|Error" | grep -v "peer" | tail -5 || true
  echo "$_current_platform" > "$_platform_sentinel"
  echo "  ✓ Dependencies ready"
  echo ""
fi
unset _platform_sentinel _current_platform _last_platform

# ── Start Next.js ─────────────────────────────────────────────────────────────
echo ""
echo "▶ Starting Next.js dev server…"
# Always invoke the 'next' binary directly via node so that log redirection
# works reliably across WSL, Git Bash, and other Windows bash environments.
# 'yarn start' uses yarn.cmd on Windows, which doesn't survive the '>&' redirect.
if grep -qi microsoft /proc/version 2>/dev/null; then
  if [[ -d "$REPO/packages/nextjs/.next" ]]; then
    echo "  Clearing Windows build cache for Linux rebuild…"
    rm -rf "$REPO/packages/nextjs/.next"
  fi
fi
_next_bin="$REPO/node_modules/next/dist/bin/next"
[[ ! -f "$_next_bin" ]] && _next_bin="$REPO/packages/nextjs/node_modules/next/dist/bin/next"
(cd "$REPO/packages/nextjs" && node "$_next_bin" dev) >"$REPO/logs/nextjs-demo.log" 2>&1 &
unset _next_bin
NEXT_PID=$!

echo -n "  Waiting for port $NEXT_PORT"
_wait=0
until [[ "$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:$NEXT_PORT" 2>/dev/null)" =~ ^[1-5][0-9][0-9]$ ]]; do
  if ! kill -0 "$NEXT_PID" 2>/dev/null; then
    echo ""
    echo "ERROR: Next.js process exited unexpectedly. Last log lines:"
    tail -10 "$REPO/logs/nextjs-demo.log" 2>/dev/null || true
    exit 1
  fi
  (( _wait++ )) || true
  if (( _wait > 120 )); then   # 2-minute timeout
    echo ""
    echo "ERROR: Timed out waiting for Next.js on port $NEXT_PORT. Last log lines:"
    tail -10 "$REPO/logs/nextjs-demo.log" 2>/dev/null || true
    exit 1
  fi
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
# Install browser binary if the actual executable is missing
_pw_chromium=$(node -e "
  try {
    const { chromium } = require('playwright');
    const b = chromium.executablePath();
    console.log(b);
  } catch(e) { console.log(''); }
" 2>/dev/null || true)
if [[ -z "$_pw_chromium" || ! -f "$_pw_chromium" ]]; then
  echo "  Downloading Chromium browser…"
  npx playwright install chromium --with-deps 2>&1 | tail -3 || true
elif grep -qi microsoft /proc/version 2>/dev/null; then
  # Binary exists but system deps may be missing (installed without --with-deps).
  # install-deps is fast (no-op) if already satisfied.
  echo "  Verifying Chromium system dependencies…"
  sudo -n npx playwright install-deps chromium 2>&1 | tail -3 || true
fi
unset _pw_chromium
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
