#!/usr/bin/env python3
"""Record a raw AEC test take (no processing): left = raw microphone, right = loudspeaker reference.
Sequence (loudspeaker = built-in speakers):  4 s quiet  |  8 s speech (say)  |  6 s quiet  |  8 s speech  |  2 s quiet
Output: <dir>/AudioMemo <date>.caf  (float32). Used by scripts/aec_eval.py.
Usage: python3 scripts/aec_capture.py <test-folder>"""
import subprocess, sys, time, pathlib
HOME = pathlib.Path.home()
LOG = HOME / "Library/Logs/AudioMemo/debug.log"
RESULT = HOME / "Library/Logs/AudioMemo/autotest.txt"
APP = HOME / "Applications/AudioMemo.app"
DIR = sys.argv[1] if len(sys.argv) > 1 else str(HOME / "Music/AudioMemo-Test")
TEXT = ("This is a test of the echo canceller. The quick brown fox jumps over the lazy dog. "
        "She sells sea shells by the sea shore. One, two, three, four, five, six, seven.")
RESULT.unlink(missing_ok=True)
n0 = len(LOG.read_text().splitlines()) if LOG.exists() else 0
subprocess.run(["open", "-n", str(APP), "--args", "-storageFolder", DIR, "-autotestSeconds", "30", "-rawCapture", "YES"])
for _ in range(600):
    if any("audio flowing" in l for l in LOG.read_text().splitlines()[n0:]): break
    time.sleep(0.1)
t0 = time.monotonic()
def at(t):
    while time.monotonic() - t0 < t: time.sleep(0.01)
def speak(t, dur):
    at(t); p = subprocess.Popen(["say", "-v", "Samantha", "-r", "175", TEXT]); at(t + dur); p.terminate(); p.wait()
speak(4, 8); speak(18, 8)
for _ in range(80):
    if RESULT.exists() and RESULT.read_text().strip(): break
    time.sleep(0.5)
print(RESULT.read_text().strip())
