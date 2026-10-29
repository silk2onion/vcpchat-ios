#!/usr/bin/env bash
# Unsigned device archive, then a Payload zip Sideloadly / AltStore can re-sign.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "未签名 IPA 需要 macOS 和 Xcode。Linux 上请运行 pnpm check。" >&2
  exit 1
fi
rustup target add aarch64-apple-ios
if [[ ! -d src-tauri/gen/apple ]]; then
  pnpm exec tauri ios init --ci --skip-targets-install
fi
bash scripts/patch-ios-plist.sh
pnpm exec tauri ios build --debug --target aarch64 --archive-only --no-sign --ci -- --locked
archive="$(find src-tauri/gen/apple -name '*.xcarchive' -type d | head -n 1)"
if [[ -z "$archive" ]]; then
  echo "构建结束但没有 xcarchive" >&2
  exit 1
fi
app="$(find "$archive/Products/Applications" -name '*.app' -type d | head -n 1)"
if [[ -z "$app" ]]; then
  echo "归档里没有 .app" >&2
  exit 1
fi
stage="$(mktemp -d)"
mkdir -p "$stage/Payload" "$root/dist-ios"
cp -R "$app" "$stage/Payload/"
out="$root/dist-ios/VCPChat-unsigned.ipa"
rm -f "$out"
(cd "$stage" && zip -qry "$out" Payload)
rm -rf "$stage"
echo "未签名 IPA: $out"
