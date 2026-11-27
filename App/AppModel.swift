import Foundation
import SwiftUI
import UIKit

/** What is happening (the Android app's Live). */
enum LiveState: Equatable {
    case idle, starting, connecting, reading, ended, failed

    var running: Bool { self == .starting || self == .connecting || self == .reading }
}

/** The live picture and its numbers, apart from the rest (it changes a few times a second). */
final class PictureFeed: ObservableObject {
    @Published var image: UIImage?
    @Published var stats = ""
    /** the game's sound on the phone (screen-off option), for the Play tab */
    @Published var sound = ""
}

/**
 * The app's state, for every screen, and translating itself (the Android app's App, Live and
 * TranslateService): the core, the settings, the console's stream, the reader, the TVs.
 *
 * iOS pauses an app soon after it leaves the screen, and the PS5's stream with it: while
 * translating, the phone stays on VI Translator (the screen doesn't lock), and when it comes back
 * from the background translating starts again by itself.
 */
final class AppModel: ObservableObject {
    static let shared = AppModel()

    let core: CoreHost?
    let coreError: String?
    let cfg: Cfg
    let picture = PictureFeed()

    @Published var loaded = false
    /** bumped when the settings change (the screens read them from cfg) */
    @Published var rev = 0
    @Published var mode: String
    @Published var tab: String
    @Published var state: LiveState = .idle
    @Published var detail: String?
    @Published var coreStatus: String?
    @Published var lines: [RecentLine] = []
    @Published var savedLabel = ""
    /** the PS5 asks for the account's passcode (true: the last one was wrong) */
    @Published var askPin: Bool?
    /** the Xbox player, open to play and translate, or only to sign in (Setup) */
    @Published var xbox: XboxMode?
    /** the TVs connected to this phone (Show on): while there are any, the screens say to keep the app open */
    @Published var tvCount = 0
    /** back from the background, where the TVs lost the translations: Play says why, until dismissed */
    @Published var tvLost = false
    @Published var dark = Prefs.dark
    @Published var uiLang = "en"
    @Published var source: Source?

    /** (demo: a picture drawn by the app, for the simulator and CI: -vitDemoText) */
    enum Source { case ps5, xbox, capture, demo }
    enum XboxMode: Identifiable {
        case play, setup
        var id: Int { self == .play ? 0 : 1 }
    }

    private(set) var reader: Reader?
    private var stream: PsStream?
    private var card: CaptureCard?
    private var resumeOnActive = false
    private var tick: Timer?
    private var savedClear: DispatchWorkItem?
    private var linesPending = false
    let io = DispatchQueue(label: "app-io", qos: .userInitiated, attributes: .concurrent)

    private init() {
        CoreHost.device = UIDevice.current.name
        Gpu.watch()
        var err: String?
        var c: CoreHost?
        do {
            c = try CoreHost(recognizer: VisionRecognizer())
        } catch {
            err = "\(error)"
            NSLog("the core didn't start: \(error)")
        }
        core = c
        coreError = err
        cfg = Cfg(core: c)
        mode = UserDefaults.standard.string(forKey: "vitMode") ?? Prefs.lastMode
        tab = UserDefaults.standard.string(forKey: "vitTab") ?? "source"
        I18n.load(Prefs.uiLanguage.isEmpty ? "en" : Prefs.uiLanguage)
        uiLang = I18n.code
        cfg.changed = { [weak self] in self?.rev += 1 }
        cfg.saved = { [weak self] ok in self?.showSaved(ok) }
        let feed = picture
        // (the PS5's picture: VideoOut, up to 15 a second, while the preview is on)
        VideoOut.shared.onImage = { img in if Prefs.preview || img == nil { feed.image = img } }
        c?.linesChanged = { [weak self] in
            DispatchQueue.main.async { self?.refreshLines() }
        }
        c?.statusChanged = { [weak self] msg in
            DispatchQueue.main.async { self?.coreStatus = msg.isEmpty ? nil : msg }
        }
        load()
    }

