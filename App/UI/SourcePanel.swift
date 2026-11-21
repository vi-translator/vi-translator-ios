import SwiftUI

/**
 * Source: where the picture comes from, as in the Android app. The desktop picks a window, a capture
 * card or OBS; the phone reads the console itself: a PS5 (PS Remote Play, set up once: sign in to PSN
 * for the account ID, find it, the PIN it shows) or an Xbox (Microsoft's web player). Then Timing.
 */
struct SourcePanel: View {
    @EnvironmentObject var m: AppModel
    @Environment(\.kit) var k
    @State private var console = Prefs.console
    @State private var xboxSigned: Bool?
    @State private var askSignOut = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            H3(L("Picture source"))
            Muted(L("The phone reads the game from your console over the home network; the TV keeps showing the console as usual. Only the translations go to the TV."))
            consoleChoice("ps5", "PlayStation 5", L("PS Remote Play: the phone streams the PS5's picture to read it (no sound). Keep the phone on VI Translator while playing."))
                .padding(.top, 10)
            consoleChoice("xbox", "Xbox", L("Microsoft's Remote Play player, in the app. Keep the phone's screen on while playing."))
                .padding(.top, 8)
            if console == "ps5" { Ps5LinkView() }
            if console == "xbox" { xboxSetup }
            H3(L("Timing"))
            TimingForm()
        }
    }

    private func consoleChoice(_ id: String, _ name: String, _ about: String) -> some View {
        let on = console == id
        return Button {
            Prefs.console = id
            console = id
            m.rev += 1
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    Image(systemName: id == "ps5" ? Icon.source : Icon.tv).foregroundColor(on ? k.accentUi : k.muted)
                    Text(name).font(k.font(k.base + 0.5, .bold)).foregroundColor(k.text)
                    Spacer()
                    Image(systemName: Icon.check).foregroundColor(on ? k.accentUi : .clear)
                }
                Muted(about, small: true).multilineTextAlignment(.leading)
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 14).fill(on ? k.accentSoft : k.panel))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(on ? k.accentUi : k.line, lineWidth: on ? 1.5 : 1))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("console-\(id)")
    }

    /**
     * The Xbox: nothing to link in the app. Microsoft's player (in the app) signs in with the
     * Microsoft account and connects to the console itself; the console only needs its remote
     * features on. Signing in here first makes Start go straight to the game.
     */
    private var xboxSetup: some View {
        let signed = xboxSigned ?? false
        return VStack(alignment: .leading, spacing: 4) {
            Callout(signed ? L("Signed in to Microsoft in the Xbox player.") : L("Not signed in to the Xbox player yet."), signed ? k.ok : nil)
                .padding(.top, 12)
            LabelText(L("On the Xbox, once")).padding(.top, 14)
            Muted("1. " + L("Settings › Devices & connections › Remote features: turn on Enable remote features."))
            Muted("2. " + L("Settings › General › Power options: choose Sleep, so the player can wake the console."))
            Muted("3. " + L("Sign in on the Xbox with the same Microsoft account as in the player."))
            LabelText(L("In the app")).padding(.top, 14)
            Muted(L("Open the player, sign in with your Microsoft account and choose your Xbox under Remote play. The sign-in stays in the app: next time, Start translating goes straight to the game."))
            KButton(L("Open the Xbox player"), icon: Icon.tv, primary: true) { m.xbox = .setup }.padding(.top, 12)
            if signed { KLink(L("Sign out of Microsoft")) { askSignOut = true } }
            Callout(L("While translating, the app copies the player's picture to read it. If the copies come out black, the player offers to record the screen instead (iOS asks you to allow it).")).padding(.top, 12)
        }
        .task(id: m.xbox == nil) { xboxSigned = await XboxPlayer.signedIn() }
        .confirmationDialog(L("Sign out of Microsoft in the Xbox player?"), isPresented: $askSignOut, titleVisibility: .visible) {
            Button(L("Sign out"), role: .destructive) {
                Task {
                    await XboxPlayer.signOut()
                    xboxSigned = await XboxPlayer.signedIn()
                }
            }
        }
    }
}

/** The desktop's Timing form: what is read how often, and how long text must settle. */
struct TimingForm: View {
    @EnvironmentObject var m: AppModel

    private static let fields: [(String, String, Double, Double, Double, String)] = [
        ("capture_fps", "Frames captured for reading text (per second)", 1, 30, 1, "Full-size frames used for reading text, game pages and saved frames. Also how often the pause menu checks whether its text changed. 12 is plenty; more costs CPU, especially at 4K. From OBS, about 12 is the most it can deliver."),
        ("interval_ms", "How often areas are read (ms)", 100, 1000, 50, "Lower = faster reaction, more CPU."),
        ("stable_ms", "Wait for text to settle before translating (ms)", 0, 1500, 50, "Avoids translating half-faded lines."),
        ("clear_after_ms", "Treat the English as gone after (ms)", 200, 3000, 100, "Ignores short OCR blinks. The translation then stays as long as the English was on screen, and switches to the next line as soon as it is ready."),
    ]
    // the last three: the game profile's timing unless the player chose their own (as the desktop)
    private static let timed = ["interval_ms", "stable_ms", "clear_after_ms"]

    var body: some View {
        let cfg = m.cfg
        let game = cfg.activeProfile()?["timing"] as? NSDictionary ?? NSDictionary()
        let gameHas = Self.timed.contains { Cfg.d(game, $0) > 0 }
        func inUse(_ key: String) -> Double {
            cfg.bool("timing_custom") || Cfg.d(game, key) <= 0 ? cfg.num(key) : Cfg.d(game, key)
        }
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Self.fields, id: \.0) { f in
                let v = Self.timed.contains(f.0) ? inUse(f.0) : cfg.num(f.0, 12)
                Field(label: L(f.1), help: L(f.5)) {
                    KSlider(range: f.2...f.3, step: f.4, value: v, format: { String(Int($0)) }) { x in
                        if Self.timed.contains(f.0) && !cfg.bool("timing_custom") {
                            for t in Self.timed { cfg.c[t] = inUse(t) }
                            cfg.put("timing_custom", true)
                            for t in Self.timed { cfg.touched(t) }
                        }
                        cfg.put(f.0, Int(x))
                    }
                }
            }
            if gameHas && cfg.bool("timing_custom") {
                KButton(L("Use the game's timing")) { cfg.put("timing_custom", false) }.padding(.top, 12)
            }
        }
    }
}
