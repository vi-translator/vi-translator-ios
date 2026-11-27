import SwiftUI
import WebKit

/**
 * Play, as on the desktop and the Android app: start (the phone connects to the console), the
 * picture with the read areas and their translations, what is running at a glance (picture source,
 * language, read areas, each with Change), and the live translations.
 */
struct PlayPanel: View {
    @EnvironmentObject var m: AppModel
    @Environment(\.kit) var k
    @Environment(\.horizontalSizeClass) var size
    /** lines older than this were cleared from the list (clear) */
    @State private var clearedAt: UInt64 = 0
    @State private var full = false
    /** the live translations full screen */
    @State private var liveFull = false
    @State private var snap: SnapResult?
    @State private var snapError: String?

    var body: some View {
        ScrollView {
            Group {
                if size == .regular {
                    HStack(alignment: .top, spacing: 16) {
                        VStack(spacing: 12) {
                            startCard
                            Stage(feed: m.picture, full: $full, snapshot: takeSnapshot)
                        }
                        .frame(maxWidth: .infinity)
                        VStack(spacing: 0) {
                            glance
                            live.padding(.top, 12)
                        }
                        .frame(width: 380)
                    }
                } else {
                    VStack(spacing: 0) {
                        startCard
                        Stage(feed: m.picture, full: $full, snapshot: takeSnapshot).padding(.top, 12)
                        glance.padding(.top, 4)
                        live.padding(.top, 12)
                    }
                }
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 40)
        }
        .fullScreenCover(isPresented: $liveFull) {
            LiveFull(clearedAt: clearedAt).environmentObject(m).environment(\.kit, k)
        }
        .fullScreenCover(isPresented: $full) {
            FullPicture(feed: m.picture).environmentObject(m).environment(\.kit, k)
        }
        .sheet(item: $snap) { s in
            SnapView(snap: s).environment(\.kit, k)
        }
        .alert(snapError ?? "", isPresented: Binding(get: { snapError != nil }, set: { if !$0 { snapError = nil } })) {
            Button(L("OK")) { snapError = nil }
        }
    }

    // ---- start / stop (the phone connects to the console; the desktop reads a window)

