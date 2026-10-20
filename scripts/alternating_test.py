#!/usr/bin/env python3
"""交替測試：系統音 5 秒 → 空白 5 秒（請說話）→ … 共 ROUNDS 輪，全程同時錄系統＋麥克風。
以除錯模式 -splitChannels YES 錄（左＝麥克風、右＝系統，方便分開量），結束後分段分析：
  系統段：ch_system 有聲；ch_mic 只有喇叭漏音（串音）
  說話段：ch_mic 有人聲、音量接近系統段；ch_system 應接近無聲（串音）
用法：python3 scripts/alternating_test.py [輪數=4] [--mix] [--no-autolevel]
  --mix：用正式的混音模式錄（只檢查破音／整體音量，不分軌）
  --no-autolevel：關掉自動音量平衡（對照組）
  --mute：第 2 輪說話段把麥克風靜音、第 3 輪系統段把系統聲靜音，檢查那兩段該軌是否無聲
⛔ 一律存到測試資料夾 ~/Music/AudioMemo-Test（-storageFolder），不碰使用者的 ~/Music/AudioMemo。檔案不會刪除。"""
import os, re, subprocess, sys, time, pathlib

ARGS = [a for a in sys.argv[1:] if not a.startswith("--")]
ROUNDS = int(ARGS[0]) if ARGS else 4
MIX = "--mix" in sys.argv
AUTOLEVEL = "--no-autolevel" not in sys.argv
MUTE = "--mute" in sys.argv
SEG = 5.0
HOME = pathlib.Path.home()
LOG = HOME / "Library/Logs/AudioMemo/debug.log"
RESULT = HOME / "Library/Logs/AudioMemo/autotest.txt"
APP = HOME / "Applications/AudioMemo.app"
TEST_DIR = str(HOME / "Music/AudioMemo-Test")
TEXT = ("This is the system sound test. The quick brown fox jumps over the lazy dog. "
        "One, two, three, four, five, six, seven, eight.")

def db(cmd_out, key):
    m = re.search(key + r": (-?[\d.]+|-inf) dB", cmd_out)
    return float(m.group(1)) if m and m.group(1) != "-inf" else -99.0

def measure(path, ch, start, dur):
    out = subprocess.run(["ffmpeg", "-nostats", "-hide_banner", "-ss", f"{start:.2f}", "-t", f"{dur:.2f}", "-i", path,
                          "-af", f"pan=mono|c0=c{ch},volumedetect", "-f", "null", "-"],
                         capture_output=True, text=True).stderr
    return db(out, "mean_volume"), db(out, "max_volume")

def pcm(path):
    """解碼成 float32 雙聲道，回傳 (左, 右) 兩個 array。"""
    import array
    raw = subprocess.run(["ffmpeg", "-v", "error", "-i", path, "-f", "f32le", "-ac", "2", "-ar", "48000", "-"],
                         capture_output=True).stdout
    a = array.array("f"); a.frombytes(raw)
    return a[0::2], a[1::2]

def window_db(x, sr=48000, win=0.1):
    import math
    n = int(sr * win); out = []
    for i in range(0, len(x) - n, n):
        seg = x[i:i + n]
        rms = math.sqrt(sum(v * v for v in seg) / n)
        out.append(20 * math.log10(rms) if rms > 0 else -120)
    return out

def pct(xs, q):
    xs = sorted(xs); return xs[int(q * (len(xs) - 1))]

