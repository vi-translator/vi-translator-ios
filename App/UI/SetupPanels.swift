import SwiftUI
import WebKit

// ------------------------------------------------------------------------------------- Show on

/**
 * Show on: the TVs (the desktop's "Show on a TV": connect with the code the TV shows), the live
 * translations on other devices (the home-network page), and the preview's options.
 */
struct ShowPanel: View {
    @EnvironmentObject var m: AppModel
    @Environment(\.kit) var k
    @State private var found: [FoundTv]?
    @State private var looking = false
    @State private var connected: [TvInfo] = []
    @State private var lan: (url: String, error: String, qr: String)?
    @State private var codeFor: CodeTarget?
    @State private var typing = false
    @State private var forgetting: TvInfo?

    struct CodeTarget: Identifiable {
        let address: String
        let name: String
        var id: String { address }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
          Group {
            // (the desktop's "Overlays on this PC": here, the translations drawn over the picture in this app)
            H3(L("Overlays on this phone"))
            Check(label: L("Show the overlays on this phone"), on: m.cfg.bool("device_overlays", true)) { m.cfg.put("device_overlays", $0, now: true) }
          }
          Group {
            H3(L("Show on a TV"))
            Muted(L("The translations over the game on a Google TV, Android TV, LG or Samsung TV, with the VI Translator app. Open the app on the TV, then connect it here with the code it shows."))
            KButton(L("Connect a TV"), icon: Icon.tv, primary: true) { findTvs() }.padding(.top, 12)
            if looking {
                Muted(L("Looking for TVs on the home network…"), small: true).padding(.top, 10)
            } else if let f = found {
                if f.isEmpty {
                    Callout(L("No TV found. Is VI Translator open on the TV, on the same network? You can also type its address.")).padding(.top, 10)
                }
                ForEach(f, id: \.address) { tv in
                    HStack(spacing: 10) {
                        Image(systemName: Icon.tv).foregroundColor(k.muted)
                        Text(tv.name).font(k.font(k.base, .bold)).foregroundColor(k.text)
                        Spacer()
                        KButton(L("Connect"), primary: true, full: false) { codeFor = CodeTarget(address: tv.address, name: tv.name) }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 12).fill(k.panel))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(k.line, lineWidth: 1))
                    .padding(.top, 8)
                }
            }
            KLink(L("Type the TV's address")) { typing = true }
            if !connected.isEmpty {
                LabelText(L("Connected TVs")).padding(.top, 14).padding(.bottom, 4)
                ForEach(connected, id: \.id) { tv in
                    HStack(spacing: 10) {
                        Image(systemName: Icon.tv).foregroundColor(tv.online ? k.accentUi : k.muted)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tv.name).font(k.font(k.base, .bold)).foregroundColor(k.text)
                            Muted(tv.online ? L("Showing the translations") : L("Not connected now (the TV is off, or VI Translator isn't open on it)"), small: true)
                        }
                        Spacer()
                        // (its translations on or off at once, while translating: it stays connected)
                        Toggle("", isOn: Binding(get: { tv.on }, set: { on in setTv(tv.id, on) }))
                            .labelsHidden().tint(k.accentUi)
                            .accessibilityLabel(L("Show the translations on this TV"))
                        KLink(L("Remove")) { forgetting = tv }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 12).fill(k.panel))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(k.line, lineWidth: 1))
                    .padding(.top, 8)
                }
                // (iOS pauses the app soon after it leaves the screen, and the TVs' page with it)
                Callout(L("Keep VI Translator open on this phone while playing: the TV gets the translations from it, and iOS pauses apps in the background."), k.warn)
                    .padding(.top, 10)
                Muted(L("You don't need the PS Remote Play app: VI Translator connects to the PS5 itself (the PS5 streams to one app at a time). On an iPad, Split View keeps another app beside it. With a PS5, “Keep translating with the screen off” (Source) lets it go on in the background."), small: true)
                    .padding(.top, 6)
            }
          }
          Group {
            H3(L("Live translations on other devices"))
            Check(label: L("Share on my home network"), on: m.cfg.bool("lan_page")) {
                m.cfg.put("lan_page", $0)
                updateLan()
            }
            Callout(lanText).padding(.top, 4)
            if let l = lan, !l.url.isEmpty, l.qr.contains("<svg") {
                QrView(svg: l.qr).frame(width: 170, height: 170).padding(.top, 8)
            }
            Check(label: L("Allow changes from that page"), on: m.cfg.bool("lan_control")) { m.cfg.put("lan_control", $0) }
            Muted(L("Lets the page switch the overlays and the live translations, and show or hide read areas and game pages."), small: true)
          }
          Group {
            H3(L("Preview"))
            Field(label: L("PS5 picture in the app (frames per second)"), help: L("Only what the app shows: the reading and the TVs don't change. 30 is the stream's own; fewer saves battery.")) {
                Select(options: [("10", "10"), ("15", "15"), ("30", "30")], value: String(Prefs.previewFps)) {
                    Prefs.previewFps = Int($0) ?? 15
                    m.rev += 1
                }
            }
            Check(label: L("Show frames per second (fps) on the preview"), on: m.cfg.bool("fps_badge")) { m.cfg.put("fps_badge", $0) }
            Field(label: L("Where it shows")) {
                Select(options: [("top-left", L("Top left")), ("top-right", L("Top right")), ("bottom-left", L("Bottom left")), ("bottom-right", L("Bottom right"))],
                       value: m.cfg.str("fps_corner", "top-right")) { m.cfg.put("fps_corner", $0) }
            }
          }
        }
        .onAppear {
            listTvs()
            updateLan()
        }
        .sheet(item: $codeFor) { t in
            CodeSheet(target: t) {
                codeFor = nil
                found = nil
                listTvs()
            }
            .environmentObject(m).environment(\.kit, k)
        }
        .sheet(isPresented: $typing) {
            AddressSheet { a in
                typing = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { codeFor = CodeTarget(address: a, name: a) }
            }
            .environment(\.kit, k)
        }
        .confirmationDialog(L("Disconnect {name}?", ("name", forgetting?.name ?? "")), isPresented: Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } }), titleVisibility: .visible) {
            Button(L("Remove"), role: .destructive) {
                if let tv = forgetting, let core = m.core {
                    m.io.async {
                        core.forgetTv(tv.id)
                        DispatchQueue.main.async { listTvs() }
                    }
                }
                forgetting = nil
            }
        }
    }

    private var lanText: String {
        if !m.cfg.bool("lan_page") { return L("Off. Turn it on to read the live translations on another device on your home network.") }
        guard let l = lan else { return L("Starting…") }
        if !l.url.isEmpty { return L("Open {url} on a phone, tablet or PC on the same network.", ("url", l.url)) }
        if !l.error.isEmpty { return L("The page couldn't start ({error}). Another program may be using this port.", ("error", l.error)) }
        return L("Starting…")
    }

    private func listTvs() {
        guard let core = m.core else { return }
        m.io.async {
            let tvs = core.pairedTvs()
            DispatchQueue.main.async {
                connected = tvs
                m.tvCount = tvs.count
            }
        }
    }

    private func setTv(_ id: String, _ on: Bool) {
        connected = connected.map { var t = $0; if t.id == id { t.on = on }; return t }
        guard let core = m.core else { return }
        m.io.async { core.setTvOn(id, on) }
    }

    private func findTvs() {
        guard let core = m.core else { return }
        looking = true
        found = nil
        m.io.async {
            let tvs = core.findTvs()
            DispatchQueue.main.async {
                looking = false
                found = tvs
            }
        }
    }

    private func updateLan(tries: Int = 0) {
        guard m.cfg.bool("lan_page"), let core = m.core else {
            lan = nil
            return
        }
        // (the setting is saved first; the page starts with it)
        m.cfg.flush()
        DispatchQueue.main.asyncAfter(deadline: .now() + (tries == 0 ? 0.3 : 0.4)) {
            m.io.async {
                let o = Cfg.parse(core.engine.lanInfo())
                let url = Cfg.s(o, "url"), err = Cfg.s(o, "error"), qr = Cfg.s(o, "qr")
                DispatchQueue.main.async {
                    lan = (url, err, qr)
                    if url.isEmpty && err.isEmpty && tries < 20 { updateLan(tries: tries + 1) }
                }
            }
        }
    }
}