    /** The settings come from the core (its files): a moment off the main thread, then the screen. */
    private func load() {
        let cfg = self.cfg
        let core = self.core
        io.async {
            let json = cfg.loadBlocking()
            // The TV page is served while the app runs (as the PC app does while open): a connected
            // TV finds the phone at once, and shows the translations when translating starts.
            do { try core?.startServer() } catch { NSLog("the TV page couldn't start: \(error)") }
            DispatchQueue.main.async { [self] in
                cfg.set(json)
                // the interface language and the theme are the desktop's settings; the phone's language picks the first
                var lang = cfg.str("ui_lang")
                if lang.isEmpty {
                    lang = I18n.fromLocale(Locale.current)
                    cfg.put("ui_lang", lang)
                }
                apply(lang: lang)
                dark = cfg.str("theme", "dark") != "light"
                Prefs.dark = dark
                loaded = true
                refreshLines()
                refreshTvs()
                debugOptions()
                tick = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                    Task { @MainActor in self?.everySecond() }
                }
            }
        }
    }

    func apply(lang: String) {
        I18n.load(lang)
        Prefs.uiLanguage = I18n.code
        uiLang = I18n.code
    }

    func setLanguage(_ code: String) {
        cfg.put("ui_lang", code, now: true)
        apply(lang: code)
        rev += 1
    }

    func toggleTheme() {
        dark.toggle()
        Prefs.dark = dark
        cfg.put("theme", dark ? "dark" : "light", now: true)
    }

    func setMode(_ m: String) {
        mode = m
        Prefs.lastMode = m
    }

    /** to a Setup tab */
    func go(_ t: String) {
        tab = t
        setMode("setup")
    }

    private func showSaved(_ ok: Bool) {
        savedLabel = ok ? L("Saved ✓") : L("Save failed")
        savedClear?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.savedLabel = "" }
        savedClear = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: w)
    }

    private func refreshLines() {
        guard let core, !linesPending else { return }
        linesPending = true
        io.async {
            let l = core.lines(max: 40)
            DispatchQueue.main.async { [self] in
                linesPending = false
                lines = l
            }
        }
    }

    /** How many TVs are connected (tvCount). */
    func refreshTvs() {
        guard let core else { return }
        io.async {
            let n = core.pairedTvs().count
            DispatchQueue.main.async { [self] in tvCount = n }
        }
    }

    /**
     * Back on the screen: the TV page must answer again. iOS suspends an app soon after it leaves
     * the screen (unless it plays sound: the PS5's screen-off option), the TV page with it, and may
     * take back its listening socket: then it is started again. With TVs connected, Play says why
     * they lost the translations ([lost]: translating was paused while away).
     */
    private func checkTvPage(lost: Bool) {
        guard let core else { return }
        io.async {
            let answers = core.serverAnswers()
            if !answers {
                NSLog("the TV page didn't answer after the background: started again")
                core.restartServer()
            }
            let n = core.pairedTvs().count
            DispatchQueue.main.async { [self] in
                tvCount = n
                if n > 0 && (lost || !answers) { tvLost = true }
            }
        }
    }

    private func everySecond() {
        if let r = reader, state == .reading {
            picture.stats = L("{n} read · {ms} ms", ("n", r.read), ("ms", r.lastMs))
        } else if !picture.stats.isEmpty {
            picture.stats = ""
        }
        let s: String
        if let snd = stream?.sound, state == .reading {
            s = !snd.running ? L("Game sound on the phone: not playing (iOS refused it)")
                : snd.received > 0 ? L("Game sound on the phone: playing") : L("Game sound on the phone: no sound from the PS5 yet")
        } else {
            s = ""
        }
        if picture.sound != s { picture.sound = s }
    }

    // ---- the status line (the header's pill)

    var statusText: String {
        switch state {
        case .idle: return coreStatus ?? (core == nil ? L("Stopped: {reason}", ("reason", coreError ?? "")) : L("Ready"))
        case .starting: return L("Starting…")
        case .connecting: return L("Connecting to the PS5…")
        case .reading: return coreStatus ?? L("Translating")
        case .ended: return L("Stopped") + (detail.map { " (\($0))" } ?? "")
        case .failed: return L("Stopped: {reason}", ("reason", detail ?? ""))
        }
    }

    private func set(_ s: LiveState, _ d: String?) {
        state = s
        detail = d
        // (the phone stays on the app while translating: iOS pauses apps that leave the screen)
        UIApplication.shared.isIdleTimerDisabled = s.running || xbox == .play
    }

    // ---- translating

    /** Start translating from the console chosen in Source (the Xbox: its player opens). */
    func start() {
        switch Prefs.console {
        case "ps5": begin(.ps5)
        case "xbox": xbox = .play
        case "capture": begin(.capture)
        default: go("source")
        }
    }

    func stop() {
        resumeOnActive = false
        retriesLeft = 0
        end(.idle, nil)
        if xbox == .play { xbox = nil }
    }

    /** The Xbox player opened to play: translating starts with it. */
    func xboxOpened() {
        begin(.xbox)
    }

    func xboxClosed() {
        if source == .xbox { end(.idle, nil) }
    }

    private func begin(_ s: Source) {
        guard !state.running || source != s else { return }
        end(.idle, nil)
        guard let core else {
            set(.failed, coreError)
            return
        }
        source = s
        set(.starting, nil)
        let cfg = self.cfg
        cfg.flush()
        io.async {
            do {
                // the language and the game: the settings' (the desktop's target_lang, and the game of the profile in use)
                let c = Cfg.parse(core.configJson())
                let all = ((c["builtins"] as? [NSDictionary]) ?? []) + ((c["profiles"] as? [NSDictionary]) ?? [])
                var game = all.first { Cfg.s($0, "id") == Cfg.s(c, "profile") }.map { Cfg.s($0, "game") } ?? ""
                if game.isEmpty { game = "gta6" }
                let lang = Cfg.s(c, "target_lang").isEmpty ? "ar" : Cfg.s(c, "target_lang")
                try core.prepare(game: game, language: lang)
                try core.startServer()
            } catch {
                DispatchQueue.main.async { [self] in
                    if source == s { set(.failed, error.localizedDescription) }
                }
                return
            }
            DispatchQueue.main.async { [self] in
                guard source == s, state == .starting else { return }
                let r = Reader(core: core)
                reader = r
                wirePreview()
                switch s {
                case .ps5: startPs(r)
                case .xbox: set(.reading, nil)
                case .capture: startCapture(r)
                case .demo: startDemo(r)
                }
            }
        }
    }

    private func startPs(_ r: Reader) {
        guard Ps5.available, let console = Ps5.saved else {
            set(.failed, Ps5.available ? L("Not linked to a PS5 yet.") : L("PS Remote Play isn't in this build of the app."))
            return
        }
        let st = PsStream(console: console, reader: r)
        st.onState = { [weak self] s, d in
            guard let self, self.stream === st else { return }
            switch s {
            case .connecting: self.set(.connecting, nil)
            case .streaming:
                self.retriesLeft = 0
                self.set(.reading, nil)
            case .ended, .failed:
                if self.away {
                    // (ended while away: started again on return)
                    self.resumeOnActive = true
                    self.end(.ended, L("iOS paused the app in the background"))
                } else if self.retriesLeft > 0 {
                    // (just back: the PS5 may still hold the last session; again in a moment)
                    self.retriesLeft -= 1
                    self.end(.connecting, nil)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                        guard let self, self.state == .connecting, self.source == nil else { return }
                        self.begin(.ps5)
                    }
                } else {
                    self.end(s == .failed ? .failed : .ended, d)
                }
            }
        }
        st.onLoginPin = { [weak self] incorrect in self?.askPin = incorrect }
        stream = st
        st.start(height: Prefs.psResolution, sound: Prefs.screenOff)
    }

    /** The capture card (an iPad with USB-C): read as soon as it gives frames. */
    private func startCapture(_ r: Reader) {
        let c = CaptureCard(reader: r)
        c.onState = { [weak self] s, d in
            guard let self, self.card === c else { return }
            switch s {
            case .reading: self.set(.reading, nil)
            case .ended: self.end(.ended, d)
            case .failed: self.end(.failed, d)
            }
        }
        card = c
        c.start()
    }

    func setPhoneVolume(_ v: Double) {
        Prefs.phoneVolume = v
        stream?.setVolume(v)
    }

    func pin(_ p: String) {
        stream?.setLoginPin(p)
        askPin = nil
    }

    private var demo: Timer?

    /** A game-like picture with [text] as a subtitle, offered as the console's would be (CI). */
    private func startDemo(_ r: Reader) {
        set(.reading, nil)
        let text = UserDefaults.standard.string(forKey: "vitDemoText") ?? "Where were you last night?"
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        let img = UIGraphicsImageRenderer(size: CGSize(width: 1280, height: 720), format: fmt).image { ctx in
            UIColor(red: 0.16, green: 0.2, blue: 0.27, alpha: 1).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 1280, height: 720))
            UIColor(red: 0.45, green: 0.35, blue: 0.3, alpha: 1).setFill()
            ctx.fill(CGRect(x: 0, y: 430, width: 1280, height: 290))
            let para = NSMutableParagraphStyle()
            para.alignment = .center
            let font = UIFont.systemFont(ofSize: 34, weight: .semibold)
            let outline: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: para, .strokeColor: UIColor.black, .strokeWidth: 8]
            let fill: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: para, .foregroundColor: UIColor.white]
            let r = CGRect(x: 140, y: 610, width: 1000, height: 50)
            (text as NSString).draw(in: r, withAttributes: outline)
            (text as NSString).draw(in: r, withAttributes: fill)
        }
        guard let cg = img.cgImage else { return }
        var n = 0
        let core = self.core
        demo = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            r.offer(ImageFrame(image: cg))
            n += 1
            // (for CI: what the core made of it, every 5 s)
            if n % 20 == 0, let core {
                self?.io.async {
                    NSLog("VIT-CI read=%d memory=%@ perf=%@ status=%@", r.read, core.engine.memoryStatsJson(), core.engine.perfJson(), self?.coreStatus ?? "")
                }
            }
        }
    }

    private func end(_ s: LiveState, _ d: String?) {
        demo?.invalidate()
        demo = nil
        stream?.stop()
        stream = nil
        card?.stop()
        card = nil
        reader?.close()
        reader = nil
        source = nil
        picture.stats = ""
        set(s, d)
    }

    /** The preview gets frames while it is switched on. */
    func wirePreview() {
        guard let r = reader else { return }
        // (the PS5's and the capture card's pictures go to the preview straight from their frames: VideoOut)
        if Prefs.preview && source != .ps5 && source != .capture {
            let feed = picture
            r.preview = { img in DispatchQueue.main.async { feed.image = img } }
        } else {
            r.preview = nil
        }
    }

    func setPreview(_ on: Bool) {
        Prefs.preview = on
        wirePreview()
        rev += 1
    }

    // ---- the app on and off the screen

    /**
     * The app left the screen (the notification shade, the lock button, another app). iOS lets it run
     * about 30 s more: the PS5's stream is kept that long, so a short trip away doesn't end it (the
     * picture comes back with the next key frame). Away longer, the stream is stopped cleanly (so the
     * PS5 lets it go) before iOS pauses the app, and it starts again on return.
     */
    func scene(_ phase: ScenePhase) {
        switch phase {
        case .background:
            cfg.flush()
            if leftAt == nil { leftAt = Date() }
            guard state.running, source == .ps5, !away else { return }
            if Prefs.screenOff, let st = stream {
                // (the game's sound keeps the app running: the picture is read on the CPU while away.
                // If the sound doesn't play after all, iOS would pause the app: then as without the option)
                awayPlaying = true
                VisionRecognizer.cpuOnly = true
                st.background(true)
                bgTask = UIApplication.shared.beginBackgroundTask(withName: "ps5-sound") { [weak self] in self?.endBackgroundTask() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                    guard let self, self.awayPlaying else { return }
                    if self.stream?.sound?.running == true {
                        self.endBackgroundTask()
                    } else {
                        NSLog("the game's sound isn't playing: the stream stops while away")
                        self.awayPlaying = false
                        VisionRecognizer.cpuOnly = false
                        self.away = true
                        self.awayTooLong()
                    }
                }
                return
            }
            away = true
            reader?.paused = true
            bgTask = UIApplication.shared.beginBackgroundTask(withName: "ps5-stream") { [weak self] in self?.awayTooLong() }
            awayTimer?.invalidate()
            awayTimer = Timer.scheduledTimer(withTimeInterval: Self.awayGrace, repeats: false) { [weak self] _ in
                Task { @MainActor in self?.awayTooLong() }
            }
        case .active:
            if let t = leftAt {
                // (what happened while away, before it is reset below: translating paused by iOS, or
                // running without the sound that keeps the app going, for longer than iOS allows)
                leftAt = nil
                let keptOn = awayPlaying && stream?.sound?.running == true
                let long = Date().timeIntervalSince(t) > Self.awayGrace
                checkTvPage(lost: resumeOnActive || (state.running && long && !keptOn))
            }
            if awayPlaying {
                awayPlaying = false
                VisionRecognizer.cpuOnly = false
                stream?.background(false)
            }
            if away {
                away = false
                awayTimer?.invalidate()
                awayTimer = nil
                endBackgroundTask()
                reader?.paused = false
                // (the decoder may have been dropped by iOS while away: the next key frame makes it again)
                stream?.refresh()
            }
            if resumeOnActive {
                resumeOnActive = false
                retriesLeft = 4
                begin(.ps5)
            }
        default:
            break
        }
    }

    /** how long the stream is kept while the app is away (iOS allows about 30 s) */
    static let awayGrace: TimeInterval = 25
    private var away = false
    /** when the app last left the screen (nil: it is on it) */
    private var leftAt: Date?
    /** away with the screen-off option: the stream and the reading go on, on the CPU */
    private var awayPlaying = false
    private var awayTimer: Timer?
    private var bgTask: UIBackgroundTaskIdentifier = .invalid
    /** reconnections left after coming back (the PS5 may still hold the last session for a moment) */
    private var retriesLeft = 0

    private func awayTooLong() {
        awayTimer?.invalidate()
        awayTimer = nil
        if away && source == .ps5 && state.running {
            resumeOnActive = true
            end(.ended, L("iOS paused the app in the background"))
        }
        endBackgroundTask()
    }

    private func endBackgroundTask() {
        if bgTask != .invalid {
            UIApplication.shared.endBackgroundTask(bgTask)
            bgTask = .invalid
        }
    }

    // ---- for the simulator and CI (launch arguments): -vitMode, -vitTab, -vitConsole, -vitFakePs5 <address>,
    //      -vitPairTv <address> -vitPairCode <code>, -vitPs5Steps YES
    private func debugOptions() {
        let d = UserDefaults.standard
        if let c = d.string(forKey: "vitConsole") { Prefs.console = c }
        if let host = d.string(forKey: "vitFakePs5") {
            Ps5.saved = PsConsole(host: host, nickname: "fake PS5", mac: Data(count: 6),
                                  registKey: Data("0123abcd".utf8) + Data(count: 8), rpKey: Data(count: 16))
        }
        if let lang = d.string(forKey: "vitUiLang") { setLanguage(lang) }
        if let addr = d.string(forKey: "vitPairTv"), let code = d.string(forKey: "vitPairCode"), let core {
            io.async {
                let r = core.pairTv(address: addr, code: code)
                NSLog("VIT-CI pairTv \(addr): \(r)")
            }
        }
        if d.bool(forKey: "vitStart") { start() }
        if d.string(forKey: "vitDemoText") != nil { begin(.demo) }
    }
}