def main():
    RESULT.unlink(missing_ok=True)
    start_lines = len(LOG.read_text().splitlines()) if LOG.exists() else 0
    total = ROUNDS * 2 * SEG + 2
    subprocess.run(["open", "-n", str(APP), "--args", "-storageFolder", TEST_DIR, "-autotestSeconds", str(total),
                    "-splitChannels", "NO" if MIX else "YES", "-autoLevel", "YES" if AUTOLEVEL else "NO"]
                   + (["-autotestMute", "mic:16-21,sys:21-26"] if MUTE else []))
    t0 = None
    for _ in range(600):
        lines = LOG.read_text().splitlines()[start_lines:] if LOG.exists() else []
        if any("audio flowing" in l for l in lines):
            t0 = time.monotonic(); break
        time.sleep(0.1)
    if t0 is None:
        print("FAIL: 錄音沒有開始"); sys.exit(1)
    time.sleep(1.0)
    segs = []   # (kind, start, end) 相對於錄音開始
    for r in range(ROUNDS):
        s = time.monotonic() - t0
        p = subprocess.Popen(["say", "-v", "Samantha", "-r", "170", TEXT])
        time.sleep(SEG)
        p.terminate(); p.wait()
        segs.append(("system", s, time.monotonic() - t0))
        print(f"\n>>> 第 {r+1}/{ROUNDS} 輪：現在請說話（5 秒）", flush=True)
        s = time.monotonic() - t0
        time.sleep(SEG)
        segs.append(("speech", s, time.monotonic() - t0))
        print(">>> 停", flush=True)
    for _ in range(60):
        if RESULT.exists() and RESULT.read_text().strip(): break
        time.sleep(0.5)
    path = RESULT.read_text().strip()
    print("\n檔案：", path)
    assert path.startswith(TEST_DIR), "測試檔沒有存到測試資料夾"
    if not os.path.exists(path):
        print("FAIL"); sys.exit(1)
    print(f"{'段':<8}{'時間':>12}  {'mic 平均/峰值':>16}  {'system 平均/峰值':>18}")
    rows = []
    for kind, s, e in segs:
        a, b = s + 0.5, (e - s) - 1.0   # 前後各留 0.5 秒緩衝
        mm, mp = measure(path, 0, a, b)
        sm, sp = measure(path, 1, a, b)
        rows.append((kind, mm, mp, sm, sp))
        print(f"{kind:<8}{s:6.1f}–{e:5.1f}  {mm:7.1f}/{mp:6.1f} dB  {sm:8.1f}/{sp:6.1f} dB")
    # 音量條（畫面數值）分段平均
    meters = []
    for l in LOG.read_text().splitlines()[start_lines:]:
        m = re.search(r"meter t=([\d.]+) mic=([\d.]+) sys=([\d.]+)", l)
        if m: meters.append(tuple(float(x) for x in m.groups()))
    if meters:
        print("\n音量條（0–1，dBFS 刻度 -60～0）分段平均：")
        for kind, s_, e_ in segs:
            v = [(mi, sy) for t, mi, sy in meters if s_ + 0.5 <= t + 1.0 <= e_ - 0.5]
            if v:
                print(f"  {kind:<7}{s_:5.1f}–{e_:5.1f}  mic {sum(x for x,_ in v)/len(v):.2f}  system {sum(y for _,y in v)/len(v):.2f}")
    if MUTE and not MIX:
        print("\n靜音檢查：")
        m2 = rows[3]; s3 = rows[4]
        print(f"  第 2 輪說話段（麥克風靜音）mic {m2[1]:.1f} dB → {'PASS' if m2[1] < -70 else 'FAIL'}")
        print(f"  第 3 輪系統段（系統靜音）system {s3[3]:.1f} dB → {'PASS' if s3[3] < -70 else 'FAIL'}")
    import math
    L, R = pcm(path)
    peakL = 20 * math.log10(max(max(L), -min(L)) or 1e-9); peakR = 20 * math.log10(max(max(R), -min(R)) or 1e-9)
    wl = window_db(L)
    noise_floor = pct(wl, 0.10)
    print(f"\n整檔峰值：左 {peakL:.2f} dBFS、右 {peakR:.2f} dBFS（上限 -1.0）")
    print(f"左聲道 100ms 視窗 RMS：P10（底噪）{noise_floor:.1f} dB、P50 {pct(wl,0.5):.1f} dB、P90 {pct(wl,0.9):.1f} dB")
    no_clip = peakL <= -1.0 and peakR <= -1.0
    if MIX:
        print("結果：", "PASS" if no_clip else "FAIL（破音）")
        return
    use = [r for i, r in enumerate(rows) if not (MUTE and i in (3, 4))]   # 靜音的兩段不算進平均
    sysrows = [r for r in use if r[0] == "system"]
    sprows = [r for r in use if r[0] == "speech"]
    avg = lambda xs: sum(xs) / len(xs)
    sys_on = avg([r[3] for r in sysrows]); sys_off = avg([r[3] for r in sprows])
    mic_speech = avg([r[1] for r in sprows]); mic_during_sys = avg([r[1] for r in sysrows])
    print("\n== 摘要")
    print(f"系統段 ch_system 平均 {sys_on:.1f} dB；說話段 ch_system 平均 {sys_off:.1f} dB（越低越好＝系統軌沒有串到麥克風）")
    print(f"說話段 ch_mic 平均 {mic_speech:.1f} dB；系統段 ch_mic 平均 {mic_during_sys:.1f} dB（喇叭漏進麥克風）")
    print(f"人聲 vs 系統音量差：{mic_speech - sys_on:+.1f} dB（目標 ±6 dB 內）")
    print(f"自動平衡：{'開' if AUTOLEVEL else '關'}；麥克風底噪 P10 {noise_floor:.1f} dB；系統軌空白段 {sys_off:.1f} dB（應維持近乎無聲）")
    ok = sys_on > -35 and sys_off < -60 and abs(mic_speech - sys_on) <= 6 and no_clip
    print("結果：", "PASS" if ok else "CHECK")

main()
