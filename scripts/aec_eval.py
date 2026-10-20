#!/usr/bin/env python3
"""Evaluate the echo canceller on a raw take from aec_capture.py (same recording, processed off/on).
Usage: python3 scripts/aec_eval.py <take.caf> <out-dir>
Writes <out-dir>/{input,aec,aec-linear,doubletalk-*}.wav and prints the metrics."""
import subprocess, sys, pathlib
import numpy as np

ROOT = pathlib.Path(__file__).resolve().parent.parent
TOOL = ROOT / "core/build/am_aec_wav"
take, out = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]); out.mkdir(parents=True, exist_ok=True)
SR = 48000
QUIET_A, FAR1, QUIET_C, FAR2 = (0.5, 3.5), (5.0, 11.5), (12.5, 17.5), (19.0, 25.5)

def run(cmd): return subprocess.run(cmd, capture_output=True, text=True)
def readwav(p, ch):
    raw = run(["ffmpeg", "-v", "error", "-i", str(p), "-f", "f32le", "-ac", str(ch), "-"]).stdout
    return np.frombuffer(raw.encode("latin1") if isinstance(raw, str) else raw, dtype=np.float32)
def pcm(p, ch):
    raw = subprocess.run(["ffmpeg", "-v", "error", "-i", str(p), "-f", "f32le", "-ac", str(ch), "-ar", str(SR), "-"], capture_output=True).stdout
    return np.frombuffer(raw, dtype=np.float32).reshape(-1, ch).astype(np.float64)
def writewav(p, *chans):
    x = np.stack(chans, 1).astype(np.float32)
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "f32le", "-ar", str(SR), "-ac", str(x.shape[1]), "-i", "-", "-c:a", "pcm_f32le", str(p)], input=x.tobytes())
def aec(inp, outp, *flags):
    r = run([str(TOOL), str(inp), str(outp), *flags]); return r.stderr.strip().splitlines()[-1]
def seg(x, t): return x[int(t[0] * SR):int(t[1] * SR)]
def db(x): return 10 * np.log10(np.mean(x ** 2) + 1e-20)
BANDS = [(100, 500), (500, 1000), (1000, 2000), (2000, 4000), (4000, 8000), (8000, 12000), (12000, 16000)]
def bands(x):
    f = np.fft.rfftfreq(2048, 1 / SR); acc = np.zeros(len(f)); n = 0
    for i in range(0, len(x) - 2048, 1024):
        acc += np.abs(np.fft.rfft(x[i:i + 2048] * np.hanning(2048))) ** 2; n += 1
    acc /= max(n, 1)
    return [10 * np.log10(acc[(f >= lo) & (f < hi)].sum() + 1e-20) for lo, hi in BANDS]
