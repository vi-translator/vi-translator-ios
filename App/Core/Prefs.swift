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

    // ---- the live translations full screen (LiveFull)

    /** the translations' text size there, in points */
    static var liveTextSize: Double {
        get { d.object(forKey: "live_text_size") as? Double ?? 30 }
        set { d.set(newValue, forKey: "live_text_size") }
    }

    /** the English line shown above each translation there */
    static var liveEnglish: Bool {
        get { d.object(forKey: "live_english") as? Bool ?? true }
        set { d.set(newValue, forKey: "live_english") }
    }

    /** "auto" (turns with the phone), "portrait" or "landscape" */
    static var liveRotation: String {
        get { d.string(forKey: "live_rotation") ?? "auto" }
        set { d.set(newValue, forKey: "live_rotation") }
    }

    /**
     * Keep translating with the screen off (PS5): the game's sound plays on the phone, so iOS keeps
     * the app running in the background. Off by default.
     */
    static var screenOff: Bool {
        get { d.object(forKey: "screen_off") as? Bool ?? false }
        set { d.set(newValue, forKey: "screen_off") }
    }

    /** the game's sound's volume on the phone then, 0 to 1 */
    static var phoneVolume: Double {
        get { d.object(forKey: "phone_volume") as? Double ?? 0.3 }
        set { d.set(newValue, forKey: "phone_volume") }
    }

    /** the PS5 picture's frames a second in the app's preview: 10, 15 (the default) or 30 (the stream's own) */
    static var previewFps: Int {
        get { d.object(forKey: "preview_fps") as? Int ?? 15 }
        set { d.set(newValue, forKey: "preview_fps") }
    }

    /** the capture card chosen in Source (its unique ID; none: the first connected) */
    static var captureCard: String {
        get { d.string(forKey: "capture_card") ?? "" }
        set { d.set(newValue, forKey: "capture_card") }
    }

    /** the PS5 stream's resolution: 720 (the default) or 1080 */
    static var psResolution: Int {
        get { d.object(forKey: "ps_resolution") as? Int ?? 720 }
        set { d.set(newValue, forKey: "ps_resolution") }
    }
}