    private var startCard: some View {
        Card {
            let running = m.state.running
            Button {
                if running { m.stop() } else { m.start() }
            } label: {
                HStack(spacing: 8) {
                    if !running { Image(systemName: Icon.play) }
                    Text(running ? L("Stop") : L("Start translating")).font(k.font(k.base + 1, .bold))
                }
                .foregroundColor(running ? k.text : .white)
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(RoundedRectangle(cornerRadius: 9).fill(running ? AnyShapeStyle(k.panel2) : AnyShapeStyle(Kit.sunset)))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(running ? k.line : .clear, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("start")
            Muted(startNote, small: true).padding(.top, 6)
            if m.tvLost {
                Callout(L("The TV stopped getting translations while VI Translator was in the background.") + " "
                    + L("Keep VI Translator open on this phone while playing: the TV gets the translations from it, and iOS pauses apps in the background."), k.warn)
                    .padding(.top, 8)
                Muted(L("You don't need the PS Remote Play app: VI Translator connects to the PS5 itself (the PS5 streams to one app at a time). On an iPad, Split View keeps another app beside it. With a PS5, “Keep translating with the screen off” (Source) lets it go on in the background."), small: true)
                    .padding(.top, 6)
                KLink(L("OK")) { m.tvLost = false }
            } else if m.tvCount > 0 {
                Muted(L("Keep VI Translator open on this phone while playing: the TV gets the translations from it, and iOS pauses apps in the background."), small: true)
                    .padding(.top, 4)
            }
            SoundLine(feed: m.picture)
        }
    }

    private var startNote: String {
        switch Prefs.console {
        case "xbox": return L("Xbox: Microsoft's Remote Play player opens; keep the phone's screen on while playing.")
        case "ps5": return L("Keep VI Translator open on the screen while playing: iOS pauses apps in the background.")
        case "capture": return L("Keep VI Translator open on the screen while playing: iPadOS stops the capture card for apps in the background.")
        default: return L("Choose your console in Source first.")
        }
    }

    // ---- what is running, at a glance (the desktop's .glance cards)

    private var glance: some View {
        let console = Prefs.console
        let ps = Ps5.saved
        let source: String
        switch console {
        case "ps5": source = ps.map { "PlayStation 5 · \($0.nickname.isEmpty ? $0.host : $0.nickname)" } ?? L("PlayStation 5 (not linked yet)")
        case "xbox": source = "Xbox"
        case "capture": source = L("Capture card") + (CaptureCard.chosen().map { " · \($0.name)" } ?? "")
        default: source = L("Not chosen yet")
        }
        let sourceNote = console == "ps5" && !Ps5.available ? L("PS Remote Play isn't in this build of the app.") : (m.state == .reading ? L("Reading the game") : "")
        let langCode = m.cfg.str("target_lang", "ar")
        let lang = m.core?.language(langCode)
        let engine = TranslatorPanel.engineName(m.cfg.str("engine", "local"))
        let names = m.cfg.areaList().filter { Cfg.b($0, "enabled", true) }.map { Cfg.s($0, "name") }.joined(separator: ", ")
        return VStack(spacing: 10) {
            glanceCard(Icon.source, L("Picture source"), source, sourceNote) { m.go("source") }
            glanceCard(Icon.translator, L("Language"), lang.map { $0.native.isEmpty ? $0.name : $0.native } ?? langCode, engine) { m.go("translator") }
            glanceCard(Icon.areas, L("Read areas"), names.isEmpty ? "—" : names, m.cfg.activeProfile().map { Cfg.s($0, "name") } ?? "") { m.go("areas") }
        }
        .padding(.top, 10)
    }

    private func glanceCard(_ icon: String, _ key: String, _ value: String, _ note: String, change: @escaping () -> Void) -> some View {
        Button(action: change) {
            HStack(spacing: 12) {
                IconTile(name: icon)
                VStack(alignment: .leading, spacing: 2) {
                    LabelText(key)
                    Text(value).font(k.font(k.base, .bold)).foregroundColor(k.text).lineLimit(2).multilineTextAlignment(.leading)
                    if !note.isEmpty { Muted(note, small: true) }
                }
                Spacer(minLength: 0)
                Text(L("Change")).font(k.font(k.base - 1, .bold)).foregroundColor(k.accentUi)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 14).fill(k.panel))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(k.line, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // ---- the live translations: newest first, the English small above its translation

    private var live: some View {
        let rtl = m.core?.language(m.cfg.str("target_lang", "ar"))?.rtl ?? true
        let ls = m.lines.filter { $0.id > clearedAt }.reversed().prefix(30)
        return Card {
            HStack(spacing: 8) {
                Circle().fill(k.neon).frame(width: 7, height: 7)
                LabelText(L("Live translations"))
                if !m.cfg.bool("live_translations", true) { Badge(L("Paused")) }
                Spacer()
                KLink(L("clear")) { clearedAt = m.lines.last?.id ?? 0 }
                Button { liveFull = true } label: {
                    Image(systemName: Icon.fullscreen).font(.system(size: 15, weight: .semibold)).foregroundColor(k.text)
                        .frame(width: 40, height: 40).background(Circle().fill(k.panel2))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("Live translations full screen"))
            }
            if ls.isEmpty {
                Muted(L("Translations appear here as the game shows text."), small: true)
                    .multilineTextAlignment(.center)
                    .padding(.vertical, 14)
            } else {
                ForEach(Array(ls), id: \.id) { l in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(l.en).font(k.font(k.base - 1)).foregroundColor(k.muted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .environment(\.layoutDirection, .leftToRight)
                        Text(l.text.isEmpty ? "…" : l.text)
                            .font(rtl ? .custom("Tajawal-Bold", fixedSize: k.base + 3) : k.font(k.base + 2.5, .bold))
                            .foregroundColor(k.text)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight)
                    }
                    .padding(.vertical, 8)
                    Divider().background(k.line)
                }
            }
        }
    }

    private func takeSnapshot() {
        Snaps.take(m) { r in
            switch r {
            case let .success(s): snap = s
            case let .failure(e): snapError = L("Could not translate the picture: {e}", ("e", e.localizedDescription))
            }
        }
    }
}

/**
 * The picture: the game (the reader's preview copy), the read areas, and the translations over it
 * as the TVs draw them (the core's own TV page, loaded from this phone, transparent; touches go
 * through to the picture).
 */
struct Stage: View {
    @EnvironmentObject var m: AppModel
    @ObservedObject var feed: PictureFeed
    @Environment(\.kit) var k
    @Binding var full: Bool
    let snapshot: () -> Void
    @State private var overlayUrl: URL?

    var body: some View {
        ZStack(alignment: .topLeading) {
            PreviewRepresentable(image: feed.image, lines: m.lines, drawText: overlayUrl == nil, showAreas: false, rev: m.rev)
                .aspectRatio(16 / 9, contentMode: .fit)
            if let u = overlayUrl {
                TvPageView(url: u).allowsHitTesting(false)
            }
            message
            if !feed.stats.isEmpty && m.cfg.bool("fps_badge") {
                Text(feed.stats).font(k.font(k.base - 2, .bold)).foregroundColor(.white).shadow(color: .black, radius: 2)
                    .padding(8)
            }
            VStack {
                Spacer()
                HStack(spacing: 8) {
                    Spacer()
                    stageButton(Icon.camera, L("Translate the whole picture"), snapshot)
                    stageButton(Icon.fullscreen, L("Full screen")) { full = true }
                }
            }
            .padding(10)
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .background(k.stage)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(k.line, lineWidth: 1))
        .onAppear {
            m.wirePreview()
            guard overlayUrl == nil, let core = m.core else { return }
            m.io.async {
                let u = core.engine.localViewerUrl().flatMap(URL.init(string:))
                DispatchQueue.main.async { overlayUrl = u }
            }
        }
    }

    @ViewBuilder private var message: some View {
        if !Prefs.preview {
            VStack(spacing: 6) {
                Image(systemName: Icon.eyeOff).font(.system(size: 26)).foregroundColor(k.muted)
                Text(L("Preview is off")).font(k.font(k.base + 1, .bold)).foregroundColor(.white)
                Text(L("Translations keep working. Turn it on to see the game here.")).font(k.font(k.base - 1.5)).foregroundColor(Kit.c(0xa193b5)).multilineTextAlignment(.center)
                KButton(L("Turn on preview"), full: false) { m.setPreview(true) }
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(k.stage)
        } else if feed.image == nil {
            VStack(spacing: 4) {
                Text(L("No picture yet")).font(k.font(k.base + 1, .bold)).foregroundColor(.white)
                Text(m.state.running ? L("Waiting for the console's picture…") : L("Press Start translating: the picture shows here once the console is connected."))
                    .font(k.font(k.base - 1.5)).foregroundColor(Kit.c(0xa193b5)).multilineTextAlignment(.center)
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func stageButton(_ icon: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 16, weight: .semibold)).foregroundColor(.white)
                .frame(width: 40, height: 40)
                .background(Circle().fill(Color.black.opacity(0.55)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/** The game's sound on the phone, while the screen-off option plays it. */
struct SoundLine: View {
    @ObservedObject var feed: PictureFeed

    var body: some View {
        if !feed.sound.isEmpty { Muted(feed.sound, small: true).padding(.top, 4) }
    }
}

/** The picture full screen, sideways (the desktop's full-screen preview); a tap closes it. */
struct FullPicture: View {
    @EnvironmentObject var m: AppModel
    @ObservedObject var feed: PictureFeed
    @Environment(\.dismiss) var dismiss
    @State private var overlayUrl: URL?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            ZStack {
                // (the translations drawn by the core's TV page, as on the small picture and the TVs:
                // each goes when the game's English goes)
                PreviewRepresentable(image: feed.image, lines: m.lines, drawText: false, showAreas: false, rev: m.rev)
                if let u = overlayUrl { TvPageView(url: u).allowsHitTesting(false) }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
        }
        .onTapGesture { dismiss() }
        .statusBarHidden()
        .onAppear {
            guard overlayUrl == nil, let core = m.core else { return }
            m.io.async {
                let u = core.engine.localViewerUrl().flatMap(URL.init(string:))
                DispatchQueue.main.async { overlayUrl = u }
            }
        }
    }
}

/** The core's TV page (its overlays) over the picture: transparent, and not touchable. */
struct TvPageView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let w = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        w.isOpaque = false
        w.backgroundColor = .clear
        w.scrollView.backgroundColor = .clear
        w.scrollView.isScrollEnabled = false
        w.isUserInteractionEnabled = false
        w.load(URLRequest(url: url))
        return w
    }

    func updateUIView(_ w: WKWebView, context: Context) {
        if w.url == nil { w.load(URLRequest(url: url)) }
    }
}
