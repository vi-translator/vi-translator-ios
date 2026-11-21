import Foundation

/** The user's choices on this phone, kept across runs (the desktop's settings are the core's: Cfg). */
enum Prefs {
    private static let d = UserDefaults.standard

    /** "ps5" or "xbox" ("" until chosen) */
    static var console: String {
        get { d.string(forKey: "console") ?? "" }
        set { d.set(newValue, forKey: "console") }
    }

    /** the app's own language ("" for the phone's) */
    static var uiLanguage: String {
        get { d.string(forKey: "ui_language") ?? "" }
        set { d.set(newValue, forKey: "ui_language") }
    }

    /** dark theme (the desktop's "theme" setting, kept here too for the first frame) */
    static var dark: Bool {
        get { d.object(forKey: "dark") as? Bool ?? true }
        set { d.set(newValue, forKey: "dark") }
    }

    /** the live picture in the app (the header's Preview switch) */
    static var preview: Bool {
        get { d.object(forKey: "preview") as? Bool ?? true }
        set { d.set(newValue, forKey: "preview") }
    }

    /** "play" or "setup", as last left */
    static var lastMode: String {
        get { d.string(forKey: "mode") ?? "setup" }
        set { d.set(newValue, forKey: "mode") }
    }

    /** the PS5 stream's resolution: 720 (the default) or 1080 */
    static var psResolution: Int {
        get { d.object(forKey: "ps_resolution") as? Int ?? 720 }
        set { d.set(newValue, forKey: "ps_resolution") }
    }
}
