import SwiftUI
import UIKit

/**
 * The live translations full screen, to read them on the phone like a second screen (as the
 * Android app's LiveFull): the newest at the bottom in large text (the ones before it dimmer
 * above), upright or sideways. A bar on top: smaller / larger text (kept), the English line on or
 * off (kept), how it turns (with the phone, or held upright or sideways: kept), and close. The
 * screen stays on while it is open.
 */
struct LiveFull: View {
    @EnvironmentObject var m: AppModel
    @Environment(\.kit) var k
    @Environment(\.dismiss) var dismiss
    /** lines older than this were cleared from the Play tab's list */
    let clearedAt: UInt64
    @State private var size = Prefs.liveTextSize
    @State private var english = Prefs.liveEnglish
    @State private var rotation = Prefs.liveRotation

    static let minSize = 16.0, maxSize = 72.0, step = 4.0
    /** at most this many lines on screen (the newest) */
    static let maxLines = 30

    var body: some View {
        let rtl = m.core?.language(m.cfg.str("target_lang", "ar"))?.rtl ?? true
        let ls = Array(m.lines.filter { $0.id > clearedAt }.suffix(Self.maxLines))
        VStack(spacing: 0) {
            bar
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        if ls.isEmpty {
                            Text(L("Translations appear here as the game shows text."))
                                .font(k.font(k.base + 1)).foregroundColor(Kit.c(0x8f84a3))
                                .multilineTextAlignment(.center).padding(24)
                        }
                        ForEach(Array(ls.enumerated()), id: \.element.id) { i, l in
                            line(l, rtl: rtl, latest: i == ls.count - 1)
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .frame(maxWidth: .infinity, minHeight: 0, alignment: .bottom)
                }
                .defaultScrollAnchorBottom()
                .onChange(of: ls.last?.id) { _ in withAnimation { proxy.scrollTo("end", anchor: .bottom) } }
                .onChange(of: size) { _ in proxy.scrollTo("end", anchor: .bottom) }
                .onAppear { proxy.scrollTo("end", anchor: .bottom) }
            }
        }
        .background(Color.black.ignoresSafeArea())
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            Orientation.set(rotation)
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = m.state.running
            Orientation.set("auto")
        }
    }

    private func line(_ l: RecentLine, rtl: Bool, latest: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if english && !l.en.trimmingCharacters(in: .whitespaces).isEmpty {
                Text(l.en).font(.system(size: max(size * 0.5, 13))).foregroundColor(Kit.c(0x9a90ad))
                    .frame(maxWidth: .infinity, alignment: rtl ? .trailing : .leading)
                    .environment(\.layoutDirection, .leftToRight)
            }
            Text(l.text.isEmpty ? "…" : l.text)
                .font(rtl ? .custom("Tajawal-Bold", fixedSize: size) : .system(size: size, weight: .bold))
                .foregroundColor(.white)
                .lineSpacing(size * 0.2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .environment(\.layoutDirection, rtl ? .rightToLeft : .leftToRight)
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .opacity(latest ? 1 : 0.55)
    }

    private var bar: some View {
        HStack(spacing: 8) {
            pill("A−", L("Smaller text")) { resize(-Self.step) }
            Text("\(Int(size))").font(.system(size: k.base - 2, weight: .bold)).foregroundColor(Kit.c(0xbdb3cc)).frame(minWidth: 36)
            pill("A+", L("Larger text")) { resize(Self.step) }
            pill("EN", L("Show the English"), on: english) {
                english.toggle()
                Prefs.liveEnglish = english
            }
            pill("⟳  " + rotationLabel, rotationLabel) {
                rotation = rotation == "auto" ? "portrait" : rotation == "portrait" ? "landscape" : "auto"
                Prefs.liveRotation = rotation
                Orientation.set(rotation)
            }
            Spacer(minLength: 0)
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 18, weight: .bold)).foregroundColor(.white)
                    .frame(width: 44, height: 44).background(Circle().fill(Color.white.opacity(0.2)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L("Close"))
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(Color.black.opacity(0.8))
        .environment(\.layoutDirection, .leftToRight)
    }

    private var rotationLabel: String {
        switch rotation {
        case "portrait": return L("Portrait")
        case "landscape": return L("Landscape")
        default: return L("Auto-rotate")
        }
    }

    private func resize(_ by: Double) {
        size = min(max(size + by, Self.minSize), Self.maxSize)
        Prefs.liveTextSize = size
    }

    private func pill(_ s: String, _ label: String, on: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(s).font(.system(size: k.base, weight: .bold)).foregroundColor(.white)
                .padding(.horizontal, 14).frame(minWidth: 44, minHeight: 44)
                .background(Capsule().fill(on ? AnyShapeStyle(Kit.sunset) : AnyShapeStyle(Color.white.opacity(0.2))))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

private extension View {
    /** (iOS 17: the list starts at its bottom; before, it is scrolled there on appearing) */
    @ViewBuilder func defaultScrollAnchorBottom() -> some View {
        if #available(iOS 17.0, *) { self.defaultScrollAnchor(.bottom) } else { self }
    }
}

/** How the app may turn: with the phone ("auto"), or held upright ("portrait") or sideways ("landscape"). */
enum Orientation {
    static var mask: UIInterfaceOrientationMask = .all

    static func set(_ how: String) {
        switch how {
        case "portrait": mask = .portrait
        case "landscape": mask = .landscape
        default: mask = UIDevice.current.userInterfaceIdiom == .pad ? .all : .allButUpsideDown
        }
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
        scene.windows.first?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
    }
}

/** (the app's delegate: only for the orientations the live translations full screen asks for) */
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        Orientation.mask
    }
}
