import CoreImage
import ReplayKit
import SwiftUI
import WebKit

/**
 * Xbox: Microsoft's own Remote Play web player, in the app (WKWebView), signed in by the user there,
 * as in the Android app. While it plays, the app copies the page's picture about 4 times a second
 * (the web view's snapshot) for text recognition. If the copies come out black (the video drawn
 * where a snapshot can't see it), it offers to record this app's screen instead (ReplayKit, which
 * iOS asks the user to allow): only the player's part of the screen is read.
 */
enum XboxPlayer {
    static let url = URL(string: "https://play.xbox.com/remoteplay")!
    static let period = 0.25
    static let blackFrames = 40
    /** sign-in and the player stay in here; anything else opens in Safari */
    static let allowed = [
        "xbox.com", "live.com", "microsoft.com", "microsoftonline.com", "msftauth.net", "msauth.net",
        "live.net", "xboxlive.com", "akamaized.net", "msecnd.net", "microsoftonline-p.com", "xboxservices.com",
    ]

    /** Microsoft's player is made for desktop browsers: a phone's is sent to the Xbox app. Safari on a Mac, which it supports. */
    static let desktopUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    static func isAllowed(_ host: String) -> Bool {
        allowed.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /**
     * Signed in to Microsoft in the player, as far as the app can tell: Microsoft's sign-in keeps its
     * "stay signed in" cookies on login.live.com.
     */
    @MainActor
    static func signedIn() async -> Bool {
        let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        return cookies.contains { c in c.domain.hasSuffix("live.com") && ["MSPAuth", "WLSSC", "ESTSAUTHPERSISTENT"].contains(c.name) }
    }

    /** Forget the Microsoft sign-in and the player's saved session (cookies and its storage). */
    @MainActor
    static func signOut() async {
        let store = WKWebsiteDataStore.default()
        let records = await store.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
        let ours = records.filter { r in allowed.contains { r.displayName.hasSuffix($0) } }
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: ours)
    }

    /** The picture at 64 pixels wide (for telling a black one). */
    static func shrink(_ image: CGImage) -> CGImage? {
        let w = 64, h = max(1, 64 * image.height / max(1, image.width))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .low
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /** Every 64th pixel dark (every pixel, for a small copy): a copy with no video in it. */
    static func isBlack(_ rgba: Data, _ w: Int, _ h: Int) -> Bool {
        guard w > 0, h > 0, rgba.count >= w * h * 4 else { return true }
        return rgba.withUnsafeBytes { (p: UnsafeRawBufferPointer) -> Bool in
            let step = w <= 64 ? 1 : 64
            var y = 0
            while y < h {
                var x = 0
                while x < w {
                    let i = (y * w + x) * 4
                    if Int(p[i]) + Int(p[i + 1]) + Int(p[i + 2]) > 48 { return false }
                    x += step
                }
                y += step
            }
            return true
        }
    }
}

/** The player, to play and translate, or only to sign in and choose the console (Setup: nothing is read). */
struct XboxPlayerView: View {
    @EnvironmentObject var m: AppModel
    @Environment(\.kit) var k
    @Environment(\.dismiss) var dismiss
    let mode: AppModel.XboxMode
    @StateObject private var player = XboxCapture()

    var body: some View {
        VStack(spacing: 0) {
            XboxWebView(player: player)
            // (the bar is under the player, not over it: the copies are of the player alone, so the app
            // never reads its own words)
            HStack(spacing: 8) {
                Text(mode == .setup ? L("Sign in, then choose your Xbox. Close when done.") : player.status)
                    .font(k.font(k.base - 2)).foregroundColor(.white).lineLimit(2)
                Spacer(minLength: 4)
                if player.offerRecording && mode == .play {
                    KButton(L("The video can't be read: record the screen"), full: false) { player.startRecording() }
                }
                KButton(L("Close"), full: false) { dismiss() }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(Color.black)
        }
        .background(Color.black.ignoresSafeArea())
        .interactiveDismissDisabled(mode == .play)
        .onAppear {
            player.model = m
            if mode == .play {
                m.xboxOpened()
                player.start()
            }
        }
        .onDisappear {
            player.stop()
            if mode == .play { m.xboxClosed() }
            if m.xbox != nil { m.xbox = nil }
        }
    }
}

/** The copies of the player's picture, to the reader. */
@MainActor
final class XboxCapture: ObservableObject {
    weak var web: WKWebView?
    weak var model: AppModel?
    @Published var status = ""
    @Published var offerRecording = false
    @Published var loaded = false
    private var timer: Timer?
    private var black = 0
    private var recording = false
    private let ci = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: XboxPlayer.period, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if recording {
            recording = false
            RPScreenRecorder.shared().stopCapture { _ in }
        }
    }

