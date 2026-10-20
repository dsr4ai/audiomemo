# Test standards

All numbers come from scripts in this repository; the raw measurements and listening files are kept outside the repo.

## Automated

| Test | Command | Pass criteria |
|---|---|---|
| Core unit tests | `make -C core test` | FFT, leveler (slow attack, no noise amplification), limiter (peak ≤ -1 dBFS), AEC synthetic (echo ≥ 20 dB, near-end unchanged, double talk ≥ -3 dB, background floor within 3 dB) |
| Alternating speaker/speech | `python3 scripts/alternating_test.py 4 [--mix|--mute]` | voice vs system within ±6 dB, peak ≤ -1 dBFS, muted track silent |
| AEC on a real take | `python3 scripts/aec_capture.py <dir>` then `python3 scripts/aec_eval.py <take.caf> <out>` | see below |

## Echo canceller quality bar

"It should sound like only the microphone was on, with a natural, steady room background."

| Metric | Target |
|---|---|
| Echo component reduction (loudspeaker only) | ≥ 20 dB (minimum 15 dB) |
| Near-end only | level change ≤ 1 dB, no band change |
| Double talk | near-end level ≥ -3 dB, no dropouts |
| Soft voice (-15 dB) under echo | ≤ 3 dB loss, no holes |
| High frequencies (4–8 / 8–12 kHz) | loss ≤ 3 dB |
| Background floor while the speaker plays | within 3 dB of the room floor per band; no pumping, no musical noise |
| Other apps' volume | unchanged (≤ 0.5 dB) |
| CPU | < 10 % of one core |

### Status (2026-10-20, MacBook Pro built-in speakers, noisy room)

| Metric | Result | |
|---|---|---|
| Echo reduction | 19–22 dB (loud playback), 10–18 dB (quiet playback near the room level) | partial |
| Near-end only | 0.0 dB | pass |
| Double talk | -1.2 dB mean, but 12 % of frames > 6 dB low | **fail** |
| Soft voice | no holes; residual echo still audible above 8 kHz | **fail** |
| Background floor | 4–11 dB below the room floor in 0.5–4 kHz | **fail** |
| Other apps' volume | 0.0 dB difference | pass |
| CPU | ~2 % (offline), ~5 % live | pass |

Because of the failures, echo cancellation ships **off by default** (Settings › Echo cancellation).
