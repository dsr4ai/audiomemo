# Third-party notices

## LAME (libmp3lame) — LGPL-2.0 (GNU Library General Public License, version 2)

Used only for "Convert to MP3". `mac/scripts/build-lame.sh` builds LAME 4.0 from the official source
(SHA-256 checked, decoder disabled, universal arm64 + x86_64, macOS 14.4+). The build scripts copy
`libmp3lame.0.dylib` into `AudioMemo.app/Contents/Frameworks/`; the app loads it at runtime with
`dlopen` (no static linking), so the library can be replaced with another build of LAME.

- License text: [`licenses/LGPL-2.0-LAME.txt`](licenses/LGPL-2.0-LAME.txt)
- Source code: https://lame.sourceforge.io/ — exact archive: https://downloads.sourceforge.net/project/lame/lame/4.0/lame-4.0.tar.gz

If you distribute AudioMemo binaries, include this file, the license text and the source link above.

## Apple frameworks

Core Audio, AudioToolbox, AVFoundation, SwiftUI, AppKit — part of macOS, used under Apple's SDK terms.
