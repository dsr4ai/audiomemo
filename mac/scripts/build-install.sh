#!/bin/bash
# Build (Release, Hardened Runtime) and install to ~/Applications/AudioMemo.app.
# Signing: AUDIOMEMO_SIGN_IDENTITY (default: first "Apple Development" identity in the keychain, else ad-hoc "-").
# Optional local settings: mac/scripts/local.env (git-ignored).
# MP3 export: bundles libmp3lame + libmpg123 (LGPL, loaded with dlopen). LAME_DIR / MPG123_DIR default to Homebrew.
set -euo pipefail
cd "$(dirname "$0")/.."
[ -f scripts/local.env ] && source scripts/local.env
ID=${AUDIOMEMO_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 "Apple Development" | awk '{print $2}' || true)}
ID=${ID:--}
xcodebuild -project AudioMemo.xcodeproj -scheme AudioMemo -configuration Release \
  -destination "platform=macOS,arch=arm64" -derivedDataPath ../build/mac CODE_SIGN_IDENTITY="$ID" build \
  | grep -E "error:|warning:|BUILD" || true
APP=../build/mac/Build/Products/Release/AudioMemo.app
test -d "$APP"

LAME=${LAME_DIR:-/opt/homebrew/opt/lame/lib}/libmp3lame.0.dylib
MPG=${MPG123_DIR:-/opt/homebrew/opt/mpg123/lib}/libmpg123.0.dylib
if [ -f "$LAME" ] && [ -f "$MPG" ]; then
  FW="$APP/Contents/Frameworks"; mkdir -p "$FW"
  cp -f "$LAME" "$MPG" "$FW/"; chmod u+w "$FW"/*.dylib
  install_name_tool -id @rpath/libmp3lame.0.dylib "$FW/libmp3lame.0.dylib" 2>/dev/null
  MPG_OLD=$(otool -L "$FW/libmp3lame.0.dylib" | awk '/libmpg123/{print $1}')
  [ -n "$MPG_OLD" ] && install_name_tool -change "$MPG_OLD" @loader_path/libmpg123.0.dylib "$FW/libmp3lame.0.dylib" 2>/dev/null
  install_name_tool -id @rpath/libmpg123.0.dylib "$FW/libmpg123.0.dylib" 2>/dev/null
  codesign --force --options runtime --sign "$ID" "$FW"/*.dylib
  codesign --force --options runtime --sign "$ID" --preserve-metadata=identifier,entitlements,requirements "$APP"
else
  echo "⚠ LAME not found (brew install lame) — MP3 export will be unavailable"
fi

mkdir -p ~/Applications
osascript -e 'tell application "AudioMemo" to quit' >/dev/null 2>&1 || true
sleep 1
rm -rf ~/Applications/AudioMemo.app
ditto "$APP" ~/Applications/AudioMemo.app
codesign --verify --deep --strict ~/Applications/AudioMemo.app && echo "installed: ~/Applications/AudioMemo.app"
