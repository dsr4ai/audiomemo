# Architecture

```
            ┌──────────── platform layer (mac/, windows/) ────────────┐
 system mix │ macOS: Core Audio process tap (global, excludes nothing   │
            │        but silent self) inside a private aggregate device│
 microphone │        whose clock master is the microphone              │
            └───────────────┬──────────────────────────────────────────┘
                            │ one IO callback: mic + system, same clock
                            ▼
              core/ (C11, real-time safe, shared by all platforms)
   mic ──► am_aec (reference = system mix) ──► am_leveler ──┐
   sys ──► (delayed by the AEC latency) ───► am_leveler ──┤
                                                           ▼
                                   mix (L = sysL + mic, R = sysR + mic)
                                                           ▼
                                                     am_limiter
                                                           ▼
                                        AAC 256 kbps (platform encoder)
```

## macOS specifics (`mac/`)

- **System audio**: `CATapDescription(stereoGlobalTapButExcludeProcesses:)`; no virtual driver. Works regardless of the output device (AirPods, wired, Bluetooth, speakers).
- **Aggregate device**: the microphone is the main sub-device (clock); the tap is added with drift compensation. A tap-only aggregate never runs, so a microphone is required.
- **Silence keeper**: while recording the app plays digital silence so the tap starts immediately even when nothing else is playing.
- **Device changes**: microphone follows the system default and the mic another app (e.g. a call app) is using; switching rebuilds the tap + aggregate without closing the file, and writes silence for the gap.
- **Writing**: `ExtAudioFileWriteAsync` (real-time safe), finalised on stop; short recordings (< 1 s) are discarded.

## core/

- `am_aec` — partitioned-block frequency-domain NLMS (block 512 @ 48 kHz, 12 partitions ≈ 128 ms), per-bin step from error/reference coherence, GCC-PHAT bulk-delay estimate (8 kHz decimated, every 2 s), light per-bin residual-echo post-filter with comfort noise. Latency 1024 samples.
- `am_leveler` / `am_limiter` — level balancing (gate, slow attack/release) and stereo-linked limiter.
- All memory is allocated in `*_create`/`*_init`; `*_process` never allocates.
