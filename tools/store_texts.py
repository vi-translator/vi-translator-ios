"""The App Store page's texts, in the 30 languages the App Store has, from the Android app's Play
listing (vi-translator-android/fastlane/metadata/android/<locale>/full_description.txt): the same
description, with the iPhone's requirement line in place of Android's and without the "screen off"
line. Writes fastlane/metadata/<App Store locale>/ (fastlane deliver's layout).

    python tools/store_texts.py ../../AndroidStudioProjects/vi-translator-android
"""
import os
import sys

android = sys.argv[1] if len(sys.argv) > 1 else r"C:\Users\fouad\AndroidStudioProjects\vi-translator-android"
src = os.path.join(android, "fastlane", "metadata", "android")
out = os.path.join(os.path.dirname(__file__), "..", "fastlane", "metadata")

NAME = "VI Translator - Live Subtitles"
SUPPORT = "https://vitranslator.app/"
PRIVACY = "https://vitranslator.app/privacy/"

# Play locale -> App Store locale, the iPhone requirement line, the keywords (100 characters at most)
LANGS = {
    "en-US": ("en-US", "• An iPhone or iPad (iOS 16 or newer)",
              "translator,subtitles,translate,PS5,Xbox,remote play,TV,Arabic,live,captions,game,overlay"),
    "ar": ("ar-SA", "• جهاز iPhone أو iPad (بنظام iOS 16 أو أحدث)",
           "مترجم,ترجمة,ترجمة الألعاب,ترجمة فورية,ترجمة عربية,PS5,Xbox,تلفاز,ألعاب,نصوص,بلايستيشن"),
    "bn-BD": ("bn-BD", "• একটি iPhone বা iPad (iOS 16 বা নতুন)",
              "অনুবাদ,সাবটাইটেল,গেম,PS5,Xbox,টিভি,লাইভ,অনুবাদক"),
    "cs-CZ": ("cs", "• iPhone nebo iPad (iOS 16 nebo novější)",
              "překladač,titulky,překlad,PS5,Xbox,remote play,TV,hry,živě"),
    "de-DE": ("de-DE", "• Ein iPhone oder iPad (iOS 16 oder neuer)",
              "Übersetzer,Untertitel,übersetzen,PS5,Xbox,Remote Play,TV,Spiele,live"),
    "el-GR": ("el", "• Ένα iPhone ή iPad (iOS 16 ή νεότερο)",
              "μετάφραση,υπότιτλοι,μεταφραστής,PS5,Xbox,τηλεόραση,παιχνίδια,live"),
    "es-419": ("es-MX", "• Un iPhone o iPad (iOS 16 o posterior)",
               "traductor,subtítulos,traducir,PS5,Xbox,remote play,TV,juegos,en vivo"),
    "es-ES": ("es-ES", "• Un iPhone o iPad (iOS 16 o posterior)",
              "traductor,subtítulos,traducir,PS5,Xbox,remote play,TV,juegos,en directo"),
    "fr-FR": ("fr-FR", "• Un iPhone ou un iPad (iOS 16 ou version ultérieure)",
              "traducteur,sous-titres,traduire,PS5,Xbox,remote play,TV,jeux,direct"),
    "hi-IN": ("hi", "• एक iPhone या iPad (iOS 16 या नया)",
              "अनुवाद,सबटाइटल,अनुवादक,गेम,PS5,Xbox,टीवी,लाइव"),
    "id": ("id", "• iPhone atau iPad (iOS 16 atau lebih baru)",
           "penerjemah,subtitle,terjemahan,PS5,Xbox,remote play,TV,game,langsung"),
    "it-IT": ("it", "• Un iPhone o iPad (iOS 16 o successivo)",
              "traduttore,sottotitoli,tradurre,PS5,Xbox,remote play,TV,giochi,dal vivo"),
    "ja-JP": ("ja", "• iPhone または iPad（iOS 16 以降）",
              "翻訳,字幕,ゲーム,PS5,Xbox,リモートプレイ,テレビ,リアルタイム,翻訳アプリ"),
    "ko-KR": ("ko", "• iPhone 또는 iPad(iOS 16 이상)",
              "번역,자막,번역기,게임,PS5,Xbox,리모트 플레이,TV,실시간"),
    "mr-IN": ("mr-IN", "• iPhone किंवा iPad (iOS 16 किंवा नवीन)",
              "भाषांतर,सबटायटल,गेम,PS5,Xbox,टीव्ही,लाइव्ह"),
    "ms": ("ms", "• iPhone atau iPad (iOS 16 atau lebih baharu)",
           "penterjemah,sari kata,terjemahan,PS5,Xbox,remote play,TV,permainan,langsung"),
    "nl-NL": ("nl-NL", "• Een iPhone of iPad (iOS 16 of nieuwer)",
              "vertaler,ondertiteling,vertalen,PS5,Xbox,remote play,tv,games,live"),
    "pl-PL": ("pl", "• iPhone lub iPad (iOS 16 lub nowszy)",
              "tłumacz,napisy,tłumaczenie,PS5,Xbox,remote play,TV,gry,na żywo"),
    "pt-BR": ("pt-BR", "• Um iPhone ou iPad (iOS 16 ou posterior)",
              "tradutor,legendas,traduzir,PS5,Xbox,remote play,TV,jogos,ao vivo"),
    "ro": ("ro", "• Un iPhone sau iPad (iOS 16 sau mai nou)",
           "traducător,subtitrări,traducere,PS5,Xbox,remote play,TV,jocuri,live"),
    "ru-RU": ("ru", "• iPhone или iPad (iOS 16 или новее)",
              "переводчик,субтитры,перевод,PS5,Xbox,remote play,ТВ,игры,онлайн"),
    "ta-IN": ("ta-IN", "• iPhone அல்லது iPad (iOS 16 அல்லது புதியது)",
              "மொழிபெயர்ப்பு,சப்டைட்டில்,கேம்,PS5,Xbox,டிவி"),
    "te-IN": ("te-IN", "• iPhone లేదా iPad (iOS 16 లేదా కొత్తది)",
              "అనువాదం,సబ్‌టైటిల్స్,గేమ్,PS5,Xbox,టీవీ"),
    "th": ("th", "• iPhone หรือ iPad (iOS 16 ขึ้นไป)",
           "แปลภาษา,ซับไตเติ้ล,เกม,PS5,Xbox,ทีวี,แปลสด"),
    "tr-TR": ("tr", "• Bir iPhone veya iPad (iOS 16 ya da daha yeni)",
              "çevirmen,altyazı,çeviri,PS5,Xbox,remote play,TV,oyun,canlı"),
    "uk": ("uk", "• iPhone або iPad (iOS 16 або новіша)",
           "перекладач,субтитри,переклад,PS5,Xbox,remote play,ТБ,ігри,наживо"),
    "ur": ("ur-PK", "• iPhone یا iPad (iOS 16 یا اس سے نیا)",
           "مترجم,ترجمہ,سب ٹائٹل,گیم,PS5,Xbox,ٹی وی,لائیو"),
    "vi": ("vi", "• iPhone hoặc iPad (iOS 16 trở lên)",
           "dịch,phụ đề,trình dịch,PS5,Xbox,remote play,TV,trò chơi,trực tiếp"),
    "zh-CN": ("zh-Hans", "• iPhone 或 iPad（iOS 16 或更高版本）",
              "翻译,字幕,游戏,PS5,Xbox,远程游玩,电视,实时翻译,翻译器"),
    "zh-TW": ("zh-Hant", "• iPhone 或 iPad（iOS 16 或以上版本）",
              "翻譯,字幕,遊戲,PS5,Xbox,遙控遊玩,電視,即時翻譯,翻譯器"),
}

for play, (apple, requirement, keywords) in LANGS.items():
    assert len(keywords) <= 100, (play, len(keywords))
    lines = open(os.path.join(src, play, "full_description.txt"), encoding="utf-8").read().rstrip("\n").split("\n")
    assert len(lines) == 21, (play, len(lines))
    # line 9: "works with the phone's screen off (PS5)"; line 13: the Android requirement
    assert lines[8].startswith("•") and lines[12].startswith("•"), play
    lines[12] = requirement
    del lines[8]
    text = "\n".join(lines) + "\n"
    assert len(text) <= 4000
    d = os.path.join(out, apple)
    os.makedirs(d, exist_ok=True)
    files = {"name.txt": NAME, "description.txt": text, "keywords.txt": keywords,
             "support_url.txt": SUPPORT, "privacy_url.txt": PRIVACY, "marketing_url.txt": SUPPORT}
    for f, v in files.items():
        open(os.path.join(d, f), "w", encoding="utf-8", newline="\n").write(v.rstrip("\n") + "\n")
print(len(LANGS), "languages written to", os.path.normpath(out))
