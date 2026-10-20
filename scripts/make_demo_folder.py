#!/usr/bin/env python3
"""Create a demo recordings folder for store screenshots (silent AAC files with realistic names, lengths and dates).

Usage: python3 scripts/make_demo_folder.py <en|zh-Hant> <folder>
The files are silent 48 kHz stereo AAC at 256 kbps, so lengths and sizes match real AudioMemo recordings.
The folder is wiped and recreated; never point it at a real recordings folder.
"""
import os, subprocess, sys, tempfile, time, wave
from datetime import datetime

DEMO = {
    "en": ["Weekly sync", "Client call — Q4 plan", "Lecture 6: Statistics", "Interview with Sam"],
    "zh-Hant": ["每週例會", "客戶會議：Q4 規劃", "統計學第 6 講", "專訪 阿明"],
}
LENGTHS = [48 * 60 + 12, 20 * 60 + 7, 52 * 60 + 36, 34 * 60 + 18]          # newest first
DATES = ["2026-10-20 10:02", "2026-10-19 15:31", "2026-10-16 09:10", "2026-10-14 14:05"]


def silent_wav(path, seconds):
    with wave.open(path, "wb") as w:
        w.setnchannels(2); w.setsampwidth(2); w.setframerate(48000)
        chunk = b"\0" * 48000 * 4 * 60
        left = seconds
        while left > 0:
            n = min(60, left); w.writeframes(chunk[: 48000 * 4 * n]); left -= n


def main():
    lang, folder = sys.argv[1], os.path.expanduser(sys.argv[2])
    if os.path.realpath(folder) == os.path.realpath(os.path.expanduser("~/Music/AudioMemo")):
        sys.exit("refusing to touch the real recordings folder")
    os.makedirs(folder, exist_ok=True)
    for f in os.listdir(folder):
        if f.endswith((".m4a", ".mp3", ".wav", ".flac", ".aiff")):
            os.remove(os.path.join(folder, f))
    with tempfile.TemporaryDirectory() as tmp:
        for name, secs, date in zip(DEMO[lang], LENGTHS, DATES):
            wav = os.path.join(tmp, "s.wav"); silent_wav(wav, secs)
            out = os.path.join(folder, name + ".m4a")
            subprocess.run(["afconvert", "-f", "m4af", "-d", "aac", "-b", "256000", "-s", "0", wav, out], check=True)
            os.remove(wav)
            t = time.mktime(datetime.strptime(date, "%Y-%m-%d %H:%M").timetuple())
            os.utime(out, (t, t))      # setting an earlier mtime also moves the creation date back on APFS
            print(out, os.path.getsize(out))


if __name__ == "__main__":
    main()
