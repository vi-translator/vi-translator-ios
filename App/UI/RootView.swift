import SwiftUI

/**
 * The app, laid out as the desktop app for a phone (as the Android app): the header (who we are,
 * Setup / Play, what's happening, the quick switches, the app's language and light / dark), then
 * either Play (the picture, what is running, the live translations) or Setup (the desktop's tabs).
 * On an iPad (a wide window) Setup's tabs are a rail at the side and Play is two columns.
 */
struct RootView: View {
    @EnvironmentObject var m: AppModel
    @Environment(\.kit) var k
    @Environment(\.horizontalSizeClass) var size
    @State private var pickingLanguage = false

    var body: some View {
        VStack(spacing: 0) {
            if m.loaded {
                header
                content
            } else {
                Spacer()
                ProgressView().tint(k.accentUi)
                Spacer()
            }
        }
        .background(k.bg.ignoresSafeArea())
        .sheet(item: $m.xbox) { mode in
            XboxPlayerView(mode: mode).environmentObject(m).environment(\.kit, k)
        }
        .sheet(isPresented: Binding(get: { m.askPin != nil }, set: { if !$0 { m.askPin = nil } })) {
            PinSheet(incorrect: m.askPin ?? false).environmentObject(m).environment(\.kit, k)
        }
        .confirmationDialog(L("App language"), isPresented: $pickingLanguage) {
            ForEach(I18n.langs, id: \.code) { l in
                Button(l.name) { m.setLanguage(l.code) }
            }
        }
    }

    // ---- the header

