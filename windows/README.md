# AudioMemo for Windows (planned)

Not started yet. Plan:

- **Capture**: WASAPI loopback on the default render endpoint (system mix) + WASAPI capture on the chosen microphone. Use the process-loopback API (`ActivateAudioInterfaceAsync` with `AUDIOCLIENT_ACTIVATION_TYPE_PROCESS_LOOPBACK`, Windows 10 2004+) to exclude our own process.
- **Clocking**: the two streams run on different clocks → resample the microphone stream to the loopback clock (drift-tracked) before mixing.
- **Processing**: link the portable C core (`core/`): echo canceller (reference = loopback signal), level balancer, limiter — identical to macOS.
- **Encoding**: Media Foundation AAC encoder (`.m4a`, 256 kbps).
- **UI**: shared strings from `i18n/`, colors and type from `design/tokens.json`.
- **Permissions**: Settings › Privacy › Microphone for desktop apps.
