#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/bitchord-automix-startup.XXXXXX")"
trap 'rm -rf "$check_dir"' EXIT
xcrun swiftc -parse-as-library -swift-version 5 \
  AppleApp/Sources/PlaybackSession/AutomixReadiness.swift \
  AppleApp/Sources/PlaybackSession/AutomixModelLoader.swift \
  scripts/automix-startup-verify/check.swift -o "$check_dir/check"
"$check_dir/check"