    private var header: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Image("Logo").resizable().frame(width: 36, height: 36).clipShape(RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 0) {
                    Text("VI Translator").font(k.font(k.base + 1.5, .heavy)).foregroundColor(k.text)
                    Text("v" + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""))
                        .font(k.font(k.base - 2.5, .bold)).foregroundColor(k.muted)
                        .environment(\.layoutDirection, .leftToRight)
                }
                Spacer()
                Text(m.savedLabel).font(k.font(k.base - 2.5)).foregroundColor(k.muted)
                iconButton(Icon.globe, L("App language")) { pickingLanguage = true }
                iconButton(m.dark ? Icon.sun : Icon.moon, L("Switch between light and dark")) { m.toggleTheme() }
            }
            HStack(spacing: 10) {
                HStack(spacing: 4) {
                    modeButton("setup", L("Setup"), Icon.setup)
                    modeButton("play", L("Play"), Icon.play)
                }
                .padding(4)
                .background(Capsule().fill(k.panel2))
                HStack(spacing: 7) {
                    Circle().fill(statusColor).frame(width: 7, height: 7)
                    Text(m.statusText).font(k.font(k.base - 1, .bold)).foregroundColor(m.state == .failed ? k.err : k.text).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
                .background(Capsule().fill(k.panel2))
                .overlay(Capsule().stroke(k.line, lineWidth: 1))
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    chip(L("Overlays"), m.cfg.bool("overlays_enabled", true)) { m.cfg.put("overlays_enabled", $0) }
                    chip(L("Live translations"), m.cfg.bool("live_translations", true)) { m.cfg.put("live_translations", $0) }
                    chip(L("Preview"), Prefs.preview) { m.setPreview($0) }
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(k.panel.ignoresSafeArea(edges: .top))
        .overlay(alignment: .bottom) {
            // a thin sunset line under the header, like the logo's horizon
            Rectangle().fill(Kit.sunset).frame(height: 2).opacity(0.85)
        }
    }

    private var statusColor: Color {
        switch m.state {
        case .idle, .ended: return k.muted
        case .starting, .connecting: return k.warn
        case .reading: return k.ok
        case .failed: return k.err
        }
    }

    private func iconButton(_ icon: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 17, weight: .semibold)).foregroundColor(k.text)
                .frame(width: 40, height: 40)
                .background(Circle().fill(k.panel2))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func modeButton(_ id: String, _ label: String, _ icon: String) -> some View {
        let on = m.mode == id
        return Button {
            m.setMode(id)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 13, weight: .bold))
                Text(label).font(k.font(k.base, .bold)).lineLimit(1)
            }
            .fixedSize()
            .foregroundColor(on ? .white : k.muted)
            .padding(.horizontal, 16).frame(minHeight: 40)
            .background(Capsule().fill(on ? AnyShapeStyle(Kit.sunset) : AnyShapeStyle(Color.clear)))
        }
        .buttonStyle(.plain)
    }

    private func chip(_ label: String, _ on: Bool, _ changed: @escaping (Bool) -> Void) -> some View {
        Toggle(isOn: Binding(get: { on }, set: { changed($0) })) {
            Text(label).font(k.font(k.base - 1.5, .bold)).foregroundColor(k.text)
        }
        .toggleStyle(.switch)
        .tint(k.accentUi)
        .controlSize(.mini)
        .fixedSize()
        .padding(.leading, 14).padding(.trailing, 9).padding(.vertical, 4)
        .background(Capsule().fill(k.panel2))
        .overlay(Capsule().stroke(k.line, lineWidth: 1))
    }

    // ---- Play or Setup

    @ViewBuilder private var content: some View {
        if m.mode == "play" {
            PlayPanel()
        } else if size == .regular {
            HStack(spacing: 0) {
                ScrollView { VStack(spacing: 4) { tabButtons(vertical: true) }.padding(10) }
                    .frame(width: 210)
                    .background(k.panel)
                Rectangle().fill(k.line).frame(width: 1)
                panel.frame(maxWidth: .infinity)
            }
        } else {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) { tabButtons(vertical: false) }.padding(.horizontal, 10).padding(.vertical, 8)
                    }
                    .background(k.panel)
                    .onAppear { proxy.scrollTo(m.tab, anchor: .center) }
                }
                Rectangle().fill(k.line).frame(height: 1)
                panel
            }
        }
    }

    /** The desktop's rail: Source, Show on, Snapshot, Translator, then the profile and its parts. */
    static let tabs: [(String, String, String)] = [
        ("source", "Source", Icon.source),
        ("show", "Show on", Icon.show),
        ("snapshot", "Snapshot", Icon.snapshot),
        ("translator", "Translator", Icon.translator),
        ("profile", "Game profile", Icon.profile),
        ("areas", "Read areas", Icon.areas),
        ("pages", "Game pages", Icon.pages),
    ]

    @ViewBuilder private func tabButtons(vertical: Bool) -> some View {
        ForEach(Self.tabs, id: \.0) { (id, label, icon) in
            let on = id == m.tab
            Button {
                m.tab = id
            } label: {
                Group {
                    if vertical {
                        HStack(spacing: 10) {
                            Image(systemName: icon).font(.system(size: 17, weight: .semibold)).frame(width: 24)
                            Text(L(label)).font(k.font(k.base - 0.5, .bold))
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 11)
                    } else {
                        VStack(spacing: 4) {
                            Image(systemName: icon).font(.system(size: 19, weight: .semibold))
                            Text(L(label)).font(k.font(k.base - 2, .bold)).lineLimit(1)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 9)
                        .frame(minWidth: 72)
                    }
                }
                .foregroundColor(on ? k.accentUi : k.muted)
                .background(RoundedRectangle(cornerRadius: 10).fill(on ? k.accentSoft : Color.clear))
            }
            .buttonStyle(.plain)
            .id(id)
        }
    }

    @ViewBuilder private var panel: some View {
        ScrollView {
            Group {
                switch m.tab {
                case "show": ShowPanel()
                case "snapshot": SnapshotPanel()
                case "translator": TranslatorPanel()
                case "profile": ProfilePanel()
                case "areas": AreasPanel()
                case "pages": PagesPanel()
                default: SourcePanel()
                }
            }
            .frame(maxWidth: 760)
            .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 40)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .id(m.tab)
    }
}

/** The PS5 asks for the account's passcode. */
struct PinSheet: View {
    @EnvironmentObject var m: AppModel
    @Environment(\.kit) var k
    let incorrect: Bool
    @State private var pin = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L(incorrect ? "Wrong passcode: try again" : "The PS5 asks for the account's passcode")).font(k.font(k.base + 0.5, .bold)).foregroundColor(k.text)
            KInput(value: pin, placeholder: L("Passcode"), secure: true, ltr: true, number: true) { pin = $0 }
            KButton(L("OK"), primary: true) { m.pin(pin) }
            Spacer()
        }
        .sheetCard(k)
        .presentationDetents([.medium])
    }
}

/** A panel's lock note, with "Make a copy" (the desktop's .lock-note). */
struct LockNote: View {
    @EnvironmentObject var m: AppModel
    @Environment(\.kit) var k

    var body: some View {
        if m.cfg.locked(), let p = m.cfg.activeProfile() {
            HStack(spacing: 10) {
                Image(systemName: Icon.lock).foregroundColor(k.accentUi)
                Text(L("“{name}” is built in and can't be changed.", ("name", Cfg.s(p, "name")))).font(k.font(k.base - 1, .bold)).foregroundColor(k.text)
                Spacer(minLength: 0)
                KButton(L("Make a copy"), primary: true, full: false) { m.cfg.copyProfile(p) }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 12).fill(k.accentSoft))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(k.accentUi, lineWidth: 1))
            .padding(.top, 12)
        }
    }
}
