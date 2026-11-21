import SwiftUI
import UIKit

/**
 * The desktop app's look ("Vice City", from its logo; ui/style.css), as the Android app's Kit: a
 * night-purple base, a sunset pink → orange accent, a neon teal for "live". Dark is the main theme;
 * light keeps the accents on a soft, warm white.
 */
struct Kit {
    let dark: Bool

    var bg: Color { Kit.c(dark ? 0x0f0b17 : 0xf7f3fa) }
    var panel: Color { Kit.c(dark ? 0x17111f : 0xffffff) }
    var panel2: Color { Kit.c(dark ? 0x20182b : 0xf1eaf6) }
    var panel3: Color { Kit.c(dark ? 0x2a2038 : 0xe9dff1) }
    var line: Color { Kit.c(dark ? 0x2f2440 : 0xe3d8ec) }
    var text: Color { Kit.c(dark ? 0xf1ebf8 : 0x241a31) }
    var muted: Color { Kit.c(dark ? 0xa193b5 : 0x6f6283) }
    var neon: Color { Kit.c(dark ? 0x3ef0d8 : 0x0d9488) }
    var accentUi: Color { Kit.c(dark ? 0xff6fae : 0xd42e78) }
    var accentSoft: Color { dark ? Color(red: 1, green: 0x5a / 255, blue: 0xa5 / 255).opacity(0x1f / 255) : Color(red: 0xe0 / 255, green: 0x36 / 255, blue: 0x7f / 255).opacity(0x1a / 255) }
    var stage: Color { Kit.c(dark ? 0x07050b : 0x0d0915) }
    var ok: Color { Kit.c(dark ? 0x3ef0d8 : 0x0f8f6b) }
    var warn: Color { Kit.c(dark ? 0xffb35c : 0xc2620a) }
    var err: Color { Kit.c(dark ? 0xff7a7a : 0xdc2626) }
    /** the read-area boxes (drawn over the dark game picture) */
    static let accent = UIColor(red: 1, green: 0xd2 / 255, blue: 0x5a / 255, alpha: 1)
    static let sunset = LinearGradient(colors: [c(0xff4f9a), c(0xff8a3d)], startPoint: .leading, endPoint: .trailing)

    /** the base text size: Arabic script reads better a little bigger */
    var base: CGFloat { I18n.arabicScript ? 16 : 15 }

    // ---- type: the desktop's Tajawal for Arabic-script interfaces, the system's for the rest
    func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        if I18n.arabicScript {
            let name = weight == .heavy || weight == .black ? "Tajawal-ExtraBold" : (weight == .bold || weight == .semibold ? "Tajawal-Bold" : "Tajawal-Regular")
            return .custom(name, fixedSize: size)
        }
        return .system(size: size, weight: weight)
    }

    static func c(_ rgb: UInt32) -> Color {
        Color(red: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255)
    }


    /** "#rrggbb" (or "#rgb") as a colour; black when it isn't one */
    static func parse(_ s: String) -> UIColor {
        var h = s.trimmingCharacters(in: .whitespaces)
        if h.hasPrefix("#") { h.removeFirst() }
        if h.count == 3 { h = h.map { "\($0)\($0)" }.joined() }
        guard h.count == 6 || h.count == 8, let v = UInt64(h, radix: 16) else { return .black }
        let rgb = h.count == 8 ? v >> 8 : v
        let a = h.count == 8 ? CGFloat(v & 255) / 255 : 1
        return UIColor(red: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255, blue: CGFloat(rgb & 255) / 255, alpha: a)
    }

    static func hex(_ c: UIColor) -> String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02x%02x%02x", Int(r * 255), Int(g * 255), Int(b * 255))
    }
}

private struct KitKey: EnvironmentKey {
    static let defaultValue = Kit(dark: true)
}

extension EnvironmentValues {
    var kit: Kit {
        get { self[KitKey.self] }
        set { self[KitKey.self] = newValue }
    }
}

/** The fonts bundled with the app (the desktop's BUNDLED_FONTS, SIL Open Font License). */
enum Fonts {
    static let bundled: [(String, String)] = [
        ("Lalezar", "heavy display, great for game titles"),
        ("Changa", "bold geometric"),
        ("Cairo", "clean, many weights"),
        ("Tajawal", "clean text"),
        ("Noto Sans Arabic Medium", "like GTA VI's subtitles"),
    ]

    static func options(core: [String], withDefault: String?) -> [(String, String)] {
        var o: [(String, String)] = []
        if let d = withDefault { o.append(("", d)) }
        for (n, note) in bundled { o.append((n, "\(n) — \(L(note))")) }
        for n in core where !bundled.contains(where: { $0.0 == n }) { o.append((n, n)) }
        return o
    }

    /** The bundled font for a name the settings use ("Tajawal", "Noto Sans Arabic Medium"...), at [size]. */
    static func ui(_ name: String, size: CGFloat, bold: Bool = false) -> UIFont {
        let family: String
        if name.hasPrefix("Lalezar") { family = "Lalezar" }
        else if name.hasPrefix("Changa") { family = "Changa" }
        else if name.hasPrefix("Cairo") { family = "Cairo" }
        else if name.hasPrefix("Noto Sans Arabic") { family = "Noto Sans Arabic" }
        else { return UIFont(name: bold ? "Tajawal-Bold" : "Tajawal-Regular", size: size) ?? .systemFont(ofSize: size, weight: bold ? .bold : .regular) }
        let names = UIFont.fontNames(forFamilyName: family)
        let pick = names.first { bold ? $0.contains("Bold") : !$0.contains("Bold") } ?? names.first
        if let n = pick, let f = UIFont(name: n, size: size) { return f }
        return .systemFont(ofSize: size, weight: bold ? .bold : .regular)
    }
}
