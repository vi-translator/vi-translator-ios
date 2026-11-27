import AVFoundation
import SwiftUI

/**
 * Source: where the picture comes from, as in the Android app. The desktop picks a window, a capture
 * card or OBS; the phone reads the console itself: a PS5 (PS Remote Play, set up once: sign in to PSN
 * for the account ID, find it, the PIN it shows) or an Xbox (the app's own Remote Play client, signed in
 * with a code, the console chosen once; or Microsoft's web player: XboxLinkView); an iPad with
 * USB-C also reads a capture card (CaptureCard). Then Timing.
 */
struct SourcePanel: View {
    @EnvironmentObject var m: AppModel
    @Environment(\.kit) var k
    @State private var console = Prefs.console
    @State private var cards: [CaptureCard.Card] = []
    @State private var cardId = Prefs.captureCard
    @State private var camera = AVCaptureDevice.authorizationStatus(for: .video)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            H3(L("Picture source"))
            Muted(L("The phone reads the game from your console over the home network; the TV keeps showing the console as usual. Only the translations go to the TV."))
            consoleChoice("ps5", "PlayStation 5", L("PS Remote Play: the phone streams the PS5's picture to read it (no sound). Keep the phone on VI Translator while playing."))
                .padding(.top, 10)
            consoleChoice("xbox", "Xbox", Prefs.xboxWebPlayer ? L("Microsoft's Remote Play player, in the app. Keep the phone's screen on while playing.")
                : L("Xbox Remote Play: the phone streams the Xbox's picture to read it (no sound). Keep the phone on VI Translator while playing."))
                .padding(.top, 8)
            if CaptureCard.supported {
                consoleChoice("capture", L("Capture card"), L("A USB capture card in the iPad's USB-C port, with the console's HDMI in it. Use a card with HDMI out (pass-through) so the TV keeps showing the game."))
                    .padding(.top, 8)
            } else {
                Muted(L("Capture cards work on an iPad with USB-C (iPadOS 17 or newer)."), small: true).padding(.top, 8)
            }
            if console == "ps5" { Ps5LinkView() }
            if console == "xbox" { XboxLinkView() }
            if console == "capture" && CaptureCard.supported { captureSetup }
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
                    Image(systemName: id == "ps5" ? Icon.source : id == "capture" ? Icon.capture : Icon.tv).foregroundColor(on ? k.accentUi : k.muted)
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
     * The capture card: the cards connected now (followed as they are plugged in and out), which one
     * is read, and the camera permission iPadOS asks for once (a capture card is an external camera
     * to it).
     */
    private var captureSetup: some View {
        let chosen = cards.first { $0.id == cardId } ?? cards.first
        return VStack(alignment: .leading, spacing: 4) {
            if cards.isEmpty {
                Callout(L("No capture card found: plug it into the iPad's USB-C port.")).padding(.top, 12)
            } else {
                LabelText(L("Capture card")).padding(.top, 14)
                ForEach(cards, id: \.id) { c in
                    Button {
                        Prefs.captureCard = c.id
                        cardId = c.id
                        m.rev += 1
                    } label: {
                        HStack {
                            Text(c.name).font(k.font(k.base)).foregroundColor(k.text)
                            Spacer()
                            Image(systemName: Icon.check).foregroundColor(c == chosen ? k.accentUi : .clear)
                        }
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)
                }
            }
            if camera == .denied || camera == .restricted {
                Callout(CaptureCard.noPermission).padding(.top, 12)
                KButton(L("Open Settings"), icon: Icon.setup) {
                    if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) }
                }.padding(.top, 8)
            }
            LabelText(L("Connecting it")).padding(.top, 14)
            Muted("1. " + L("The console's HDMI into the card's HDMI in; the card's HDMI out into the TV."))
            Muted("2. " + L("The card's USB into the iPad's USB-C port (a USB-A card through a USB-C adapter or hub). A card that needs its own driver doesn't work: it must be a UVC (plug-and-play) card."))
            Muted("3. " + L("Play › Start translating: iPadOS asks once to let VI Translator use the card (as a camera)."))
            Callout(L("On the PS5, turn off HDCP (Settings › System › HDMI), or the card gets no picture.")).padding(.top, 12)
        }
        .onAppear(perform: refreshCards)
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureDevice.wasConnectedNotification)) { _ in refreshCards() }
        .onReceive(NotificationCenter.default.publisher(for: AVCaptureDevice.wasDisconnectedNotification)) { _ in refreshCards() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in refreshCards() }
    }

    private func refreshCards() {
        // (the notifications come on any thread)
        DispatchQueue.main.async {
            cards = CaptureCard.cards()
            camera = AVCaptureDevice.authorizationStatus(for: .video)
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
