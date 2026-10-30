#!/usr/bin/env bash
# Install and launch the actual simulator bundle, retaining its first-screen evidence.
set -euo pipefail
app="${1:?Usage: smoke-ios-simulator.sh app-path results-directory}"
results="${2:?Usage: smoke-ios-simulator.sh app-path results-directory}"
mkdir -p "$results"
test -f "$app/Info.plist"
bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Info.plist")
xcrun simctl list devices available --json > "$results/simulator-devices.json"
device=$(node --input-type=module - "$results/simulator-devices.json" <<'NODE'
import fs from 'node:fs';
const { devices } = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const candidates = Object.entries(devices)
  .filter(([runtime]) => runtime.includes('.iOS-'))
  .sort(([a], [b]) => b.localeCompare(a, undefined, { numeric: true }))
  .flatMap(([, list]) => list.filter(d => d.isAvailable && d.name.startsWith('iPhone')));
if (!candidates.length) throw new Error('No available iPhone simulator runtime');
const chosen = candidates.find(d => d.state === 'Booted') ?? candidates[0];
console.error(`Simulator: ${chosen.name} (${chosen.udid}), ${chosen.state}`);
process.stdout.write(`${chosen.udid} ${chosen.state}`);
NODE
)
read -r udid state <<< "$device"
if [[ "$state" != Booted ]]; then xcrun simctl boot "$udid"; fi
xcrun simctl bootstatus "$udid" -b
xcrun simctl install "$udid" "$app"
xcrun simctl launch "$udid" "$bundle_id" | tee "$results/simulator-launch.log"
# Give the initial WKWebView a chance to render before collecting the first screen.
sleep 8
xcrun simctl io "$udid" screenshot "$results/simulator-first-screen.png"
xcrun simctl spawn "$udid" launchctl list > "$results/simulator-processes.log"
grep -F "$bundle_id" "$results/simulator-processes.log"
