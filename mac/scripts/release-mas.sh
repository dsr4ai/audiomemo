#!/bin/bash
# Mac App Store build: universal, App Sandbox, Apple Distribution signature + embedded profile,
# packaged with productbuild (Mac Installer Distribution) and validated with altool. Does NOT upload
# unless AUDIOMEMO_MAS_UPLOAD=1.
#
# Environment (or mac/scripts/local.env, git-ignored):
#   AUDIOMEMO_TEAM_ID         Apple developer team ID
#   AUDIOMEMO_MAS_PROFILE     path to the "Mac App Store" .provisionprofile for com.bookai.audiomemo
#   AUDIOMEMO_NOTARY_KEY      App Store Connect API key (.p8)
#   AUDIOMEMO_NOTARY_KEY_ID   key ID
#   AUDIOMEMO_NOTARY_ISSUER   issuer ID
#   AUDIOMEMO_VERSION (default 0.1), AUDIOMEMO_BUILD (default 1)
set -euo pipefail
cd "$(dirname "$0")/.."
[ -f scripts/local.env ] && source scripts/local.env
: "${AUDIOMEMO_TEAM_ID:?}" "${AUDIOMEMO_MAS_PROFILE:?}" "${AUDIOMEMO_NOTARY_KEY:?}" "${AUDIOMEMO_NOTARY_KEY_ID:?}" "${AUDIOMEMO_NOTARY_ISSUER:?}"
VERSION=${AUDIOMEMO_VERSION:-0.1}; BUILD=${AUDIOMEMO_BUILD:-1}
BUNDLE_ID=com.bookai.audiomemo
APPSIGN=$(security find-identity -v -p codesigning | grep -m1 "Apple Distribution" | awk '{print $2}')
PKGSIGN=$(security find-identity -v | grep -m1 -E "3rd Party Mac Developer Installer|Mac Installer Distribution" | sed -E 's/.*"(.*)"/\1/')
[ -n "$APPSIGN" ] && [ -n "$PKGSIGN" ] || { echo "⛔ need Apple Distribution + Mac Installer Distribution identities"; exit 1; }
OUT=../build/mas; rm -rf "$OUT"; mkdir -p "$OUT"

# 1) universal build (signed ad-hoc here; the real signature is applied below)
xcodebuild -project AudioMemo.xcodeproj -scheme AudioMemo -configuration Release -destination "generic/platform=macOS" \
  -derivedDataPath ../build/mac-mas MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO build | grep -E " error:|BUILD" || true
APP="$OUT/AudioMemo.app"
ditto ../build/mac-mas/Build/Products/Release/AudioMemo.app "$APP"
lipo -archs "$APP/Contents/MacOS/AudioMemo"

# 2) entitlements = sandbox entitlements + identifiers matching the profile
ENT="$OUT/entitlements.plist"
cp Support/AudioMemo-MAS.entitlements "$ENT"
/usr/libexec/PlistBuddy -c "Add :com.apple.application-identifier string $AUDIOMEMO_TEAM_ID.$BUNDLE_ID" "$ENT"
/usr/libexec/PlistBuddy -c "Add :com.apple.developer.team-identifier string $AUDIOMEMO_TEAM_ID" "$ENT"
cp "$AUDIOMEMO_MAS_PROFILE" "$APP/Contents/embedded.provisionprofile"

# 3) sign: LAME dylib, then the app
scripts/bundle-lame.sh "$APP" "$APPSIGN"
codesign --force --timestamp --options runtime --entitlements "$ENT" --sign "$APPSIGN" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -d --entitlements - "$APP" | grep -E "app-sandbox|application-identifier" || true

# 4) installer package
PKG="$OUT/AudioMemo-$VERSION-$BUILD.pkg"
productbuild --component "$APP" /Applications --sign "$PKGSIGN" "$PKG"
pkgutil --check-signature "$PKG" | head -3

# 5) validate (and optionally upload) with the API key
KEYDIR="$OUT/private_keys"; mkdir -p "$KEYDIR"; ln -sf "$AUDIOMEMO_NOTARY_KEY" "$KEYDIR/AuthKey_$AUDIOMEMO_NOTARY_KEY_ID.p8"
export API_PRIVATE_KEYS_DIR="$KEYDIR"
xcrun altool --validate-app -f "$PKG" -t macos --apiKey "$AUDIOMEMO_NOTARY_KEY_ID" --apiIssuer "$AUDIOMEMO_NOTARY_ISSUER"
if [ "${AUDIOMEMO_MAS_UPLOAD:-0}" = 1 ]; then
  xcrun altool --upload-app -f "$PKG" -t macos --apiKey "$AUDIOMEMO_NOTARY_KEY_ID" --apiIssuer "$AUDIOMEMO_NOTARY_ISSUER"
fi
rm -rf "$KEYDIR"
echo "package: $PKG"
