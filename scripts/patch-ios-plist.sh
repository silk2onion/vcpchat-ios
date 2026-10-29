#!/usr/bin/env bash
# Merge the local-network and cleartext exceptions the VCP server needs.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
plist="$(find "$root/src-tauri/gen/apple" -name Info.plist -not -path '*/build/*' | head -n 1 || true)"
if [[ -z "$plist" ]]; then
  echo "找不到 Info.plist。请先在 macOS 上运行 pnpm tauri ios init --ci" >&2
  exit 1
fi
buddy=/usr/libexec/PlistBuddy
add_or_set() {
  local key="$1"
  local type="$2"
  local value="$3"
  if ! "$buddy" -c "Add ${key} ${type} ${value}" "$plist" >/dev/null 2>&1; then
    "$buddy" -c "Set ${key} ${value}" "$plist"
  fi
}
add_or_set ":NSAppTransportSecurity" "dict" ""
add_or_set ":NSAppTransportSecurity:NSAllowsArbitraryLoads" "bool" "true"
add_or_set ":NSAppTransportSecurity:NSAllowsLocalNetworking" "bool" "true"
add_or_set ":NSLocalNetworkUsageDescription" "string" "用于连接你自己的 VCPToolBox 服务器"
add_or_set ":NSPhotoLibraryUsageDescription" "string" "用于把相册图片作为对话附件"
echo "已写入传输与相册说明: $plist"