/** The code the TV shows, then connect. */
struct CodeSheet: View {
    @EnvironmentObject var m: AppModel
    @Environment(\.kit) var k
    let target: ShowPanel.CodeTarget
    let connected: () -> Void
    @State private var code = ""
    @State private var msg = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("Enter the code {name} shows", ("name", target.name))).font(k.font(k.base + 0.5, .bold)).foregroundColor(k.text)
            KInput(value: code, placeholder: "000000", ltr: true, number: true) { code = $0 }
            if !msg.isEmpty { Muted(msg, small: true) }
            KButton(L("Connect"), primary: true) { connect() }
            Spacer()
        }
        .sheetCard(k)
        .presentationDetents([.medium])
    }

    private func connect() {
        let c = Ps5.digitsOnly(code)
        guard c.count == 6 else {
            // (the PS5's 8-digit PIN goes in Source, not here)
            msg = c.count == 8 ? L("The TV's code has 6 digits. The 8-digit PIN is the PS5's: it goes in Source › PlayStation 5.") : L("The code has 6 digits.")
            return
        }
        guard let core = m.core else { return }
        msg = L("Connecting…")
        let address = target.address
        m.io.async {
            let r = core.pairTv(address: address, code: c)
            DispatchQueue.main.async {
                switch r {
                case .ok: msg = L("Connected")
                case .wrongCode: msg = L("That isn't the code the TV shows.")
                case .newCode: msg = L("Too many wrong codes: the TV shows a new one.")
                case .notSharing: msg = L("This phone isn't on a home network: connect it to the same Wi-Fi as the TV.")
                case .unreachable: msg = L("The TV didn't answer. Is VI Translator still open on it?")
                }
                if r == .ok { connected() }
            }
        }
    }
}

