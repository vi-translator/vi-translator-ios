import AVFoundation
import CoreVideo
import Foundation
import UIKit

/**
 * A USB capture card as the picture source, as the desktop's: the console's HDMI goes into the card,
 * the card's USB into the iPad, and the app reads the card's frames like the PS5's (Reader, the GPU's
 * FrameConverter). The TV keeps showing the game through the card's HDMI out (pass-through).
 *
 * iPadOS 17 or newer, on an iPad with USB-C, is the only Apple system that lets apps use such cards
 * (USB Video Class "external cameras"); iPhones don't, even with USB-C. A card with a USB-A plug
 * works through a USB-C adapter or hub.
 *
 * The card's format: 1080p if it has it (as the desktop picks), else the nearest at 720p or more,
 * at 30 frames a second when it can (the reading takes ~12, the preview at most 30). Its frames are
 * never read in the card's own layout: the GPU draws whatever format it gives into RGBA.
 */
final class CaptureCard: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    enum State { case reading, ended, failed }

    /** whether this device lets apps use capture cards (an iPad with iPadOS 17 or newer) */
    static var supported: Bool {
        if #available(iOS 17.0, *) { return UIDevice.current.userInterfaceIdiom == .pad }
        return false
    }

    /** a capture card connected now */
    struct Card: Hashable {
        let id: String
        let name: String
    }

    /** The capture cards connected now (none where they aren't supported). */
    static func cards() -> [Card] {
        guard #available(iOS 17.0, *), supported else { return [] }
        return AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .video, position: .unspecified)
            .devices.map { Card(id: $0.uniqueID, name: $0.localizedName) }
    }

    /** The card to read: the one chosen in Source, else the first connected. */
    static func chosen() -> Card? {
        let all = cards()
        return all.first { $0.id == Prefs.captureCard } ?? all.first
    }

    /** told on the main thread: reading, ended or failed (with what to tell the player) */
    var onState: ((State, String?) -> Void)?
    /** what the card gives, for the screen: "1920x1080 30 fps" */
    private(set) var format = ""

    private let reader: Reader
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "capture", qos: .userInitiated)
    // (the card's HDMI picture already has the console's levels: no studio-levels stretch, unlike the PS5's stream)
    private let converter = FrameConverter(stretchLevels: false)
    private var observers: [NSObjectProtocol] = []
    private var device: AVCaptureDevice?
    private var stopped = false
    private var told = false

    init(reader: Reader) {
        self.reader = reader
    }

    /** Asks for the camera permission (the first time), then starts reading the card. */
    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            queue.async { [self] in open() }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [self] ok in
                if ok {
                    queue.async { [self] in open() }
                } else {
                    tell(.failed, Self.noPermission)
                }
            }
        default:
            tell(.failed, Self.noPermission)
        }
    }

    static var noPermission: String {
        L("VI Translator isn't allowed to use the capture card: turn on Camera in the iPad's Settings › VI Translator.")
    }

    func stop() {
        queue.async { [self] in
            guard !stopped else { return }
            stopped = true
            for o in observers { NotificationCenter.default.removeObserver(o) }
            observers = []
            if session.isRunning { session.stopRunning() }
            VideoOut.shared.stop()
            reader.noPicture()
        }
    }

    // ---- on the capture queue

    private func open() {
        guard !stopped else { return }
        guard #available(iOS 17.0, *), Self.supported else {
            tell(.failed, L("Capture cards work on an iPad with USB-C (iPadOS 17 or newer)."))
            return
        }
        let all = AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .video, position: .unspecified).devices
        guard let dev = all.first(where: { $0.uniqueID == Prefs.captureCard }) ?? all.first else {
            tell(.failed, L("No capture card found: plug it into the iPad's USB-C port."))
            return
        }
        device = dev
        do {
            let input = try AVCaptureDeviceInput(device: dev)
            let output = AVCaptureVideoDataOutput()
            output.alwaysDiscardsLateVideoFrames = true
            // (a YUV format the GPU draws, if the card offers one, else whatever it gives: never read by the CPU)
            let wanted: [OSType] = [kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, kCVPixelFormatType_32BGRA]
            if let pf = wanted.first(where: { output.availableVideoPixelFormatTypes.contains($0) }) {
                output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: pf]
            }
            output.setSampleBufferDelegate(self, queue: queue)
            session.beginConfiguration()
            guard session.canAddInput(input), session.canAddOutput(output) else {
                session.commitConfiguration()
                tell(.failed, L("The capture card couldn't be opened."))
                return
            }
            session.addInput(input)
            session.addOutput(output)
            choose(dev)
            session.commitConfiguration()
        } catch {
            tell(.failed, L("The capture card couldn't be opened.") + " (\(error.localizedDescription))")
            return
        }
        watch(dev)
        session.startRunning()
        if session.isRunning {
            tell(.reading, nil)
        } else {
            tell(.failed, L("The capture card couldn't be opened."))
        }
    }

    /** The card's format: see [best]. */
    private func choose(_ dev: AVCaptureDevice) {
        let formats = dev.formats
        let modes = formats.map { f -> Mode in
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            return Mode(width: Int(d.width), height: Int(d.height), maxFps: f.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0)
        }
        guard let i = Self.best(modes) else { return }
        let f = formats[i]
        do {
            try dev.lockForConfiguration()
            dev.activeFormat = f
            let fps = min(30, modes[i].maxFps)
            if fps > 0, f.videoSupportedFrameRateRanges.contains(where: { $0.minFrameRate <= fps && fps <= $0.maxFrameRate }) {
                let t = CMTime(value: 1000, timescale: CMTimeScale(fps * 1000))
                dev.activeVideoMinFrameDuration = t
                dev.activeVideoMaxFrameDuration = t
            }
            dev.unlockForConfiguration()
            format = "\(modes[i].width)x\(modes[i].height) \(Int(fps.rounded())) fps"
            NSLog("capture card \(dev.localizedName): \(format)")
        } catch {
            NSLog("capture card: its format couldn't be set: \(error)")
        }
    }

    private func watch(_ dev: AVCaptureDevice) {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: dev, queue: nil) { [weak self] _ in
            self?.tell(.ended, L("The capture card was unplugged."))
        })
        observers.append(nc.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { [weak self] n in
            let e = n.userInfo?[AVCaptureSessionErrorKey] as? Error
            NSLog("capture card: runtime error: \(String(describing: e))")
            self?.tell(.failed, L("The capture card stopped.") + (e.map { " (\($0.localizedDescription))" } ?? ""))
        })
        // (iOS interrupts the card while the app is in the background, or in Split View / Slide Over
        // beside another app, and resumes it by itself afterwards)
        observers.append(nc.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil) { [weak self] _ in
            self?.reader.noPicture()
        })
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard !stopped, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        if Prefs.preview { VideoOut.shared.show(buffer, stretch: false) }
        reader.offer(PixelBufferFrame(buffer: buffer, converter: converter))
    }

    /** once: the first ending or failure is the one told */
    private func tell(_ s: State, _ detail: String?) {
        DispatchQueue.main.async { [self] in
            if s != .reading {
                guard !told else { return }
                told = true
            }
            onState?(s, detail)
        }
    }

    // ---- the format

    struct Mode: Equatable {
        let width: Int
        let height: Int
        let maxFps: Double
    }

    /**
     * The best of the card's formats for reading: 1080p first (the desktop's choice, and the game
     * pages' checks are tuned on it), then 720p to 1080p (the nearest to 1080p), then above 1080p
     * (the nearest: 4K costs much more for no better reading), then below 720p; among the same size,
     * those that reach 30 frames a second, then the most frames.
     */
    static func best(_ modes: [Mode]) -> Int? {
        func score(_ m: Mode) -> (Int, Int, Int, Double) {
            let h = m.height
            let tier = h == 1080 ? 3 : (h >= 720 && h < 1080) ? 2 : h > 1080 ? 1 : 0
            return (tier, -abs(h - 1080), m.maxFps >= 29.9 ? 1 : 0, min(m.maxFps, 60))
        }
        return modes.indices.max { score(modes[$0]) < score(modes[$1]) }
    }
}
