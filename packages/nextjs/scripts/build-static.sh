#!/usr/bin/env bash
# Build the wallet-direct Base Sepolia release. Publication is a separate operation.
set -euo pipefail
cd "$(dirname "$0")/.."

# scaffold.target.ts is deliberately literal so the generated contract types follow it.
# Serialize this temporary swap and retain the previous usable export if the build fails.
lock=.static-build-lock
if ! mkdir "$lock" 2>/dev/null; then
  echo "A static build already owns scaffold.target.ts; finish it before starting another." >&2
  exit 1
fi
if ! backup=$(mktemp -d "$lock/backup.XXXXXX"); then
  rmdir "$lock"
  exit 1
fi
build_started=false
target_saved=false
restore() {
  status=$?
  trap - EXIT
  if [[ "$target_saved" == true ]]; then
    # Keep a fresh mtime so file watchers invalidate the temporary chain value.
    cp "$backup/scaffold.target.ts" scaffold.target.ts
  fi
  if [[ $status -ne 0 ]]; then
    # A signal can arrive after mv finishes but before build_started is set.
    if [[ -e "$backup/out" || -L "$backup/out" ]]; then
      rm -rf out
      mv "$backup/out" out
    elif [[ "$build_started" == true ]]; then
      rm -rf out
    fi
  fi
  rm -rf "$backup"
  rmdir "$lock"
  exit "$status"
}
trap restore EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
cp -p scaffold.target.ts "$backup/scaffold.target.ts"
target_saved=true
if [[ -e out ]]; then mv out "$backup/out"; fi
build_started=true
cat > scaffold.target.ts <<'TS'
import * as chains from "viem/chains";

/** Temporary target written by scripts/build-static.sh and restored when it finishes. */
export const TARGET_CHAIN = chains.baseSepolia;
TS
export NEXT_PUBLIC_RELAYER_DISABLED=true
export NEXT_PUBLIC_IPFS_BUILD=true
export NEXT_PUBLIC_BUILD_COMMIT="${NEXT_PUBLIC_BUILD_COMMIT:-$(git rev-parse --short HEAD)}"
export NEXT_PUBLIC_BASE_PATH="${NEXT_PUBLIC_BASE_PATH:-}"
yarn build
echo "static export written to out/ (Base Sepolia, commit ${NEXT_PUBLIC_BUILD_COMMIT}, base path '${NEXT_PUBLIC_BASE_PATH}')"
