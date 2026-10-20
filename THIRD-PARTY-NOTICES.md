# Third-party notices

## LAME (libmp3lame) — LGPL-2.0 (GNU Library General Public License, version 2)

Used only for "Convert to MP3". The macOS build script copies `libmp3lame.0.dylib`
into `AudioMemo.app/Contents/Frameworks/`; the app loads it at runtime with `dlopen`
(no static linking). You can replace that file with your own build of LAME.

- License text: [`licenses/LGPL-2.0-LAME.txt`](licenses/LGPL-2.0-LAME.txt)
- Source code: https://lame.sourceforge.io/ (the build used is Homebrew's `lame` formula;
  `brew info lame` shows the exact version and source URL)

## mpg123 (libmpg123) — LGPL-2.1

A dependency of the Homebrew LAME build, bundled and loaded the same way.

- License text: [`licenses/COPYING-mpg123.txt`](licenses/COPYING-mpg123.txt)
- Source code: https://www.mpg123.de/ (Homebrew `mpg123` formula)

If you distribute AudioMemo binaries, include this file, the license texts above and a
way to obtain the corresponding LAME / mpg123 source (a link to the exact release is enough).

## Apple frameworks

Core Audio, AudioToolbox, AVFoundation, SwiftUI, AppKit — part of macOS, used under Apple's SDK terms.
