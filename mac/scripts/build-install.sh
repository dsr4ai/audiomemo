#!/bin/bash
# Build (Release, Hardened Runtime) and install to ~/Applications/AudioMemo.app.
# Signing: AUDIOMEMO_SIGN_IDENTITY (default: first "Apple Development" identity in the keychain, else ad-hoc "-").
# Optional local settings: mac/scripts/local.env (git-ignored).
# MP3 export: bundles libmp3lame (LGPL, loaded with dlopen) built by scripts/build-lame.sh.
set -euo pipefail
cd "$(dirname "$0")/.."
[ -f scripts/local.env ] && source scripts/local.env
ID=${AUDIOMEMO_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 "Apple Development" | awk '{print $2}' || true)}
ID=${ID:--}
xcodebuild -project AudioMemo.xcodeproj -scheme AudioMemo -configuration Release \
  -destination "platform=macOS,arch=arm64" -derivedDataPath ../build/mac CODE_SIGN_IDENTITY="$ID" ${AUDIOMEMO_TEAM_ID:+DEVELOPMENT_TEAM=$AUDIOMEMO_TEAM_ID} build \
  | grep -E "error:|warning:|BUILD" || true
APP=../build/mac/Build/Products/Release/AudioMemo.app
test -d "$APP"

scripts/bundle-lame.sh "$APP" "$ID"
codesign --force --options runtime --sign "$ID" --preserve-metadata=identifier,entitlements,requirements "$APP"

mkdir -p ~/Applications
osascript -e 'tell application "AudioMemo" to quit' >/dev/null 2>&1 || true
sleep 1
rm -rf ~/Applications/AudioMemo.app
ditto "$APP" ~/Applications/AudioMemo.app
codesign --verify --deep --strict ~/Applications/AudioMemo.app && echo "installed: ~/Applications/AudioMemo.app"
