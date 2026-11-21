import CoreGraphics
import Foundation
import UIKit

/** A picture of the game, whatever it came from. */
protocol Frame {
    /**
     * A hold on the picture, taken on the producer's thread while the frame is still there (quick:
     * no copy of the pixels); [Snapshot.rgba] then makes the RGBA picture on the reading thread.
     */
    func snapshot() throws -> Snapshot
}

protocol Snapshot {
    var width: Int { get }
    var height: Int { get }

    /** The picture as RGBA, 4 bytes a pixel, row after row, top row first. */
    func rgba() throws -> Data
}

/**
 * Reads the game, as the Android app's Reader: of the frames offered (as fast as they come), takes
 * one whenever the core is ready for the next (it sets the pace, about 4 a second), and gives it to
 * the core, which crops its areas and has Vision read them. A frame offered while the last one is
 * still being read, or too early, is skipped at once, so the stream never waits for the reading.
 */
final class Reader: @unchecked Sendable {
    private let core: CoreHost
    private let worker = DispatchQueue(label: "reader", qos: .userInitiated)
    private let lock = NSLock()
    private var busy = false
    private var nextAt: TimeInterval = 0

    /** For the screen: frames seen, frames read, and how long the last reading took. */
    private(set) var offered = 0
    private(set) var read = 0
    private(set) var lastMs = 0
    private(set) var frameSize = ""

    /** The last frame read, whole (RGBA, width, height): what a snapshot translates. */
    private(set) var last: (Data, Int, Int)?

    /** The screen's preview, while it shows one: gets a small copy of each frame read (on the reading thread). */
    var preview: ((UIImage) -> Void)?

    init(core: CoreHost) {
        self.core = core
    }

    /**
     * A new frame (on the producer's thread). True when it was taken: its snapshot was made before
     * this returns, so the producer can let the frame go either way.
     */
    @discardableResult
    func offer(_ frame: Frame) -> Bool {
        lock.lock()
        offered += 1
        let now = ProcessInfo.processInfo.systemUptime
        if now < nextAt || busy {
            lock.unlock()
            return false
        }
        busy = true
        lock.unlock()
        let snap: Snapshot
        do {
            snap = try frame.snapshot()
        } catch {
            NSLog("Reader: copy failed: \(error)")
            setBusy(false)
            return false
        }
        worker.async { [self] in
            let start = ProcessInfo.processInfo.systemUptime
            do {
                let rgba = try snap.rgba()
                frameSize = "\(snap.width)x\(snap.height)"
                last = (rgba, snap.width, snap.height)
                if let show = preview, let img = Reader.small(rgba, snap.width, snap.height) { show(img) }
                let wait = try core.processFrame(rgba, width: snap.width, height: snap.height)
                lastMs = Int((ProcessInfo.processInfo.systemUptime - start) * 1000)
                lock.lock()
                nextAt = start + Double(min(wait, 2000)) / 1000
                read += 1
                lock.unlock()
            } catch {
                NSLog("Reader: reading failed: \(error)")
                lock.lock()
                nextAt = ProcessInfo.processInfo.systemUptime + 1
                lock.unlock()
            }
            setBusy(false)
        }
        return true
    }

    private func setBusy(_ b: Bool) {
        lock.lock()
        busy = b
        lock.unlock()
    }

    /** The picture stopped (the stream ended). */
    func noPicture() {
        worker.async { [core] in core.noPicture() }
    }

    func close() {
        preview = nil
        noPicture()
    }

    /** RGBA bytes as an image, at most [maxWidth] pixels wide (the preview's copy). */
    static func small(_ rgba: Data, _ w: Int, _ h: Int, maxWidth: Int = 960) -> UIImage? {
        guard let full = cgImage(rgba, w, h) else { return nil }
        if w <= maxWidth { return UIImage(cgImage: full) }
        let sw = maxWidth, sh = max(1, maxWidth * h / w)
        guard let ctx = CGContext(data: nil, width: sw, height: sh, bitsPerComponent: 8, bytesPerRow: sw * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(full, in: CGRect(x: 0, y: 0, width: sw, height: sh))
        return ctx.makeImage().map { UIImage(cgImage: $0) }
    }

    /** RGBA bytes (top row first) as an image. */
    static func cgImage(_ rgba: Data, _ w: Int, _ h: Int) -> CGImage? {
        guard w > 0, h > 0, rgba.count >= w * h * 4, let provider = CGDataProvider(data: rgba as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /** Any image drawn into plain RGBA bytes (top row first): its own pixel layout never matters. */
    static func rgba(of image: CGImage, crop: CGRect? = nil) -> (Data, Int, Int)? {
        let r = (crop ?? CGRect(x: 0, y: 0, width: image.width, height: image.height)).integral
        let w = Int(r.width), h = Int(r.height)
        guard w > 0, h > 0 else { return nil }
        var data = Data(count: w * h * 4)
        let ok = data.withUnsafeMutableBytes { (buf: UnsafeMutableRawBufferPointer) -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            // (Core Graphics' origin is the bottom left: the image is drawn so its top row lands first in memory)
            ctx.draw(image, in: CGRect(x: -r.minX, y: -(CGFloat(image.height) - r.maxY), width: CGFloat(image.width), height: CGFloat(image.height)))
            return true
        }
        return ok ? (data, w, h) : nil
    }
}

/** A frame that is a Core Graphics image (the Xbox player's snapshots). */
struct ImageFrame: Frame {
    let image: CGImage
    var crop: CGRect?

    func snapshot() throws -> Snapshot { ImageSnapshot(image: image, crop: crop) }
}

private struct ImageSnapshot: Snapshot {
    let image: CGImage
    let crop: CGRect?
    var width: Int { Int((crop ?? CGRect(x: 0, y: 0, width: image.width, height: image.height)).integral.width) }
    var height: Int { Int((crop ?? CGRect(x: 0, y: 0, width: image.width, height: image.height)).integral.height) }

    func rgba() throws -> Data {
        guard let d = Reader.rgba(of: image, crop: crop)?.0 else { throw CoreFailure("the picture couldn't be copied") }
        return d
    }
}