struct AddressSheet: View {
    @Environment(\.kit) var k
    let next: (String) -> Void
    @State private var a = ""
    @State private var msg = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("The TV's address")).font(k.font(k.base + 0.5, .bold)).foregroundColor(k.text)
            KInput(value: a, placeholder: "192.168.1.30", ltr: true) { a = $0 }
            if !msg.isEmpty { Muted(msg, small: true) }
            KButton(L("Next"), primary: true) {
                let t = Ps5.asciiDigits(a).trimmingCharacters(in: .whitespaces)
                guard !t.isEmpty else { return }
                // (an IP address or a host name, with the TV app's port or not: "192.168.1.30:8792")
                var host = t
                if let i = t.lastIndex(of: ":") {
                    let port = t[t.index(after: i)...]
                    if !port.isEmpty, port.count <= 5, port.allSatisfy({ $0.isASCII && $0.isNumber }) { host = String(t[..<i]) }
                }
                guard Ps5.validAddress(host), !Ps5.looksLikePin(t) else {
                    msg = L("That isn't an IP address (like 192.168.1.20) or a host name.")
                    return
                }
                next(t)
            }
            Spacer()
        }
        .sheetCard(k)
        .presentationDetents([.medium])
    }
}

/** The home-network page's QR code (the core draws it as SVG). */
struct QrView: UIViewRepresentable {
    let svg: String

    func makeUIView(context: Context) -> WKWebView {
        let w = WKWebView()
        w.isOpaque = false
        w.scrollView.isScrollEnabled = false
        w.isUserInteractionEnabled = false
        return w
    }

