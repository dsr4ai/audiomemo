#!/bin/bash
# Build the App Sandbox (Mac App Store) variant signed for local testing (Apple Development)
# and install it as ~/Applications/AudioMemo-Sandbox.app. Needs AUDIOMEMO_TEAM_ID (env or scripts/local.env).
set -euo pipefail
cd "$(dirname "$0")/.."
[ -f scripts/local.env ] && source scripts/local.env
: "${AUDIOMEMO_TEAM_ID:?set AUDIOMEMO_TEAM_ID}"
ID=${AUDIOMEMO_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | grep -m1 "Apple Development" | awk '{print $2}')}
xcodebuild -project AudioMemo.xcodeproj -scheme AudioMemo -configuration Release -destination "platform=macOS,arch=arm64" \
  -derivedDataPath ../build/mac-sandbox CODE_SIGN_IDENTITY="$ID" DEVELOPMENT_TEAM="$AUDIOMEMO_TEAM_ID" \
  CODE_SIGN_ENTITLEMENTS=Support/AudioMemo-MAS.entitlements build | grep -E " error:|BUILD" || true
APP=../build/mac-sandbox/Build/Products/Release/AudioMemo.app
scripts/bundle-lame.sh "$APP" "$ID"
codesign --force --options runtime --sign "$ID" --entitlements Support/AudioMemo-MAS.entitlements "$APP"
rm -rf ~/Applications/AudioMemo-Sandbox.app
ditto "$APP" ~/Applications/AudioMemo-Sandbox.app
echo "installed: ~/Applications/AudioMemo-Sandbox.app"
