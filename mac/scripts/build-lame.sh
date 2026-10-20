#!/bin/bash
# Build LAME (libmp3lame, LGPL) from the official source as a universal (arm64 + x86_64) dylib
# for macOS 14.4+, without the mpg123 decoder. Output: ../build/lame/lib/libmp3lame.0.dylib
# The app loads it at runtime with dlopen (it stays a separate, replaceable library — LGPL).
set -euo pipefail
cd "$(dirname "$0")/.."
VER=4.0
SHA=3df5124d5ad3a98312ffd7ba6a9b36230e4f8a3e66d3ce0f425e336c32d216eb
OUT="$(cd .. && pwd)/build/lame"
SRC="$(cd .. && pwd)/build/lame-src"
mkdir -p "$SRC"
cd "$SRC"
[ -f lame-$VER.tar.gz ] || curl -sSL -o lame-$VER.tar.gz "https://downloads.sourceforge.net/project/lame/lame/$VER/lame-$VER.tar.gz"
echo "$SHA  lame-$VER.tar.gz" | shasum -a 256 -c
rm -rf lame-$VER && tar xzf lame-$VER.tar.gz && cd lame-$VER
export MACOSX_DEPLOYMENT_TARGET=14.4
FLAGS="-O2 -arch arm64 -arch x86_64 -mmacosx-version-min=14.4"
PKG_CONFIG=/usr/bin/true ./configure --prefix="$OUT" --disable-frontend --disable-decoder --enable-shared --disable-static \
  CFLAGS="$FLAGS" LDFLAGS="-arch arm64 -arch x86_64 -mmacosx-version-min=14.4" > configure.log
make -j"$(sysctl -n hw.ncpu)" > make.log && make install > install.log
lipo -archs "$OUT/lib/libmp3lame.0.dylib"
echo "built: $OUT/lib/libmp3lame.0.dylib"
