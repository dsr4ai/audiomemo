#!/bin/bash
# 自動錄音測試（存到 ~/Music/AudioMemo-Test，不碰使用者資料夾）：開 App 錄 N 秒（預設 10），同時用 say 播一段英文，再量左右聲道音量。
set -uo pipefail
SECS=${1:-10}
RESULT=~/Library/Logs/AudioMemo/autotest.txt
rm -f "$RESULT"
LOG=~/Library/Logs/AudioMemo/debug.log
START_LINES=$(wc -l < "$LOG" 2>/dev/null || echo 0)
open -n ~/Applications/AudioMemo.app --args -storageFolder ~/Music/AudioMemo-Test -autotestSeconds "$SECS"
# 等 App 真的開始錄（第一次會停在權限視窗，請按「允許」）
for i in $(seq 1 130); do
  tail -n +$((START_LINES + 1)) "$LOG" 2>/dev/null | grep -q "recording started" && break
  [ -s "$RESULT" ] && break
  sleep 1
done
sleep 1
say -v Samantha "This is the AudioMemo system audio test. One two three four five six seven." &
for i in $(seq 1 $((SECS + 30))); do [ -s "$RESULT" ] && break; sleep 1; done
FILE=$(cat "$RESULT" 2>/dev/null)
echo "file: $FILE"
[ -f "$FILE" ] || { echo "FAIL: no file"; exit 1; }
ffprobe -v error -show_entries stream=codec_name,channels,sample_rate,duration -of default=nw=1 "$FILE"
for ch in 0 1; do
  label=$([ $ch = 0 ] && echo "L 麥克風" || echo "R 系統聲音")
  echo "== $label"
  ffmpeg -nostats -hide_banner -i "$FILE" -af "pan=mono|c0=c$ch,volumedetect" -f null - 2>&1 | grep -E "mean_volume|max_volume"
done
