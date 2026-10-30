#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
: "${VCHAT_ARTIFACTS:?Set VCHAT_ARTIFACTS to an absolute test-output directory}"
mkdir -p "$VCHAT_ARTIFACTS/tmp" "$VCHAT_ARTIFACTS/results"
export TMPDIR="$VCHAT_ARTIFACTS/tmp"
export CLANG_MODULE_CACHE_PATH="$TMPDIR/clang-cache"
export VCHAT_TEST_ARTIFACTS="$TMPDIR/databases"
mkdir -p "$VCHAT_TEST_ARTIFACTS"
ready="$TMPDIR/fixture-$$.url"
node scripts/protocol-fixture.mjs "$ready" > "$VCHAT_ARTIFACTS/results/fixture.log" 2>&1 &
fixture=$!
cleanup() { kill "$fixture" 2>/dev/null || true; wait "$fixture" 2>/dev/null || true; rm -f "$ready"; }
trap cleanup EXIT
for i in {1..100}; do [[ -s "$ready" ]] && break; kill -0 "$fixture"; sleep 0.05; done
export VCHAT_FIXTURE_URL="$(cat "$ready")"
swift test --scratch-path "$TMPDIR/build" --cache-path "$TMPDIR/spm-cache" "$@"
