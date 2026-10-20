#!/usr/bin/env python3
"""i18n/ → Mac 的 String Catalog（mac/AudioMemo/Localizable.xcstrings、InfoPlist.xcstrings）。
來源：i18n/strings.json（en、zh-Hant 定稿）＋ i18n/locales/<語言>.json（其他語言，標 needs_review）。
沒翻的 key 先放英文（state=new），因為編譯出來的 .strings 缺 key 時會直接顯示 key 名。
目標語言（同 Osmi 21 語）：見 TARGETS；還沒有 locales 檔的語言目前不產生（App 會用英文）。"""
import json, pathlib

ROOT = pathlib.Path(__file__).resolve().parent.parent
TARGETS = ["zh-Hant", "zh-HK", "zh-Hans", "en", "en-GB", "ja", "ko", "fr", "de", "es", "es-MX", "it", "nl", "hu",
           "id", "ms", "th", "vi", "hi", "tr", "ar", "he"]
DERIVED = {"zh-HK": "zh-Hant", "en-GB": "en", "es-MX": "es"}   # 暫時沿用（待審）

base = json.loads((ROOT / "i18n/strings.json").read_text(encoding="utf-8"))
extra = {f.stem: json.loads(f.read_text(encoding="utf-8")) for f in sorted((ROOT / "i18n/locales").glob("*.json"))}

def catalog(table):
    out = {}
    for k, v in table.items():
        langs = {l: t for l, t in v.items() if l in ("en", "zh-Hant")}
        locs = {l: {"stringUnit": {"state": "translated", "value": t}} for l, t in langs.items()}
        for lang, tr in extra.items():
            if k in tr: locs[lang] = {"stringUnit": {"state": "needs_review", "value": tr[k]}}
        for lang, src in DERIVED.items():
            t = langs.get(src) or extra.get(src, {}).get(k)
            if t is not None: locs[lang] = {"stringUnit": {"state": "needs_review", "value": t}}
        for lang in list(extra) + list(DERIVED):
            locs.setdefault(lang, {"stringUnit": {"state": "new", "value": langs["en"]}})
        entry = {"extractionState": "manual", "localizations": locs}
        if v.get("note"): entry["comment"] = v["note"]
        out[k] = entry
    return {"sourceLanguage": "en", "version": "1.0", "strings": out}

mac = ROOT / "mac/AudioMemo"
for name, table in (("Localizable.xcstrings", base["strings"]), ("InfoPlist.xcstrings", base["infoPlist"])):
    (mac / name).write_text(json.dumps(catalog(table), ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print("wrote", name, len(table))
have = set(extra) | set(DERIVED) | {"en", "zh-Hant"}
print("languages with strings:", sorted(have))
print("still missing (English fallback):", [l for l in TARGETS if l not in have])
