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
    "en-GB": ["Team catch-up", "Client call \u2013 Q4 plan", "Lecture 6: Statistics", "Interview with Sam"],
    "de": ["Wöchentliches Teammeeting", "Kundentermin \u2013 Q4-Planung", "Vorlesung 6: Statistik", "Interview mit Jonas"],
    "fr": ["Point hebdo", "Appel client \u2013 plan T4", "Cours 6 : Statistiques", "Entretien avec Camille"],
    "es": ["Reunión semanal", "Llamada con cliente: plan T4", "Clase 6: Estadística", "Entrevista con Lucía"],
    "es-MX": ["Junta semanal", "Llamada con cliente: plan Q4", "Clase 6: Estadística", "Entrevista con Diego"],
    "hu": ["Heti megbeszélés", "Ügyfélhívás \u2013 Q4 terv", "6. előadás: Statisztika", "Interjú Annával"],
    "ja": ["週次ミーティング", "顧客打ち合わせ：Q4計画", "統計学 第6回", "インタビュー 佐藤さん"],
    "th": ["ประชุมประจำสัปดาห์", "คุยกับลูกค้า แผน Q4", "สถิติ บทที่ 6", "สัมภาษณ์คุณนัท"],
    "zh-Hans": ["每周例会", "客户会议：Q4 规划", "统计学第 6 讲", "采访 小李"],
    "ar": ["الاجتماع الأسبوعي", "مكالمة عميل \u2013 خطة الربع الرابع", "المحاضرة 6: الإحصاء", "مقابلة مع عمر"],
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
    cache = os.path.expanduser("~/Library/Caches/AudioMemoDemo")      # silent files are reused (APFS clone copy)
    os.makedirs(cache, exist_ok=True)
    with tempfile.TemporaryDirectory() as tmp:
        for name, secs, date in zip(DEMO[lang], LENGTHS, DATES):
            src = os.path.join(cache, f"{secs}.m4a")
            if not os.path.exists(src):
                wav = os.path.join(tmp, "s.wav"); silent_wav(wav, secs)
                subprocess.run(["afconvert", "-f", "m4af", "-d", "aac", "-b", "256000", "-s", "0", wav, src], check=True)
                os.remove(wav)
            out = os.path.join(folder, name + ".m4a")
            subprocess.run(["cp", "-c", src, out], check=True)
            t = time.mktime(datetime.strptime(date, "%Y-%m-%d %H:%M").timetuple())
            os.utime(out, (t, t))      # setting an earlier mtime also moves the creation date back on APFS
            print(out, os.path.getsize(out))


if __name__ == "__main__":
    main()
