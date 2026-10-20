#!/bin/bash
# Synthetic test sounds only (macOS `say` voices and generated noise) — no recordings of real people.
set -euo pipefail
cd "$(dirname "$0")"
say -v Samantha -r 175 -o speech-en.aiff "The quick brown fox jumps over the lazy dog. One, two, three, four, five."
ffmpeg -v error -y -i speech-en.aiff -ar 48000 -ac 1 speech-en.wav && rm speech-en.aiff
ffmpeg -v error -y -f lavfi -i "anoisesrc=color=pink:amplitude=0.3:duration=3:sample_rate=48000" -ac 1 pink-noise.wav
ls -la *.wav
