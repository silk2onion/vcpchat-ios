#!/bin/bash
# Same native SwiftUI sources; no web server or WebView.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${VCHAT_ARTIFACTS:?Set VCHAT_ARTIFACTS to an absolute output directory}"
mkdir -p "$VCHAT_ARTIFACTS/tmp" "$VCHAT_ARTIFACTS/products"
export TMPDIR="$VCHAT_ARTIFACTS/tmp"
export CLANG_MODULE_CACHE_PATH="$TMPDIR/clang-cache"
swift build --scratch-path "$TMPDIR/build" --cache-path "$TMPDIR/spm-cache"
bin="$TMPDIR/build/debug"
app="$VCHAT_ARTIFACTS/products/VChat Native.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/VChatMac" "$app/Contents/MacOS/VChatMac"
cp -R "$bin/GRDB_GRDB.bundle" "$app/Contents/Resources/"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>app.vcpchat.native</string>
<key>CFBundleExecutable</key><string>VChatMac</string>
<key>CFBundleName</key><string>VChat Native</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.3.0</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict></plist>
PLIST
codesign --force --deep --sign - "$app"
printf '\nMac native app: %s\n' "$app"