    /** One copy of the page's picture (the web view's snapshot), then the next a quarter of a second later. */
    private func tick() {
        guard !recording, let web, web.window != nil, web.bounds.width > 0, let reader = model?.reader else { return }
        let cfg = WKSnapshotConfiguration()
        cfg.afterScreenUpdates = false
        web.takeSnapshot(with: cfg) { [weak self] image, _ in
            guard let self, let cg = image?.cgImage else { return }
            // (a tiny copy tells a black picture: the whole one is copied only when the reader takes it)
            if let tiny = Reader.rgba(of: XboxPlayer.shrink(cg) ?? cg) {
                self.noteBlack(XboxPlayer.isBlack(tiny.0, tiny.1, tiny.2))
            }
            reader.offer(ImageFrame(image: cg))
            self.status = L("Read {n} frames ({size})", ("n", reader.read), ("size", reader.frameSize))
        }
    }

    /**
     * After ~10 s of black copies of a loaded page, offer to record the screen instead (the video
     * is drawn where a snapshot can't see it); a picture again takes the offer back.
     */
    private func noteBlack(_ isBlack: Bool) {
        guard loaded else { return }
        if !isBlack {
            black = 0
            offerRecording = false
            return
        }
        black += 1
        if black == XboxPlayer.blackFrames { offerRecording = true }
    }

    /** ReplayKit: the app's own screen, cropped to the player (iOS asks the user to allow it). */
    func startRecording() {
        guard let web else { return }
        let rec = RPScreenRecorder.shared()
        rec.isMicrophoneEnabled = false
        let crop = web.convert(web.bounds, to: nil)
        let scale = web.window?.screen.scale ?? UIScreen.main.scale
        let ci = self.ci
        recording = true
        offerRecording = false
        var last = 0.0
        rec.startCapture(handler: { [weak self] sample, type, error in
            guard error == nil, type == .video, let pb = CMSampleBufferGetImageBuffer(sample) else { return }
            let now = ProcessInfo.processInfo.systemUptime
            guard now - last >= XboxPlayer.period else { return }
            last = now
            // (the screen's pixels, the player's part; the image is made by Core Image, whatever the buffer's layout)
            let full = CIImage(cvPixelBuffer: pb)
            let h = full.extent.height
            let r = CGRect(x: crop.minX * scale, y: h - crop.maxY * scale, width: crop.width * scale, height: crop.height * scale).intersection(full.extent)
            guard !r.isEmpty, let cg = ci.createCGImage(full, from: r) else { return }
            Task { @MainActor in
                guard let self, let reader = self.model?.reader else { return }
                reader.offer(ImageFrame(image: cg))
                self.status = L("Read {n} frames ({size})", ("n", reader.read), ("size", reader.frameSize))
            }
        }, completionHandler: { [weak self] error in
            if let error {
                Task { @MainActor in
                    self?.recording = false
                    self?.status = error.localizedDescription
                }
            }
        })
    }
}

/** Microsoft's player in a web view: a desktop browser's, signed in by the user. */
struct XboxWebView: UIViewRepresentable {
    let player: XboxCapture

    func makeCoordinator() -> Coordinator { Coordinator(player) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.defaultWebpagePreferences.preferredContentMode = .desktop
        let web = WKWebView(frame: .zero, configuration: config)
        web.customUserAgent = XboxPlayer.desktopUA
        web.backgroundColor = .black
        web.isOpaque = true
        web.navigationDelegate = context.coordinator
        web.uiDelegate = context.coordinator
        web.load(URLRequest(url: XboxPlayer.url))
        player.web = web
        return web
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let player: XboxCapture

        init(_ p: XboxCapture) { player = p }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { @MainActor in self.player.loaded = true }
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url, let host = url.host else {
                decisionHandler(.allow)
                return
            }
            if XboxPlayer.isAllowed(host) || url.scheme == "about" || url.scheme == "blob" || url.scheme == "data" {
                decisionHandler(.allow)
                return
            }
            decisionHandler(.cancel)
            UIApplication.shared.open(url)
        }

        /** (sign-in pop-ups open in the same view) */
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if action.targetFrame == nil { webView.load(action.request) }
            return nil
        }

        /** the player's microphone and camera: not asked for, refused */
        @available(iOS 15.0, *)
        func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
            decisionHandler(.deny)
        }
    }
}
