#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "模拟器构建需要 macOS 和 Xcode。" >&2
  exit 1
fi
rustup target add aarch64-apple-ios-sim
if [[ ! -d src-tauri/gen/apple ]]; then
  pnpm exec tauri ios init --ci --skip-targets-install
fi
bash scripts/patch-ios-plist.sh
pnpm exec tauri ios build --debug --target aarch64-sim --ci -- --locked
app="$(find src-tauri/gen/apple -path '*iphonesimulator*' -name '*.app' -type d | head -n 1 || true)"
echo "模拟器构建完成${app:+: $app}"
