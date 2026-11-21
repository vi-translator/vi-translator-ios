import SwiftUI

// ------------------------------------------------------------------------------------- Game profile

/**
 * Game profile: a game's read areas, how its translations look, and the game pages it translates.
 * Built-in profiles can't be changed: make a copy to adjust one (as the desktop).
 */
struct ProfilePanel: View {
    @EnvironmentObject var m: AppModel
    @Environment(\.kit) var k
    @State private var askDelete = false

    var body: some View {
        let cfg = m.cfg
        return VStack(alignment: .leading, spacing: 0) {
            H3(L("Game profile"))
            Muted(L("A profile holds a game's read areas, how its translations look, and the game's own pages it translates. Built-in profiles can't be changed: make a copy to adjust one."))
            if let p = cfg.activeProfile() {
                let builtin = cfg.isBuiltin(p)
                Field(label: L("Profile in use")) {
                    Select(options: profileOptions(cfg), value: Cfg.s(p, "id")) { cfg.useProfile($0) }
                }
                Card {
                    HStack {
                        if builtin {
                            Text(Cfg.s(p, "name")).font(k.font(k.base + 0.5, .bold)).foregroundColor(k.text)
                            Spacer()
                            Badge(L("Built-in"))
                        } else {
                            KInput(value: Cfg.s(p, "name")) { cfg.renameProfile($0) }
                            Badge(L("Yours"), on: true)
                        }
                    }
                    Muted(L("For {game} · {n} read area(s)", ("game", cfg.gameName(Cfg.s(p, "game"))), ("n", (p["areas"] as? NSArray)?.count ?? 0)), small: true).padding(.top, 8)
                    HStack(spacing: 8) {
                        KButton(L("Make a copy"), full: false) { cfg.copyProfile(p) }
                        if !builtin { KButton(L("Delete"), danger: true, full: false) { askDelete = true } }
                    }
                    .padding(.top, 12)
                }
                .padding(.top, 12)
                Muted(builtin ? L("Built-in profiles get updates for the game automatically. A copy keeps your changes and stays yours.")
                              : L("Your changes to read areas, text style and game pages are saved in this profile."), small: true)
                    .padding(.top, 10)
                    .confirmationDialog(L("Delete the profile “{name}”? This can't be undone.", ("name", Cfg.s(p, "name"))), isPresented: $askDelete, titleVisibility: .visible) {
                        Button(L("Delete"), role: .destructive) { cfg.deleteProfile(p) }
                    }
            }
        }
    }

    private func profileOptions(_ cfg: Cfg) -> [(String, String)] {
        var o: [(String, String)] = [(Select.group + "b", L("Built-in"))]
        for p in cfg.builtins() { o.append((Cfg.s(p, "id"), Cfg.s(p, "name"))) }
        if !cfg.profiles().isEmpty {
            o.append((Select.group + "m", L("Your profiles")))
            for p in cfg.profiles() { o.append((Cfg.s(p, "id"), Cfg.s(p, "name"))) }
        }
        return o
    }
}

// ------------------------------------------------------------------------------------- Read areas

/**
 * Read areas: each area is read separately; its translation's place, font, background, size and
 * text style; its position as percentages of the picture (or drag it in the picture above).
 */
struct AreasPanel: View {
    @EnvironmentObject var m: AppModel
    @Environment(\.kit) var k
    @State private var selected: String?
    @State private var showSample = true
    @State private var styleOpen = Set<String>()
    @State private var deleting: NSMutableDictionary?
    private let sample = "هذا نص تجريبي لمعاينة شكل الترجمة على الشاشة"

