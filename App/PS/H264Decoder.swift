import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/**
 * The PS5's H.264 stream decoded by VideoToolbox (the phone's hardware decoder) into CVPixelBuffers
 * on the GPU's memory (IOSurface), in whatever format the decoder writes: the pixels are never read
 * by the CPU from the decoder's own layout (see FrameConverter: the GPU draws them into plain RGBA).
 *
 * chiaki-ng gives each frame as Annex B (start codes; the parameter sets before each key frame);
 * VideoToolbox takes AVCC (each NAL unit after its 4-byte length) with a format made from the SPS
 * and PPS. Not thread-safe: one stream's frames, one at a time (chiaki's video thread).
 */
final class H264Decoder {
    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    private var sps: Data?
    private var pps: Data?
    private var decoded: ((CVPixelBuffer) -> Void)

    /** decoded frames, and frames the decoder refused */
    private(set) var frames = 0
    private(set) var errors = 0

    init(decoded: @escaping (CVPixelBuffer) -> Void) {
        self.decoded = decoded
    }

    deinit {
        close()
    }

    func close() {
        if let s = session {
            VTDecompressionSessionWaitForAsynchronousFrames(s)
            VTDecompressionSessionInvalidate(s)
        }
        session = nil
    }

    /** One frame (Annex B). False when it couldn't be decoded (a key frame is then needed). */
    @discardableResult
    func decode(_ annexB: UnsafeBufferPointer<UInt8>) -> Bool {
        let units = H264Decoder.nalUnits(annexB)
        var payload: [Data] = []
        var newSps: Data?, newPps: Data?
        for u in units {
            guard let first = u.first else { continue }
            switch first & 0x1f {
            case 7: newSps = u
            case 8: newPps = u
            case 9: continue // (access unit delimiter)
            default: payload.append(u)
            }
        }
        if let s = newSps, let p = newPps, s != sps || p != pps || session == nil {
            sps = s
            pps = p
            guard makeSession() else { return false }
        }
        guard let session, let format, !payload.isEmpty else { return session != nil }

        // AVCC: each unit after its length
        var avcc = Data(capacity: payload.reduce(0) { $0 + $1.count + 4 })
        for u in payload {
            var len = UInt32(u.count).bigEndian
            withUnsafeBytes(of: &len) { avcc.append(contentsOf: $0) }
            avcc.append(u)
        }
        var block: CMBlockBuffer?
        let size = avcc.count
        var st = CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: size,
                                                    blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
                                                    offsetToData: 0, dataLength: size, flags: kCMBlockBufferAssureMemoryNowFlag,
                                                    blockBufferOut: &block)
        guard st == noErr, let block else { return false }
        st = avcc.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: size) }
        guard st == noErr else { return false }
        var sample: CMSampleBuffer?
        var sizes = [size]
        st = CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
                                       sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
                                       sampleSizeEntryCount: 1, sampleSizeArray: &sizes, sampleBufferOut: &sample)
        guard st == noErr, let sample else { return false }
        // (synchronous: the frame is decoded before chiaki gives the next one)
        var flagsOut = VTDecodeInfoFlags()
        var ok = true
        let r = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: &flagsOut) { [weak self] status, _, image, _, _ in
            guard let self else { return }
            if status == noErr, let image {
                self.frames += 1
                self.decoded(image)
            } else {
                ok = false
                self.errors += 1
            }
        }
        if r == kVTInvalidSessionErr {
            // (after the app was in the background, the decoder must be made again)
            self.session = nil
            return false
        }
        return r == noErr && ok
    }

    private func makeSession() -> Bool {
        close()
        guard let sps, let pps else { return false }
        var fmt: CMVideoFormatDescription?
        let st: OSStatus = sps.withUnsafeBytes { s in
            pps.withUnsafeBytes { p in
                let sets: [UnsafePointer<UInt8>] = [s.bindMemory(to: UInt8.self).baseAddress!, p.bindMemory(to: UInt8.self).baseAddress!]
                let sizes = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault, parameterSetCount: 2,
                                                                           parameterSetPointers: sets, parameterSetSizes: sizes,
                                                                           nalUnitHeaderLength: 4, formatDescriptionOut: &fmt)
            }
        }
        guard st == noErr, let fmt else {
            NSLog("H264Decoder: bad parameter sets (\(st))")
            return false
        }
        format = fmt
        // the decoder's own YUV, in GPU memory: drawn into RGBA by the GPU (FrameConverter)
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        var s: VTDecompressionSession?
        let r = VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: fmt, decoderSpecification: nil,
                                             imageBufferAttributes: attrs as CFDictionary, outputCallback: nil, decompressionSessionOut: &s)
        guard r == noErr, let s else {
            NSLog("H264Decoder: no decoder (\(r))")
            return false
        }
        VTSessionSetProperty(s, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        session = s
        let dims = CMVideoFormatDescriptionGetDimensions(fmt)
        NSLog("H264Decoder: \(dims.width)x\(dims.height)")
        return true
    }

    /** The NAL units of an Annex B buffer (each without its start code). */
    static func nalUnits(_ b: UnsafeBufferPointer<UInt8>) -> [Data] {
        var out: [Data] = []
        let n = b.count
        var i = 0
        var start = -1
        while i + 2 < n {
            if b[i] == 0, b[i + 1] == 0, b[i + 2] == 1 {
                if start >= 0 {
                    var end = i
                    // (a 4-byte start code's leading zero belongs to it, not to the unit before)
                    while end > start, b[end - 1] == 0 { end -= 1 }
                    if end > start { out.append(Data(b[start..<end])) }
                }
                i += 3
                start = i
                continue
            }
            i += 1
        }
        if start >= 0, start < n { out.append(Data(b[start..<n])) }
        return out
    }
}
