# AudioMemo

*Made by [BookAI](https://bookai.com) · BookAI 出品*

**Record every sound on your computer — meetings, videos, anything — together with your microphone, into one file.**

AudioMemo is a small, free, open-source recorder. It captures the system audio mix (whatever any app plays, whether you listen on AirPods, wired headphones, Bluetooth or built-in speakers) plus your microphone, and saves an `.m4a` on your own disk. No account, no upload, no AI.

> Screenshots: _(to be added)_

## Features (macOS)

- System audio + microphone in one recording (AAC 256 kbps, 48 kHz, stereo mix)
- Pause / resume, per-track mute, live level meters
- Automatic level balancing (quiet voices brought up, background noise not amplified), peak limiter
- Microphone follows the system (and the mic your call app uses); switching devices never stops a recording
- Recordings list: play inside the app, rename inline, share, show in Finder, convert to MP3 / WAV / FLAC / AIFF
- Menu-bar control, light & dark mode, 13 languages (more coming; see `i18n/`)
- Loudspeaker echo cancellation (experimental, off by default — see `docs/TESTING.md`)

Windows is planned (`windows/`), sharing the portable C core in `core/`.

## Repository layout

| Path | What |
|---|---|
| `mac/` | macOS app (SwiftUI + AppKit, Core Audio process tap) |
| `windows/` | Windows plan (WASAPI loopback + microphone) |
| `core/` | Portable C11 audio processing: echo canceller, level balancer, limiter, unit tests, offline WAV tool |
| `i18n/` | Shared UI strings (source of truth for every platform) |
| `design/` | Colors, type scale, icon sources |
| `test-audio/` | Synthetic test sounds only (no real-person recordings) |
| `scripts/` | Verification scripts |
| `docs/` | Architecture and test standards |

## Build (macOS 14.4+, Xcode 16+)

```bash
make -C core test                     # portable core unit tests
python3 scripts/gen_strings.py        # i18n/ → mac String Catalogs (already committed)
mac/scripts/build-lame.sh             # optional: LAME for MP3 export (LGPL, separate dylib)
mac/scripts/build-install.sh          # Release build → ~/Applications/AudioMemo.app
open ~/Applications/AudioMemo.app
```

Signing: `AUDIOMEMO_SIGN_IDENTITY` (defaults to your "Apple Development" identity, or ad-hoc `-`).
MP3 export uses LAME, built from source by `mac/scripts/build-lame.sh` and bundled as a separate LGPL library — see `THIRD-PARTY-NOTICES.md`.
Mac App Store build (App Sandbox): `mac/scripts/release-mas.sh`; Developer ID build: `mac/scripts/release.sh`.

## Permissions

The first time you record, macOS asks twice — click **Allow** both times:

1. **Microphone** — your voice.
2. **System audio recording** — the sound other apps play.

If you clicked "Don't Allow": System Settings › Privacy & Security › *Microphone*, and *Screen & System Audio Recording › System Audio Recording Only*.

## Privacy

AudioMemo records only when you press record, keeps files on your Mac (`~/Music/AudioMemo` by default), never uploads anything and collects no analytics. "Transcribe" simply opens a web page in your browser and selects the file in Finder; nothing is sent by the app itself.

Content protected by DRM may be recorded as silence.

## License

Apache License 2.0 — see `LICENSE` and `NOTICE`. The AudioMemo and Osmi names, marks and app icon are trademarks of BookAI and are **not** covered by the license (see `design/README.md`). Third-party components: `THIRD-PARTY-NOTICES.md`.

---

## 正體中文

**把電腦播出的所有聲音（會議、影片…）和你的麥克風，一起錄成一個檔案。**

AudioMemo 是免費、開源的小錄音工具：錄下系統混音（任何 App 的聲音，不論你用 AirPods、有線耳機、藍牙或內建喇叭）加上麥克風，存成 `.m4a` 在你自己的電腦。不用帳號、不上傳、沒有 AI。

- 建置：見上方 Build。
- 第一次錄音會跳出兩個視窗，都按「允許」：麥克風、錄製這台電腦的音訊。按錯可到「系統設定 › 隱私權與安全性 › 麥克風」與「螢幕與系統錄音 › 僅限系統錄音」打開。
- 隱私：只在你按錄音時錄；檔案存在你的 Mac（預設 `~/音樂/AudioMemo`），App 不上傳任何東西、不收集使用資料。
- 授權：Apache 2.0。AudioMemo 與 Osmi 的名稱、標誌與 App 圖示是 BookAI 的商標，不在授權範圍內。