    func updateUIView(_ w: WKWebView, context: Context) {
        let page = "<html><head><meta name=viewport content='width=device-width'></head><body style=\"margin:0;background:#fff\">"
            + svg.replacingOccurrences(of: "<svg", with: "<svg style=\"width:100%;height:100%\"") + "</body></html>"
        w.loadHTMLString(page, baseURL: nil)
    }
}

// ------------------------------------------------------------------------------------- Snapshot

/** Snapshot: the whole picture translated at once, like a translated photo; and its service. */
struct SnapshotPanel: View {
    @EnvironmentObject var m: AppModel
    @Environment(\.kit) var k
    @State private var status: (String, Bool)?
    @State private var snap: SnapResult?

    var body: some View {
        let cfg = m.cfg
        let live = TranslatorPanel.engines.first { $0.0 == cfg.str("engine") }
        var opts: [(String, String)] = [("", L("Same as live translations ({name})", ("name", live.map { L($0.1) } ?? cfg.str("engine"))))]
        for e in TranslatorPanel.engines where e.0 != "local" {
            opts.append((e.0, e.0 == "claude" || e.0 == "openai" ? L("{name} — reads the picture", ("name", L(e.1))) : L(e.1)))
        }
        opts.append(("gemini-image", L("Gemini (Nano Banana) — redraws the picture in the language")))
        opts.append(("azure-image", L("Azure image translation — picture in, picture out")))
        let svc = cfg.str("snap_service")
        let used = svc.isEmpty ? cfg.str("engine") : svc
        let help: String
        switch used {
        case "gemini-image": help = L("Google's image model redraws the whole picture with its text in the language: the most natural look. It can change small details (an icon, a number, a car), takes 10–30 s and Google bills about $0.03–0.13 per picture. Needs a Gemini API key from Google AI Studio.")
        case "azure-image": help = L("Azure redraws the picture with the translation. Needs an Azure Translator resource with its own endpoint (https://<name>.cognitiveservices.azure.com) and its key. Billed by Azure per picture.")
        case "claude", "openai": help = L("The picture and the text the app found go to the model in one request: it fixes misread words and translates with the whole screen as context. Uses the key and model from the Translator tab.")
        default: help = L("Each piece of text is translated on its own, the translation memory first, so the game's words match the subtitles.")
        }
        return VStack(alignment: .leading, spacing: 0) {
          Group {
            H3(L("Snapshot"))
            Muted(L("Translates all the text on the game's picture at once and shows it over the picture, like a translated photo: menus, the map, the phone, a car's stats."))
            KButton(L("Translate the whole picture"), icon: Icon.camera, primary: true) { take() }.padding(.top, 12)
            if let s = status { Callout(s.0, s.1 ? k.err : nil).padding(.top, 8) }
            KButton(L("Share the picture as read"), icon: "square.and.arrow.up") {
                if let u = Snaps.lastFrame(m) { sharing = ShareItem(url: u) } else { status = (L("No picture yet"), true) }
            }
            .padding(.top, 8)
            Muted(L("The last frame of the game exactly as the app reads it (PNG): send it with a problem report, for example a page that isn't translated."), small: true)
          }
          Group {
            H3(L("Snapshot service"))
            Field(label: L("Service"), help: help) {
                Select(options: opts, value: svc) { cfg.put("snap_service", $0) }
            }
            if used == "azure-image" {
                Field(label: L("Azure endpoint")) { KInput(value: cfg.str("snap_azure_endpoint"), placeholder: "https://<name>.cognitiveservices.azure.com", ltr: true) { cfg.put("snap_azure_endpoint", $0.trimmingCharacters(in: .whitespaces)) } }
                Field(label: L("Azure key")) { KInput(value: cfg.str("snap_azure_key"), secure: true, ltr: true) { cfg.put("snap_azure_key", $0.trimmingCharacters(in: .whitespaces)) } }
            }
            if used == "gemini-image" {
                Field(label: L("Gemini API key")) { KInput(value: cfg.str("snap_gemini_key"), secure: true, ltr: true) { cfg.put("snap_gemini_key", $0.trimmingCharacters(in: .whitespaces)) } }
                let models = [
                    ("gemini-nano-banana-2.1", L("Nano Banana 2.1 — recommended, about $0.05 a picture")),
                    ("gemini-3-pro-image", L("Nano Banana Pro — best text, about $0.13 a picture")),
                    ("gemini-3.1-flash-lite-image", L("Nano Banana 2 Lite — fastest, about $0.03 a picture")),
                ]
                Field(label: L("Model")) { Select(options: models, value: cfg.str("snap_gemini_model", models[0].0)) { cfg.put("snap_gemini_model", $0) } }
            }
          }
          Group {
            Field(label: L("Behind the translation")) {
                Select(options: [("blur", L("The picture, blurred")), ("solid", L("A solid color"))], value: cfg.str("snap_style") == "solid" ? "solid" : "blur") { cfg.put("snap_style", $0) }
            }
            Check(label: L("Keep every snapshot in Photos"), on: cfg.bool("snap_save", true)) { cfg.put("snap_save", $0) }
            Check(label: L("Allow snapshots from the home-network page"), on: cfg.bool("snap_lan", true)) { cfg.put("snap_lan", $0) }
            Muted(L("Phones and tablets showing the live translations get a snapshot button too."), small: true)
            Muted(L("Text a game page marks as private (other players' names) is never read or sent: it's covered in the picture."), small: true).padding(.top, 10)
          }
        }
        .sheet(item: $snap) { s in SnapView(snap: s).environment(\.kit, k) }
        .sheet(item: $sharing) { s in ShareSheet(items: [s.url]) }
    }

