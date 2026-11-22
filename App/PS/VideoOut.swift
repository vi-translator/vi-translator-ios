import AVFoundation
import CoreMedia
import CoreVideo
import SwiftUI
import UIKit

/**
 * The PS5's picture in the app's preview, smooth: each decoded frame (a GPU buffer) goes straight
 * to the screen's display layers (AVSampleBufferDisplayLayer), up to 30 a second, with no copy. The
 * reading itself still takes about 4 frames a second (Reader); this is only what the user sees.
 */
final class VideoOut: @unchecked Sendable {
    static let shared = VideoOut()

    private let lock = NSLock()
    private let layers = NSHashTable<AVSampleBufferDisplayLayer>.weakObjects()
    private var format: CMVideoFormatDescription?
    private var lastShown: TimeInterval = 0

    /** told on the main thread when the first picture of a stream is shown (and when it stops) */
    var showing: ((Bool) -> Void)?
    private var isShowing = false

    func add(_ layer: AVSampleBufferDisplayLayer) {
        lock.lock()
        layers.add(layer)
        lock.unlock()
    }

    func remove(_ layer: AVSampleBufferDisplayLayer) {
        lock.lock()
        layers.remove(layer)
        lock.unlock()
    }

    /** A decoded frame (on the decoder's thread). */
    func show(_ buffer: CVPixelBuffer) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        let targets = layers.allObjects
        guard !targets.isEmpty, now - lastShown >= 1.0 / 31 else {
            lock.unlock()
            return
        }
        lastShown = now
        if format == nil || !CMVideoFormatDescriptionMatchesImageBuffer(format!, imageBuffer: buffer) {
            var f: CMVideoFormatDescription?
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: buffer, formatDescriptionOut: &f)
            format = f
        }
        let fmt = format
        lock.unlock()
        guard let fmt else { return }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: buffer, formatDescription: fmt,
                                                       sampleTiming: &timing, sampleBufferOut: &sample) == noErr, let sample else { return }
        // (shown at once, whatever its time)
        if let atts = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true), CFArrayGetCount(atts) > 0 {
            let d = unsafeBitCast(CFArrayGetValueAtIndex(atts, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(d, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        for l in targets {
            if l.status == .failed { l.flush() }
            l.enqueue(sample)
        }
        if !isShowing {
            isShowing = true
            DispatchQueue.main.async { [weak self] in self?.showing?(true) }
        }
    }

    /** The stream ended: the layers are cleared. */
    func stop() {
        lock.lock()
        let targets = layers.allObjects
        format = nil
        lock.unlock()
        DispatchQueue.main.async { [weak self] in
            for l in targets { l.flushAndRemoveImage() }
            if self?.isShowing == true {
                self?.isShowing = false
                self?.showing?(false)
            }
        }
    }
}

/** A view showing the PS5's picture (VideoOut), fitted 16:9. */
struct VideoView: UIViewRepresentable {
    final class LayerView: UIView {
        override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
        var display: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }
    }

    func makeUIView(context: Context) -> LayerView {
        let v = LayerView()
        v.backgroundColor = .black
        v.display.videoGravity = .resizeAspect
        VideoOut.shared.add(v.display)
        return v
    }

    func updateUIView(_ uiView: LayerView, context: Context) {}

    static func dismantleUIView(_ uiView: LayerView, coordinator: ()) {
        VideoOut.shared.remove(uiView.display)
    }
}
