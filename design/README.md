# Design

- `tokens.json` — colors (light/dark), type scale and radii used by every platform.
  - Primary color: AudioMemo **wave teal** — deep `#299898`, light `#54CDCC` (same hue). The derivation of the other primary steps and the contrast checks are recorded in `tokens.json` → `derivation`.
  - Small text in the primary color uses `primaryText` (WCAG AA); `p500` is for fills, icons and large text.
  - The recording red is reserved for the recording state.
- Icons use the platform's system symbols (SF Symbols on macOS), plus the AudioMemo mark for the menu bar.

## Brand assets and trademarks — not covered by the Apache License

| Asset | Path |
|---|---|
| AudioMemo app icon (two bubbles, light `#54CDCC` / deep `#299898`) | `mac/AudioMemo/Assets.xcassets/AppIcon.appiconset` |
| AudioMemo mark, single color (menu bar) | `mac/AudioMemo/Assets.xcassets/AudioMemoMark.imageset` |
| Osmi mark (transcribe button) | `mac/AudioMemo/Assets.xcassets/OsmiMark.imageset` |

The **AudioMemo** name, mark and app icon and the **Osmi** name and mark are trademarks of **BookAI**.
They are included for the official builds only and are **not** licensed under Apache-2.0.
Forks must replace them with their own artwork and name.
