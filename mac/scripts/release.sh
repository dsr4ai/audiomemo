#!/bin/bash
# 產出給同事試用的 DMG：Developer ID 簽章（Hardened Runtime）→ 公證 → staple → DMG（也簽＋公證＋staple）→ ~/Desktop/AudioMemo-0.1.dmg
# Requires a "Developer ID Application" identity in the keychain.
# Notarization uses an App Store Connect API key, passed only through environment variables:
#   AUDIOMEMO_NOTARY_KEY      path to the .p8 key file
#   AUDIOMEMO_NOTARY_KEY_ID   key ID
#   AUDIOMEMO_NOTARY_ISSUER   issuer ID
# (Optional) AUDIOMEMO_SIGN_IDENTITY to pick a specific Developer ID identity. Local values can live in
# mac/scripts/local.env (git-ignored).
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=0.1
[ -f scripts/local.env ] && source scripts/local.env
IDENTITY=${AUDIOMEMO_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | grep -m1 "Developer ID Application" | awk '{print $2}' || true)}
[ -n "$IDENTITY" ] || { echo "⛔ 鑰匙圈沒有 Developer ID Application 憑證（見 README「發布」）"; exit 1; }
: "${AUDIOMEMO_NOTARY_KEY:?set AUDIOMEMO_NOTARY_KEY}" "${AUDIOMEMO_NOTARY_KEY_ID:?set AUDIOMEMO_NOTARY_KEY_ID}" "${AUDIOMEMO_NOTARY_ISSUER:?set AUDIOMEMO_NOTARY_ISSUER}"
NOTARY=(--key "$AUDIOMEMO_NOTARY_KEY" --key-id "$AUDIOMEMO_NOTARY_KEY_ID" --issuer "$AUDIOMEMO_NOTARY_ISSUER")
OUT=../build/release; rm -rf "$OUT"; mkdir -p "$OUT"

# 1) build (Hardened Runtime, Developer ID, app icon from the asset catalog)
xcodebuild -project AudioMemo.xcodeproj -scheme AudioMemo -configuration Release -destination "platform=macOS,arch=arm64" \
  -derivedDataPath ../build/mac-release ENABLE_HARDENED_RUNTIME=YES CODE_SIGN_IDENTITY="$IDENTITY" \
  CODE_SIGN_ENTITLEMENTS=Support/AudioMemo.entitlements OTHER_CODE_SIGN_FLAGS="--timestamp" build | grep -E "error:|BUILD" || true
APP="$OUT/AudioMemo.app"
ditto ../build/mac-release/Build/Products/Release/AudioMemo.app "$APP"

# 2) bundle LAME (LGPL, dlopen) signed with the same Developer ID (library validation stays on)
scripts/bundle-lame.sh "$APP" "$IDENTITY"
codesign --force --timestamp --options runtime --sign "$IDENTITY" "$APP/Contents/Frameworks/libmp3lame.0.dylib"
codesign --force --timestamp --options runtime --entitlements Support/AudioMemo.entitlements --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

# 3) App 公證＋staple
ditto -c -k --keepParent "$APP" "$OUT/AudioMemo.zip"
xcrun notarytool submit "$OUT/AudioMemo.zip" "${NOTARY[@]}" --wait
xcrun stapler staple "$APP"

# 4) DMG（AudioMemo.app＋「應用程式」捷徑＋使用說明）→ 簽＋公證＋staple
STAGE="$OUT/dmg"; mkdir -p "$STAGE"
ditto "$APP" "$STAGE/AudioMemo.app"
ln -s /Applications "$STAGE/應用程式（把 AudioMemo 拖到這裡）"
cp "Support/dmg/使用說明.txt" "$STAGE/"
DMG="$HOME/Desktop/AudioMemo-$VERSION.dmg"; rm -f "$DMG"
hdiutil create -volname "AudioMemo $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"
xcrun notarytool submit "$DMG" "${NOTARY[@]}" --wait
xcrun stapler staple "$DMG"
cp "Support/dmg/使用說明.txt" "$HOME/Desktop/AudioMemo-$VERSION.txt"

# 5) 驗證
spctl -a -vv "$APP"
spctl -a -vv -t open --context context:primary-signature "$DMG"
# 6) Remove the intermediate app copies so Spotlight only finds the installed one (the DMG keeps the shipped build)
rm -rf "$APP" "$STAGE" ../build/mac-release/Build/Products
echo "完成：$DMG"