    var body: some View {
        let cfg = m.cfg
        let locked = cfg.locked()
        let sel = selected ?? cfg.areaList().first.map { Cfg.s($0, "id") }
        return VStack(alignment: .leading, spacing: 0) {
            LockNote()
            H3(L("Read areas"))
            Muted(L("Each area is read separately. Position and size are a percentage of the window, so they stay right if the window is resized."))
            // the picture with the areas: drag a box to move it, its corner to resize
            PreviewRepresentable(image: m.picture.image, lines: [], drawText: false, sample: showSample ? sample : nil, selected: sel,
                                 editable: !locked, rev: m.rev,
                                 moved: { _ in cfg.touched("areas") },
                                 tapped: { selected = $0 })
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(k.line, lineWidth: 1))
                .padding(.top, 12)
            if !locked { Muted(L("Drag a box to move it, drag its corners to resize."), small: true).padding(.top, 6) }
            Check(label: L("Show sample text"), on: showSample) { showSample = $0 }
            ForEach(cfg.areaList().map { (Cfg.s($0, "id"), $0) }, id: \.0) { item in
                areaCard(item.1, selected: item.0 == sel, locked: locked)
            }
            KButton(L("＋ Add read area"), primary: true) { addArea() }
                .disabled(locked)
                .padding(.top, 14)
        }
        .confirmationDialog(L("Delete the read area \"{name}\"?", ("name", Cfg.s(deleting, "name"))), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button(L("Delete"), role: .destructive) {
                if let a = deleting {
                    cfg.areas().remove(a)
                    cfg.touched("areas")
                }
                deleting = nil
            }
        }
    }

    private func changed() { m.cfg.touched("areas") }

    @ViewBuilder private func areaCard(_ a: NSMutableDictionary, selected sel: Bool, locked: Bool) -> some View {
        let cfg = m.cfg
        let id = Cfg.s(a, "id")
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                // read or not (the player's own choice, even with a built-in profile)
                Toggle("", isOn: Binding(get: { Cfg.b(a, "enabled", true) }, set: {
                    a["enabled"] = $0
                    cfg.setShown(kind: "area", id: id, on: $0)
                    changed()
                }))
                .labelsHidden().tint(k.accentUi).fixedSize()
                if locked {
                    Text(Cfg.s(a, "name")).font(k.font(k.base, .bold)).foregroundColor(k.text)
                } else {
                    KInput(value: Cfg.s(a, "name")) {
                        a["name"] = $0
                        changed()
                    }
                }
                Spacer(minLength: 0)
                if !locked {
                    Button { deleting = a } label: { Image(systemName: Icon.trash).foregroundColor(k.err) }.buttonStyle(.plain).padding(.leading, 8)
                }
            }
            if !sel {
                Muted(L("Translation: {where}", ("where", L(Self.placements.first { $0.0 == Cfg.s(a, "placement") }?.1 ?? ""))), small: true).padding(.top, 6)
            } else {
                areaForm(a, locked: locked)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).fill(k.panel))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(sel ? k.accentUi : k.line, lineWidth: sel ? 1.5 : 1))
        .contentShape(Rectangle())
        .onTapGesture { if !sel { selected = id } }
        .padding(.top, 12)
    }

    @ViewBuilder private func areaForm(_ a: NSMutableDictionary, locked: Bool) -> some View {
        let cfg = m.cfg
        let id = Cfg.s(a, "id")
        let st = Cfg.styleOf(a, cfg.style())
        Group {
            Field(label: L("Translation")) {
                Select(options: Self.placements.map { ($0.0, L("Translation: {where}", ("where", L($0.1)))) }, value: Cfg.s(a, "placement", "over")) { v in
                    if v == "custom" { toCustom(a) } else { a["placement"] = v }
                    changed()
                }
            }
            Field(label: L("Font")) {
                Select(options: Fonts.options(core: m.core?.engine.fontList() ?? [], withDefault: L("Main font ({font})", ("font", Cfg.s(st, "font_family")))),
                       value: Cfg.s(a, "font_family")) { a["font_family"] = $0; changed() }
            }
            Field(label: L("Background")) {
                Select(options: [("", L("Its text style's box")), ("none", L("None — outlined text, like game subtitles")), ("game", L("Game-style dark box"))],
                       value: Cfg.s(a, "background")) { a["background"] = $0; changed() }
            }
            Check(label: L("Match the game's text size"), on: Cfg.b(a, "match_size", true)) { a["match_size"] = $0; changed() }
            Check(label: L("Only text centred in the picture (subtitles)"), on: Cfg.b(a, "centered_only")) { a["centered_only"] = $0; changed() }
            Field(label: Cfg.b(a, "match_size", true) ? L("Fine-tune") : L("Text size")) {
                KSlider(range: 0.5...2, step: 0.05, value: Cfg.d(a, "font_scale", 1), format: { "\(Int(($0 * 100).rounded()))%" }) {
                    a["font_scale"] = ($0 * 100).rounded() / 100
                    changed()
                }
            }
        }
        .disabled(locked)
        // its text style (the profile's until changed here)
        Button {
            if styleOpen.contains(id) { styleOpen.remove(id) } else { styleOpen.insert(id) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: Icon.chevron).rotationEffect(.degrees(styleOpen.contains(id) ? 90 : 0)).foregroundColor(k.muted)
                Text(L("Text style")).font(k.font(k.base - 0.5, .bold)).foregroundColor(k.text)
            }
            .padding(.top, 12).padding(.bottom, 4)
        }
        .buttonStyle(.plain)
        if styleOpen.contains(id) { styleForm(a).disabled(locked) }
        LabelText(L("Read area")).padding(.top, 14)
        PosGrid(a: a, keys: ["x", "y", "w", "h"], changed: changed).disabled(locked)
        if Cfg.s(a, "placement") != "custom" {
            Field(label: L("Text sits")) {
                Select(options: Self.textPos.map { ($0.0, L($0.1)) }, value: Cfg.s(a, "text_pos")) { a["text_pos"] = $0; changed() }
            }
            .disabled(locked)
        } else {
            LabelText(L("Translation region")).padding(.top, 14)
            PosGrid(a: a, keys: ["out_x", "out_y", "out_w", "out_h"], changed: changed).disabled(locked)
            HStack(spacing: 8) {
                Select(options: [("top", L("Text at the top")), ("middle", L("Text in the middle")), ("bottom", L("Text at the bottom"))], value: Cfg.s(a, "out_valign", "bottom")) { a["out_valign"] = $0; changed() }
                Select(options: [("right", L("Right")), ("center", L("Centre")), ("left", L("Left"))], value: Cfg.s(a, "out_halign", "center")) { a["out_halign"] = $0; changed() }
            }
            .padding(.top, 8)
            .disabled(locked)
        }
    }

    /** The desktop's STYLE_FIELDS for one area: its own style from its first change on. */
    @ViewBuilder private func styleForm(_ a: NSMutableDictionary) -> some View {
        let s = Cfg.styleOf(a, m.cfg.style())
        let set: (String, Any) -> Void = { key, v in
            if !Cfg.has(a, "style") { a["style"] = Cfg.clone(m.cfg.style()) }
            (a["style"] as? NSMutableDictionary)?[key] = v
            changed()
        }
        let two: (Double) -> String = { String(format: "%.2f", $0) }
        Field(label: L("Text size (px at 1080p; scales with the game window)")) {
            KSlider(range: 10...96, step: 1, value: Cfg.d(s, "font_size", 26), format: { "\(Int($0)) px" }) { set("font_size", Int($0)) }
        }
        Check(label: L("Bold"), on: Cfg.b(s, "bold")) { set("bold", $0) }
        Field(label: L("Line spacing")) { KSlider(range: 1...2.2, step: 0.05, value: Cfg.d(s, "line_height", 1.5), format: two) { set("line_height", ($0 * 100).rounded() / 100) } }
        Field(label: L("Text colour")) { ColorPick(value: Cfg.s(s, "text_color", "#ffffff")) { set("text_color", $0) } }
        Check(label: L("Colour highlighted words like the game does"), on: Cfg.b(s, "keep_colors", true)) { set("keep_colors", $0) }
        Field(label: L("Box colour")) { ColorPick(value: Cfg.s(s, "bg_color", "#000000")) { set("bg_color", $0) } }
        Field(label: L("Box opacity")) { KSlider(range: 0...1, step: 0.05, value: Cfg.d(s, "bg_opacity", 0.65), format: two) { set("bg_opacity", ($0 * 100).rounded() / 100) } }
        Field(label: L("Box padding")) { KSlider(range: 0...30, step: 1, value: Cfg.d(s, "padding", 10), format: { String(Int($0)) }) { set("padding", Int($0)) } }
        Field(label: L("Box corner roundness")) { KSlider(range: 0...30, step: 1, value: Cfg.d(s, "radius", 10), format: { String(Int($0)) }) { set("radius", Int($0)) } }
        Field(label: L("Text outline colour")) { ColorPick(value: Cfg.s(s, "outline_color", "#000000")) { set("outline_color", $0) } }
        Field(label: L("Text outline width")) { KSlider(range: 0...6, step: 0.5, value: Cfg.d(s, "outline_width", 0), format: two) { set("outline_width", $0) } }
        Check(label: L("Text shadow"), on: Cfg.b(s, "shadow")) { set("shadow", $0) }
        if Cfg.has(a, "style") {
            KButton(L("Reset to defaults")) {
                a["style"] = NSNull()
                changed()
            }
            .padding(.top, 10)
        }
    }

    /** "Custom position": its region starts where the translation is now (over the area). */
    private func toCustom(_ a: NSMutableDictionary) {
        a["placement"] = "custom"
        if Cfg.d(a, "out_w") <= 0 {
            a["out_x"] = Cfg.d(a, "x")
            a["out_y"] = max(Cfg.d(a, "y") - 0.15, 0)
            a["out_w"] = Cfg.d(a, "w")
            a["out_h"] = 0.15
            a["out_valign"] = "bottom"
            a["out_halign"] = "center"
        }
    }

    private func addArea() {
        let cfg = m.cfg
        guard !cfg.locked() else { return }
        let id = "area_" + String(Int64(Date().timeIntervalSince1970 * 1000), radix: 36)
        let a = NSMutableDictionary(dictionary: [
            "id": id, "name": L("Area {n}", ("n", cfg.areas().count + 1)), "enabled": true,
            "x": 0.35, "y": 0.4, "w": 0.3, "h": 0.12, "placement": "above", "font_scale": 1, "font_family": "",
            "out_x": 0.35, "out_y": 0.25, "out_w": 0.3, "out_h": 0.15, "out_valign": "bottom", "out_halign": "center",
        ])
        cfg.areas().add(a)
        selected = id
        cfg.touched("areas")
    }

    static let placements: [(String, String)] = [
        ("under_text", "Below the game's text box (same left edge, at most its width)"),
        ("above_text", "Just above the game's text (centred on it)"),
        ("above", "Above the area"), ("below", "Below the area"), ("right", "To the right"), ("left", "To the left"),
        ("over", "On top of the area"), ("custom", "Custom position (drag it in the preview)"),
    ]

    static let textPos: [(String, String)] = [
        ("", "Automatic for this placement"),
        ("top-left", "Top left"), ("top-center", "Top centre"), ("top-right", "Top right"),
        ("middle-left", "Middle left"), ("middle-center", "Middle centre"), ("middle-right", "Middle right"),
        ("bottom-left", "Bottom left"), ("bottom-center", "Bottom centre"), ("bottom-right", "Bottom right"),
    ]
}

