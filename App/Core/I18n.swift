import Foundation

/**
 * The interface's words, as the desktop and Android apps': each phrase is looked up by its English
 * text in the desktop's dictionaries (i18n/<code>.json, 33 languages), then in the phone's own
 * (i18n-phone/<code>.json, what only the phone apps say) and the iPhone's (i18n-ios/<code>.json,
 * what only this app says); a phrase missing from all stays English. {name} placeholders are filled.
 */
enum I18n {
    struct UiLang: Hashable {
        let code: String
        let name: String
        let rtl: Bool
    }

    private(set) static var langs: [UiLang] = [UiLang(code: "en", name: "English", rtl: false)]
    /** the interface language in use */
    private(set) static var code = "en"
    private static var dict: [String: String] = [:]

    static var rtl: Bool { langs.first { $0.code == code }?.rtl ?? false }

    /** Arabic-script interfaces use the desktop's Tajawal font */
    static var arabicScript: Bool { ["ar", "fa", "ur"].contains(code) }

    static func load(_ wanted: String, bundle: Bundle = .main) {
        if langs.count == 1 { langs = readLangs(bundle) }
        code = langs.first { $0.code == wanted }?.code ?? "en"
        if code == "en" {
            dict = [:]
        } else {
            dict = read(bundle, "i18n", code)
                .merging(read(bundle, "i18n-phone", code)) { _, b in b }
                .merging(read(bundle, "i18n-ios", code)) { _, b in b }
        }
    }

    /** The interface language for a phone whose own language is [locale] (the desktop's choice for a new install). */
    static func fromLocale(_ locale: Locale) -> String {
        let tag = locale.identifier.replacingOccurrences(of: "_", with: "-")
        if let exact = langs.first(where: { $0.code.caseInsensitiveCompare(tag) == .orderedSame }) { return exact.code }
        let lang = locale.languageCode ?? "en"
        let region = locale.regionCode ?? ""
        let script = locale.scriptCode ?? ""
        switch lang {
        case "zh": return script == "Hant" || ["TW", "HK", "MO"].contains(region) ? "zh-Hant" : "zh-Hans"
        case "es": return region == "ES" ? "es-ES" : "es-MX"
        case "pt": return "pt-BR"
        case "in": return "id"
        case "tl": return "fil"
        default: return langs.first { $0.code == lang }?.code ?? "en"
        }
    }

    static func lookup(_ en: String) -> String { dict[en] ?? en }

    private static func readLangs(_ bundle: Bundle) -> [UiLang] {
        guard let url = bundle.url(forResource: "languages", withExtension: "json", subdirectory: "i18n"),
              let data = try? Data(contentsOf: url),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return [UiLang(code: "en", name: "English", rtl: false)]
        }
        return arr.compactMap { o in
            guard let c = o["code"] as? String, let n = o["name"] as? String else { return nil }
            return UiLang(code: c, name: n, rtl: (o["rtl"] as? Bool) ?? false)
        }
    }

    private static func read(_ bundle: Bundle, _ dir: String, _ code: String) -> [String: String] {
        guard let url = bundle.url(forResource: code, withExtension: "json", subdirectory: dir),
              let data = try? Data(contentsOf: url),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return o.compactMapValues { $0 as? String }
    }
}

/** A phrase in the interface's language, its {placeholders} filled: L("Waking {name}…", ("name", n)). */
func L(_ en: String, _ vars: (String, Any)...) -> String {
    var s = I18n.lookup(en)
    for (k, v) in vars { s = s.replacingOccurrences(of: "{\(k)}", with: "\(v)") }
    return s
}
