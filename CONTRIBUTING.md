# Contributing

Thanks for helping! Short version:

1. Open an issue first for anything bigger than a small fix.
2. Keep the audio thread real-time safe: no allocation, locks or I/O in `core/*_process` or the Core Audio IOProc.
3. Run `make -C core test` and, for audio changes, the scripts in `scripts/` (see `docs/TESTING.md`). Paste the numbers in the PR.
4. UI strings go in `i18n/strings.json` (never hard-coded); run `python3 scripts/gen_strings.py`.
5. Only synthetic test audio in the repo (`test-audio/`). Never commit real people's recordings, keys, certificates or personal paths.
6. By contributing you agree your work is licensed under Apache-2.0.