/** Four percentage fields for a rectangle kept as fractions (the desktop's posGrid). */
struct PosGrid: View {
    @Environment(\.kit) var k
    let a: NSMutableDictionary
    let keys: [String]
    let changed: () -> Void

    private static let labels = ["Left %", "Top %", "Width %", "Height %"]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<4, id: \.self) { i in
                VStack(alignment: .leading, spacing: 3) {
                    Text(L(Self.labels[i])).font(k.font(k.base - 3, .bold)).foregroundColor(k.muted)
                    KInput(value: String(format: "%.1f", Cfg.d(a, keys[i]) * 100), ltr: true) { t in
                        guard let v = Double(t.replacingOccurrences(of: ",", with: ".")) else { return }
                        let min = i >= 2 ? 0.02 : 0
                        a[keys[i]] = ((Swift.min(Swift.max(v / 100, min), 1)) * 10000).rounded() / 10000
                        if Cfg.d(a, keys[0]) + Cfg.d(a, keys[2]) > 1 { a[keys[2]] = 1 - Cfg.d(a, keys[0]) }
                        if Cfg.d(a, keys[1]) + Cfg.d(a, keys[3]) > 1 { a[keys[3]] = 1 - Cfg.d(a, keys[1]) }
                        changed()
                    }
                    .keyboardType(.decimalPad)
                }
            }
        }
        .padding(.top, 6)
    }
}