    @State private var sharing: ShareItem?

    private func take() {
        status = (L("Translating the whole picture…"), false)
        Snaps.take(m) { r in
            switch r {
            case let .success(s):
                status = nil
                snap = s
            case let .failure(e):
                status = (L("Could not translate the picture: {e}", ("e", e.localizedDescription)), true)
            }
        }
    }
}

// ------------------------------------------------------------------------------------- Translator

/** Translator: the language, the translation service (with its keys), and the translation memory. */
struct TranslatorPanel: View {
    @EnvironmentObject var m: AppModel
    @Environment(\.kit) var k
    @State private var memory = ""
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        let cfg = m.cfg
        let langs = m.core?.languages ?? []
        let engine = cfg.str("engine", "local")
        return VStack(alignment: .leading, spacing: 0) {
            // VI Translator's ready translations first (on by default): turning them off asks first, as every line
            // then waits for the translator (and with "Translation memory only", lines not in the player's own
            // memory aren't translated at all)
            Card(pad: 12) {
                Check(label: L("Use VI Translator's ready translations first"), on: cfg.bool("shared_translations", true)) { v in
                    if v { cfg.put("shared_translations", true) } else { askShared = true }
                }
                Muted(L("Most GTA VI lines are already translated and reviewed, and are shown instantly. Only lines not found there go to the translator chosen below. Keep this on: with it off, every line waits for the translator and translations come much slower."), small: true)
            }
            .confirmationDialog(L("Turn off VI Translator's ready translations? Every line will then wait for the translator chosen below, so translations will come much slower.")
                                + (engine == "local" ? " " + L("With no translation service chosen, lines not in your own memory won't be translated at all.") : ""),
                                isPresented: $askShared, titleVisibility: .visible) {
                Button(L("Turn off"), role: .destructive) { cfg.put("shared_translations", false) }
            }
            H3(L("Language"))
            Select(options: langs.map { ($0.code, $0.name.isEmpty || $0.name == $0.native ? $0.native : "\($0.name) — \($0.native)") },
                   value: cfg.str("target_lang", "ar")) { cfg.put("target_lang", $0, now: true) }
            Muted(L("The phone app has no free offline model: lines the translation memory knows (reviewed translations from vitranslator.app) are free; for the others choose DeepL, Azure, Google, LibreTranslate, Claude or ChatGPT."), small: true)
                .padding(.top, 6)

            H3(L("Translation service"))
            ForEach(Self.engines, id: \.0) { e in
                let on = engine == e.0
                Button {
                    cfg.put("engine", e.0)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(e.0 == "local" ? L("Translation memory only") : L(e.1)).font(k.font(k.base, .bold)).foregroundColor(k.text)
                            Spacer()
                            Badge(e.0 == "local" ? L("Free") : L(e.2), on: on)
                        }
                        Muted(e.0 == "local" ? L("Only lines the translation memory and the reviewed translations know are shown. No account needed.") : L(e.3), small: true)
                            .multilineTextAlignment(.leading)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 12).fill(on ? k.accentSoft : k.panel))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(on ? k.accentUi : k.line, lineWidth: on ? 1.5 : 1))
                }
                .buttonStyle(.plain)
                .padding(.top, 8)
            }
            // the service's fields (the Arabic variety only for Arabic)
            ForEach(Self.fields[engine] ?? [], id: \.key) { f in
                if f.key != "dialect" || cfg.str("target_lang", "ar") == "ar" {
                    Field(label: L(f.label), help: f.help.map { L($0) }) {
                        if let o = f.options {
                            Select(options: o.map { ($0.0, L($0.1)) }, value: cfg.str(f.key, o[0].0)) { cfg.put(f.key, $0) }
                        } else {
                            KInput(value: cfg.str(f.key), secure: f.password, ltr: true) { cfg.put(f.key, $0.trimmingCharacters(in: .whitespaces)) }
                        }
                    }
                }
            }
            Muted(L("Keys are saved only on this phone, in the app's settings."), small: true).padding(.top, 10)
          Group {
            H3(L("Translation memory"))
            Muted(L("Remembers every translated line and reuses it instantly the next time it appears — no translator call, and no waiting for the line to settle."), small: true)
            Callout(memory.isEmpty ? "…" : memory).padding(.top, 8)
            KButton(L("Clear memory"), danger: true, full: false) { askClear = true }.padding(.top, 10)
          }
        }
        .onAppear(perform: stats)
        .onReceive(timer) { _ in stats() }
        .confirmationDialog(L("Forget all remembered translations?"), isPresented: $askClear, titleVisibility: .visible) {
            Button(L("Clear memory"), role: .destructive) {
                guard let core = m.core else { return }
                m.io.async {
                    core.engine.memoryClear()
                    DispatchQueue.main.async { stats() }
                }
            }
        }
    }

    @State private var askClear = false
    @State private var askShared = false

    /** the memory's numbers, every 2 s while shown (as the desktop) */
    private func stats() {
        guard let core = m.core else { return }
        m.io.async {
            let mem = Cfg.parse(core.engine.memoryStatsJson())
            let perf = Cfg.parse(core.engine.perfJson())
            let t = Self.memoryText(mem, perf)
            DispatchQueue.main.async { memory = t }
        }
    }

    static func memoryText(_ m: NSDictionary, _ p: NSDictionary) -> String {
        var lines = [L("{n} remembered line(s)", ("n", Int(Cfg.d(m, "entries"))))]
        let hits = Int(Cfg.d(m, "hits")), misses = Int(Cfg.d(m, "misses"))
        if hits + misses > 0 {
            lines.append(L("This session: {hits} from memory, {misses} translated ({rate}% hits)", ("hits", hits), ("misses", misses), ("rate", Int((100.0 * Double(hits) / Double(hits + misses)).rounded()))))
            lines.append(L("Translation ready after the English appeared: memory {a} · translator {b}",
                           ("a", hits > 0 ? "\(Int(Cfg.d(m, "avg_hit_ms").rounded())) ms" : "—"),
                           ("b", misses > 0 ? "\(Int(Cfg.d(m, "avg_miss_ms").rounded())) ms" : "—")))
        } else {
            lines.append(L("No lines seen yet this session."))
        }
        if let read = p["read"] as? NSDictionary {
            func ms(_ x: NSDictionary?) -> String { x.map { "\(Int(Cfg.d($0, "avg"))) ms" } ?? "—" }
            let ready = p["ready"] as? NSDictionary
            lines.append(L("Last minute: reading {read} per pass · translating {tr} · translation ready {ready} after the English (slowest {max})",
                           ("read", ms(read)), ("tr", ms(p["translate"] as? NSDictionary)), ("ready", ms(ready)),
                           ("max", ready.map { "\(Int(Cfg.d($0, "max"))) ms" } ?? "—")))
            lines.append(L("Running for {m} min", ("m", Int(Cfg.d(p, "minutes")))))
        }
        return lines.joined(separator: "\n")
    }

    struct EngineField {
        let key: String
        let label: String
        var password = false
        var help: String?
        var options: [(String, String)]?
    }

    /** the desktop's ENGINES: id, name, badge, description */
    static let engines: [(String, String, String, String)] = [
        ("local", "Local (offline)", "Free", "Runs on this PC. No account or internet after a one-time ~110 MB download per language. Basic, literal quality. Not every language has one."),
        ("deepl", "DeepL", "Free tier", "Very good quality. The free API plan includes 500,000 characters a month."),
        ("azure", "Microsoft Azure Translator", "Free tier", "Good quality. The free tier includes 2 million characters a month."),
        ("google", "Google Cloud Translation", "Free tier", "Good quality. Around 500,000 free characters a month."),
        ("libre", "LibreTranslate", "Free / self-hosted", "Open source. Use your own server or a hosted one."),
        ("claude", "Claude (Anthropic)", "≈ $1 per game", "Best with slang, jokes and context. Can use a dialect. Paid per use."),
        ("openai", "ChatGPT (OpenAI)", "≈ $1 per game", "Natural translations with context, like Claude. Can use a dialect. Paid per use."),
    ]

    private static let dialects = [("msa", "Modern Standard (الفصحى)"), ("egyptian", "Egyptian (مصري)"), ("gulf", "Gulf (خليجي)"), ("levantine", "Levantine (شامي)")]

    /** the desktop's ENGINE_FIELDS */
    static let fields: [String: [EngineField]] = [
        "deepl": [EngineField(key: "deepl_key", label: "DeepL API key", password: true, help: "Free keys end in :fx")],
        "azure": [EngineField(key: "azure_key", label: "Azure Translator key", password: true), EngineField(key: "azure_region", label: "Region (e.g. westeurope)", help: "Leave empty for a global resource")],
        "google": [EngineField(key: "google_key", label: "Google Cloud API key", password: true)],
        "libre": [EngineField(key: "libre_url", label: "Server URL"), EngineField(key: "libre_key", label: "API key (if the server needs one)", password: true)],
        "claude": [
            EngineField(key: "claude_key", label: "Anthropic API key", password: true),
            EngineField(key: "claude_model", label: "Model", options: [("claude-haiku-5-5", "Claude Haiku 5.5 — cheapest, fast"), ("claude-sonnet-5-5", "Claude Sonnet 5.5 — better"), ("claude-opus-5-5", "Claude Opus 5.5 — best, ~40× Haiku's price")]),
            EngineField(key: "dialect", label: "Arabic variety", options: dialects),
        ],
        "openai": [
            EngineField(key: "openai_key", label: "OpenAI API key", password: true),
            EngineField(key: "openai_model", label: "Model", options: [("gpt-6-luna", "GPT-6 Luna — cheapest, fast"), ("gpt-6.1-terra", "GPT-6.1 Terra — better"), ("gpt-6.2-sol", "GPT-6.2 Sol — best, ~20× Luna's price")]),
            EngineField(key: "dialect", label: "Arabic variety", options: dialects),
        ],
    ]

    static func engineName(_ id: String) -> String {
        id == "local" ? L("Translation memory only") : engines.first { $0.0 == id }.map { L($0.1) } ?? id
    }
}