def delay_of(x, r):
    n = 1 << int(np.ceil(np.log2(len(x) * 2)))
    X, R = np.fft.rfft(x, n), np.fft.rfft(r, n)
    c = np.fft.irfft(X * np.conj(R) / (np.abs(X * np.conj(R)) + 1e-12), n)
    return int(np.argmax(c[:SR // 2]))
def echo_db(x, r, D):
    """Level of the part of x that is linearly predictable from the reference (delay-aligned
    frequency-domain Wiener fit) — i.e. the echo, separated from room voices / noise."""
    xs, rs = x[D:], r[:len(r) - D]
    def stft(z, n=4096, h=1024):
        w = np.hanning(n); return np.array([np.fft.rfft(z[i:i + n] * w) for i in range(0, len(z) - n, h)])
    Xr, Xx = stft(rs), stft(xs)
    H = (Xx * np.conj(Xr)).sum(0) / ((np.abs(Xr) ** 2).sum(0) + 1e-12)
    E = H * Xr
    return 10 * np.log10((np.abs(E) ** 2).sum() / (len(Xr) * 4096 * 0.375 * 4096 / 2) + 1e-20)
def frame_db(x, w=0.02):
    n = int(SR * w); return np.array([db(x[i:i + n]) for i in range(0, len(x) - n, n)])

a = pcm(take, 2); mic, ref = a[:, 0], a[:, 1]
# segments from the reference itself: loudspeaker playing (> -35 dB) / silent (< -70 dB), 100 ms frames
fr = np.array([db(ref[i:i + SR // 10]) for i in range(0, len(ref) - SR // 10, SR // 10)])
def runs(mask):
    out, st = [], None
    for i, v in enumerate(list(mask) + [False]):
        if v and st is None: st = i
        if not v and st is not None: out.append((st, i)); st = None
    return sorted(out, key=lambda r: r[1] - r[0], reverse=True)
play = np.array([fr[max(0, i - 5):i + 6].max() for i in range(len(fr))])   # bridge pauses between words (±0.5 s)
far = runs(play > -35)[:2]; quiet = runs(play < -70)
far = sorted([((b + 5) / 10, (e - 1) / 10) for b, e in far])      # skip the first 0.5 s of each run
QUIET_A = ((quiet[0][0] + 2) / 10, (quiet[0][1] - 2) / 10)
FAR1, FAR2 = far[0], far[1]
QUIET_C = QUIET_A

writewav(out / "input.wav", mic, ref)
cpu = aec(out / "input.wav", out / "aec.wav")
aec(out / "input.wav", out / "aec-linear.wav", "--linear-only")
o = pcm(out / "aec.wav", 1)[:, 0]; ol = pcm(out / "aec-linear.wav", 1)[:, 0]
n = min(len(o), len(mic)); o, ol, mic, ref = o[:n], ol[:n], mic[:n], ref[:n]
writewav(out / "listen-before-after.wav", np.concatenate([seg(mic, (4, 12)), seg(o, (4, 12))]))

print(f"take: {take.name}   CPU: {cpu}")
amb = seg(mic, QUIET_A); amb_db = db(amb)
print(f"\n[1] Echo (loudspeaker playing {FAR1[0]:.1f}–{FAR1[1]:.1f} s and {FAR2[0]:.1f}–{FAR2[1]:.1f} s; room level without playback {amb_db:.1f} dB)")
D = delay_of(seg(mic, (FAR1[0] - 0.2, FAR1[1])), seg(ref, (FAR1[0] - 0.2, FAR1[1])))
print(f"    acoustic delay {D / 48:.1f} ms")
for t in (FAR1, FAR2):
    wide = (t[0] - D / SR - 0.1, t[1])
    em, el, eo = (echo_db(seg(x, wide), seg(ref, wide), D) for x in (mic, ol, o))
    print(f"    level: mic {db(seg(mic,t)):6.1f} → out {db(seg(o,t)):6.1f} dB (out vs ambient {db(seg(o,t))-amb_db:+.1f} dB)")
    print(f"    echo component: mic {em:6.1f} → linear {el:6.1f} → full {eo:6.1f} dB   ECHO REDUCTION {em-eo:5.1f} dB (linear {em-el:.1f})")

print("\n[2] Background floor: output while the loudspeaker plays vs the room without playback, per band")
print("    (floor = 20th percentile of 50 ms band levels, so voices in the room don't count as 'noise')")
def floor_bands(x):
    f = np.fft.rfftfreq(2400, 1 / SR); lv = []
    for i in range(0, len(x) - 2400, 2400):
        P = np.abs(np.fft.rfft(x[i:i + 2400] * np.hanning(2400))) ** 2
        lv.append([10 * np.log10(P[(f >= lo) & (f < hi)].sum() + 1e-20) for lo, hi in BANDS])
    return np.percentile(np.array(lv), 20, axis=0)
ba, bo = floor_bands(amb), floor_bands(np.concatenate([seg(o, FAR1), seg(o, FAR2)]))
print("    band     " + " ".join(f"{lo//1000 if lo>=1000 else lo:>5}{'k' if lo>=1000 else ''}" for lo, _ in BANDS))
print("    diff     " + " ".join(f"{bo[i]-ba[i]:+6.1f}" for i in range(len(BANDS))))
fa, fo = frame_db(amb), frame_db(seg(o, FAR1))
print(f"    short-time (20 ms) level std: ambient {fa.std():.1f} dB, output {fo.std():.1f} dB")

print(f"\n[3] Near-end only (no playback, {QUIET_A[0]:.1f}–{QUIET_A[1]:.1f} s): output vs input")
ni, no_ = seg(mic, QUIET_C), seg(o, QUIET_C)
print(f"    level {db(no_)-db(ni):+.2f} dB;  bands " + " ".join(f"{x-y:+.1f}" for x, y in zip(bands(no_), bands(ni))))

# synthetic double talk / soft voice: near-end (quiet section) + echo (loudspeaker section), same reference
L = int(min(5.0, QUIET_A[1] - QUIET_A[0], FAR1[1] - FAR1[0]) * SR)
near = seg(mic, QUIET_C)[:L]; echo = seg(mic, FAR1)[:L]; r = seg(ref, FAR1)[:L]
# give the canceller the preceding loudspeaker audio so it is converged, like in real use
pre_m, pre_r = seg(mic, (FAR2[0], FAR2[1])), seg(ref, (FAR2[0], FAR2[1]))
for name, gain in (("doubletalk", 1.0), ("soft", 10 ** (-15 / 20))):
    nm = near * gain
    mix_m = np.concatenate([pre_m, echo + nm]); mix_r = np.concatenate([pre_r, r])
    writewav(out / f"{name}-input.wav", mix_m, mix_r)
    aec(out / f"{name}-input.wav", out / f"{name}-aec.wav")
    om = pcm(out / f"{name}-aec.wav", 1)[:, 0][len(pre_m):len(pre_m) + L]
    # near-end retention: compare output with the clean near-end, frame by frame where near-end is active
    fn, fo2 = frame_db(nm), frame_db(om)
    act = fn > np.percentile(fn, 60)
    holes = int(np.sum((fn - fo2)[act] > 6))
    print(f"\n[{4 if name=='doubletalk' else 5}] {'Double talk' if name=='doubletalk' else 'Soft voice (-15 dB)'}: near-end {db(nm):.1f} dB + echo {db(echo):.1f} dB")
    print(f"    output vs clean near-end, active frames: {np.mean(fo2[act]-fn[act]):+.1f} dB (mean), holes (>6 dB below) {holes}/{int(act.sum())}")
    print(f"    bands (output − near): " + " ".join(f"{x-y:+.1f}" for x, y in zip(bands(om), bands(nm))))