// ------------------------------------------------------------------------------------- Game pages

/** Game pages: the game's own pages that get a hand-made translation, in the game's look. */
struct PagesPanel: View {
    @EnvironmentObject var m: AppModel
    @Environment(\.kit) var k
    @State private var script: NSDictionary?
    @State private var loaded = false

    var body: some View {
        let cfg = m.cfg
        let game = cfg.profileGame()
        return VStack(alignment: .leading, spacing: 0) {
            LockNote()
            H3(L("Game pages"))
            Muted(L("The game's own pages that get a hand-made translation, in the game's look."))
            if loaded {
                let pages = script?["pages"] as? NSArray
                if script == nil || (pages?.count ?? 0) == 0 {
                    Callout(script == nil ? L("The game pages' switches come to the phone app with an update. The pages themselves are translated as on the PC.")
                                          : L("{game}'s own pages aren't known yet, so none are translated for now. Subtitles and the read areas work as usual.", ("game", cfg.gameName(game))))
                        .padding(.top, 12)
                } else {
                    let o = cfg.profileOpts()
                    ForEach(Array(((script?["options"] as? NSArray) ?? []).enumerated()), id: \.offset) { _, x in
                        if let opt = x as? NSDictionary {
                            let id = Cfg.s(opt, "id")
                            let more = (o["more"] as? NSMutableDictionary)
                            let on = more?[id] != nil ? Cfg.b(more, id) : Cfg.b(opt, "on")
                            Card(pad: 12) {
                                Check(label: { let n = text(opt["name"]); return n.isEmpty ? id : n }(), on: on) { v in
                                    let mo = (o["more"] as? NSMutableDictionary) ?? { let d = NSMutableDictionary(); o["more"] = d; return d }()
                                    mo[id] = v
                                    cfg.setShown(kind: "page", id: id, on: v)
                                    cfg.touched("profile_opts")
                                }
                                let about = text(opt["about"])
                                if !about.isEmpty { Muted(about, small: true) }
                            }
                            .padding(.top, 10)
                        }
                    }
                }
                fontsCard
            }
        }
        .task(id: game) {
            guard let core = m.core else {
                loaded = true
                return
            }
            let s = await Task.detached { core.engine.pageOptions(game: game) }.value
            let d = Cfg.parse(s)
            script = d.count == 0 ? nil : d
            loaded = true
        }
    }

    /** a script's words: plain, or one per interface language */
    private func text(_ v: Any?) -> String {
        if let s = v as? String { return s }
        if let o = v as? NSDictionary {
            let s = Cfg.s(o, I18n.code)
            if !s.isEmpty { return s }
            let en = Cfg.s(o, "en")
            if !en.isEmpty { return en }
            return (o.allValues.first as? String) ?? ""
        }
        return ""
    }

    private var fontsCard: some View {
        let cfg = m.cfg
        let o = cfg.profileOpts()
        let fonts = Fonts.options(core: m.core?.engine.fontList() ?? [], withDefault: nil)
        return Card(pad: 12) {
            Field(label: L("Title font")) {
                Select(options: fonts, value: Cfg.s(o, "title_font", "Lalezar")) { o["title_font"] = $0; cfg.touched("profile_opts") }
            }
            Field(label: L("Reason and button font")) {
                Select(options: fonts, value: Cfg.s(o, "text_font", "Tajawal")) { o["text_font"] = $0; cfg.touched("profile_opts") }
            }
        }
        .disabled(cfg.locked())
        .padding(.top, 10)
    }
}
