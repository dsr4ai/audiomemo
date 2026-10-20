#!/bin/bash
# Copy libmp3lame into <app>/Contents/Frameworks and sign it with the given identity.
# Usage: bundle-lame.sh <AudioMemo.app> <signing identity>
# LAME_DYLIB overrides the source (default: ../build/lame/lib/libmp3lame.0.dylib from build-lame.sh).
set -euo pipefail
APP=$1; ID=$2
HERE="$(cd "$(dirname "$0")/.." && pwd)"
LAME=${LAME_DYLIB:-$HERE/../build/lame/lib/libmp3lame.0.dylib}
if [ ! -f "$LAME" ]; then echo "⚠ $LAME missing — run mac/scripts/build-lame.sh (MP3 export will be unavailable)"; exit 0; fi
FW="$APP/Contents/Frameworks"; mkdir -p "$FW"
rm -f "${FW:?}/libmpg123.0.dylib"   # older builds bundled mpg123; LAME is now built without the decoder
cp -f "$LAME" "$FW/libmp3lame.0.dylib"; chmod u+w "$FW/libmp3lame.0.dylib"
install_name_tool -id @rpath/libmp3lame.0.dylib "$FW/libmp3lame.0.dylib" 2>/dev/null
codesign --force --timestamp=none --options runtime --sign "$ID" "$FW/libmp3lame.0.dylib"
