#!/bin/zsh
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="${BILI_CAPTION_TEST_DIR:-$root/.build/tests}"
extension="$test_dir/extension"

mkdir -p "$test_dir"
test_token="$(openssl rand -hex 32)"

node "$root/extension/scripts/build.cjs" --out "$extension" --token "$test_token"
BILI_CAPTION_EXTENSION_DIR="$extension" node --test "$root/extension/tests/bridge.test.cjs"

xcrun swiftc \
  -swift-version 5 \
  -target "$(uname -m)-apple-macos13.0" \
  "$root/native/CaptionCore.swift" \
  "$root/tests/native/main.swift" \
  -o "$test_dir/caption-core-tests"

"$test_dir/caption-core-tests"
