#!/bin/bash
set -euo pipefail
# Explicit output directory keeps synthetic documents and test output out of user folders.
if [[ $# != 1 ]]; then echo "Usage: bash scripts/test-connected-folders.sh /absolute/artifact-directory" >&2; exit 2; fi
case "$1" in /*) ;; *) echo 'Output directory must be absolute' >&2; exit 2;; esac
archive="$1"
mkdir -p "$archive/tmp" "$archive/fixtures"
export TMPDIR="$archive/tmp"
source_root="$(cd "$(dirname "$0")/.." && pwd)"
xcrun swiftc -swift-version 5 -parse-as-library -module-cache-path "$archive/tmp/swift-cache" \
  "$source_root/src-tauri/apple/ConnectedFolders.swift" \
  "$source_root/src-tauri/apple/tests/ConnectedFoldersTests.swift" \
  -o "$archive/tmp/native-folder-tests"
"$archive/tmp/native-folder-tests" "$archive/fixtures"
