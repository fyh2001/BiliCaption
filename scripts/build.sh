#!/bin/zsh
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="${BILI_CAPTION_BUILD_DIR:-$root/.build}"
token_file="$build_dir/bridge-token"
app="$build_dir/BiliCaption.app"
extension="$build_dir/extension"

mkdir -p "$build_dir" "$app/Contents/MacOS"

if [[ ! -s "$token_file" ]] || ! grep -Eq '^[a-f0-9]{64}$' "$token_file"; then
  openssl rand -hex 32 > "$token_file"
fi
chmod 600 "$token_file"
bridge_token="$(<"$token_file")"

xcrun swiftc \
  -swift-version 5 \
  -target "$(uname -m)-apple-macos13.0" \
  -O \
  "$root/native/CaptionCore.swift" \
  "$root/native/BridgeServer.swift" \
  "$root/native/ListeningLibrary.swift" \
  "$root/native/LocalTranscriber.swift" \
  "$root/native/ModernConsoleDesign.swift" \
  "$root/native/GlassMaterial.swift" \
  "$root/native/DetailController.swift" \
  "$root/native/GlassSettingsPopover.swift" \
  "$root/native/ListeningWindow.swift" \
  "$root/native/IslandWindow.swift" \
  "$root/native/main.swift" \
  -o "$app/Contents/MacOS/BiliCaption"

cp "$root/native/Info.plist" "$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Delete :BiliCaptionBridgeToken" "$app/Contents/Info.plist" >/dev/null 2>&1 || true
/usr/libexec/PlistBuddy -c "Add :BiliCaptionBridgeToken string $bridge_token" "$app/Contents/Info.plist"
codesign --force --sign - "$app"

node "$root/extension/scripts/build.cjs" --out "$extension" --token "$bridge_token"

printf '\nBuilt application: %s\n' "$app"
printf 'Built extension:   %s\n' "$extension"
