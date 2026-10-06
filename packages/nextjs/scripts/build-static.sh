#!/usr/bin/env bash
# Static export of the app against the live Base Sepolia pool, with no relayer: every page uses
# wallet-direct calls. Output in out/. Serve it from any static host; set NEXT_PUBLIC_BASE_PATH=/pool
# (no trailing slash) when it lives under a sub-path such as a GitHub Pages project site.
#
# The target chain is a literal in scaffold.target.ts so that the contract types follow it; this script
# swaps that file for Base Sepolia for the duration of the build and restores it whatever happens.
set -euo pipefail
cd "$(dirname "$0")/.."
TARGET=scaffold.target.ts
cp "$TARGET" "$TARGET.local"
restore() { mv -f "$TARGET.local" "$TARGET"; }
trap restore EXIT
cat > "$TARGET" <<'TS'
import * as chains from "viem/chains";

/** Written by scripts/build-static.sh for the duration of the static export: the live Base Sepolia pool. */
export const TARGET_CHAIN = chains.baseSepolia;
TS
export NEXT_PUBLIC_RELAYER_DISABLED=true
export NEXT_PUBLIC_IPFS_BUILD=true
export NEXT_PUBLIC_BUILD_COMMIT="${NEXT_PUBLIC_BUILD_COMMIT:-$(git rev-parse --short HEAD)}"
export NEXT_PUBLIC_BASE_PATH="${NEXT_PUBLIC_BASE_PATH:-}"
rm -rf out
yarn build
echo "static export written to out/ (Base Sepolia, commit ${NEXT_PUBLIC_BUILD_COMMIT}, base path '${NEXT_PUBLIC_BASE_PATH}')"
