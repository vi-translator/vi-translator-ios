import CoreImage
import CoreVideo
import Foundation
import Metal
import UIKit

/**
 * The PS5's picture in the app's preview, smoother than the reading's ~4 frames a second: up to 10,
 * 15 or 30 decoded frames a second (Show on › Preview; the stream itself has 30) (GPU buffers) are drawn small by Core Image on the GPU, with the same
 * studio-levels stretch as the reading, and shown. A frame that comes while the last is still being
 * drawn is skipped, so the decoder never waits.
 */
final class VideoOut: @unchecked Sendable {
    static let shared = VideoOut()

    /** told on the main thread with each picture (nil: the stream stopped) */
    var onImage: ((UIImage?) -> Void)?

    private let queue = DispatchQueue(label: "preview", qos: .userInitiated)
    private let lock = NSLock()
    private var busy = false
    private var busySince: TimeInterval = 0
    private var lastShown: TimeInterval = 0
    private let context: CIContext = {
        let opts: [CIContextOption: Any] = [.workingColorSpace: NSNull(), .outputColorSpace: NSNull(), .cacheIntermediates: false]
        if let d = MTLCreateSystemDefaultDevice() { return CIContext(mtlDevice: d, options: opts) }
        return CIContext(options: opts)
    }()

    /** the preview's width in pixels */
    static let width: CGFloat = 960

    /** A decoded frame (on the decoder's thread). */
    func show(_ buffer: CVPixelBuffer) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        // (a draw that never finished, in the background: given up after 2 s)
        if busy && now - busySince > 2 { busy = false }
        guard Gpu.allowed, onImage != nil, !busy, now - lastShown >= 1.0 / Double(max(Prefs.previewFps, 1)) - 0.004 else {
            lock.unlock()
            return
        }
        busy = true
        busySince = now
        lastShown = now
        lock.unlock()
        queue.async { [self] in
            defer {
                lock.lock()
                busy = false
                lock.unlock()
            }
            if CVBufferCopyAttachment(buffer, kCVImageBufferYCbCrMatrixKey, nil) == nil {
                CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
            }
            var image = CIImage(cvPixelBuffer: buffer, options: [.colorSpace: NSNull()])
            let s = min(1, Self.width / image.extent.width)
            image = image.transformed(by: CGAffineTransform(scaleX: s, y: s))
            let g = CGFloat(FrameConverter.gain), b = CGFloat(FrameConverter.bias)
            image = image.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: g, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: g, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: g, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBiasVector": CIVector(x: b, y: b, z: b, w: 0),
            ]).applyingFilter("CIColorClamp")
            guard let cg = context.createCGImage(image, from: image.extent.integral, format: .RGBA8,
                                                 colorSpace: CGColorSpaceCreateDeviceRGB()) else { return }
            let ui = UIImage(cgImage: cg)
            DispatchQueue.main.async { [weak self] in self?.onImage?(ui) }
        }
    }

    /** The stream ended. */
    func stop() {
        DispatchQueue.main.async { [weak self] in self?.onImage?(nil) }
    }
}
