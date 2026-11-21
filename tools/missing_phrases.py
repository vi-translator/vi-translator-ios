"""The interface phrases the app says (L("...")) that a language's dictionaries don't have.

    python tools/missing_phrases.py ar

The desktop's dictionaries (App/Resources/i18n), the phone apps' (i18n-phone) and this app's
(i18n-ios) are looked in; a phrase missing from all of them shows in English.
"""
import glob
import json
import re
import sys

lang = sys.argv[1] if len(sys.argv) > 1 else "ar"
keys = set()
pat = re.compile(r'\bL\("((?:[^"\\]|\\.)*)"')
for f in glob.glob("App/**/*.swift", recursive=True):
    for m in pat.finditer(open(f, encoding="utf-8").read()):
        keys.add(m.group(1).replace('\\"', '"'))
d = {}
for p in ["App/Resources/i18n/%s.json", "App/Resources/i18n-phone/%s.json", "App/Resources/i18n-ios/%s.json"]:
    try:
        d.update(json.load(open(p % lang, encoding="utf-8")))
    except FileNotFoundError:
        pass
missing = sorted(k for k in keys if k not in d)
print(len(keys), "phrases,", len(missing), "missing in", lang)
for k in missing:
    print(json.dumps(k, ensure_ascii=False))
