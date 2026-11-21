import CoreMedia
import CoreVideo
import UIKit
import VideoToolbox
import XCTest
@testable import VITranslator

/**
 * The PS5 path without a PS5: an H.264 stream made here (VideoToolbox's encoder) in chiaki-ng's
 * form (Annex B, the parameter sets before the key frame) goes through H264Decoder and
 * FrameConverter, as the PS5's does; and Vision reads text drawn into a picture.
 */
final class VideoTests: XCTestCase {
    /** A picture: the top half light grey (Y 180), the bottom half black (Y 16), 4:2:0 video range. */
    private func nv12(_ w: Int, _ h: Int, top: UInt8 = 180, bottom: UInt8 = 16) -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attrs as CFDictionary, &pb)
        let b = pb!
        CVPixelBufferLockBaseAddress(b, [])
        let y = CVPixelBufferGetBaseAddressOfPlane(b, 0)!.assumingMemoryBound(to: UInt8.self)
        let yRow = CVPixelBufferGetBytesPerRowOfPlane(b, 0)
        for r in 0..<h { memset(y + r * yRow, Int32(r < h / 2 ? top : bottom), w) }
        let uv = CVPixelBufferGetBaseAddressOfPlane(b, 1)!.assumingMemoryBound(to: UInt8.self)
        let uvRow = CVPixelBufferGetBytesPerRowOfPlane(b, 1)
        for r in 0..<(h / 2) { memset(uv + r * uvRow, 128, w) }
        CVPixelBufferUnlockBaseAddress(b, [])
        CVBufferSetAttachment(b, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        return b
    }

    func testConverterStretchesTheStudioLevelsAndKeepsTheTopRowFirst() throws {
        let (rgba, w, h) = try FrameConverter(stretchLevels: true).rgba(nv12(64, 32))
        XCTAssertEqual(w, 64)
        XCTAssertEqual(h, 32)
        let top = Int(rgba[0]), bottom = Int(rgba[(31 * 64) * 4])
        // Y 180 → full range (180-16)*255/219 = 191 → stretched again (191-16)*255/219 = 204
        XCTAssertEqual(top, 204, accuracy: 4)
        XCTAssertEqual(bottom, 0, accuracy: 3)
        XCTAssertEqual(rgba[3], 255)
        let (plain, _, _) = try FrameConverter(stretchLevels: false).rgba(nv12(64, 32))
        XCTAssertEqual(Int(plain[0]), 191, accuracy: 4)
    }

    /** Encodes [count] frames of a picture as chiaki-ng gives them: Annex B, each key frame after its SPS and PPS. */
    private func annexBFrames(_ count: Int, w: Int = 320, h: Int = 180) throws -> [Data] {
        var session: VTCompressionSession?
        XCTAssertEqual(VTCompressionSessionCreate(allocator: nil, width: Int32(w), height: Int32(h), codecType: kCMVideoCodecType_H264,
                                                  encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
                                                  outputCallback: nil, refcon: nil, compressionSessionOut: &session), noErr)
        let s = try XCTUnwrap(session)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Main_AutoLevel)
        var out: [Data] = []
        let lock = NSLock()
        for i in 0..<count {
            let props = i == 0 ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary : nil
            let st = VTCompressionSessionEncodeFrame(s, imageBuffer: nv12(w, h, top: UInt8(150 + i), bottom: 20),
                                                     presentationTimeStamp: CMTime(value: CMTimeValue(i), timescale: 30),
                                                     duration: CMTime(value: 1, timescale: 30), frameProperties: props, infoFlagsOut: nil) { status, _, sample in
                guard status == noErr, let sample, let data = Self.annexB(sample) else { return }
                lock.lock()
                out.append(data)
                lock.unlock()
            }
            XCTAssertEqual(st, noErr)
        }
        VTCompressionSessionCompleteFrames(s, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(s)
        return out
    }

    private static func annexB(_ sample: CMSampleBuffer) -> Data? {
        guard let block = CMSampleBufferGetDataBuffer(sample), let fmt = CMSampleBufferGetFormatDescription(sample) else { return nil }
        var out = Data()
        let start: [UInt8] = [0, 0, 0, 1]
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
        let key = !(attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
        if key {
            var count = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
            for i in 0..<count {
                var p: UnsafePointer<UInt8>?
                var n = 0
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmt, parameterSetIndex: i, parameterSetPointerOut: &p, parameterSetSizeOut: &n, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                out.append(contentsOf: start)
                out.append(p!, count: n)
            }
        }
        var length = 0
        var ptr: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &ptr) == noErr, let ptr else { return nil }
        let bytes = UnsafeRawPointer(ptr).assumingMemoryBound(to: UInt8.self)
        var i = 0
        while i + 4 <= length {
            let n = Int(bytes[i]) << 24 | Int(bytes[i + 1]) << 16 | Int(bytes[i + 2]) << 8 | Int(bytes[i + 3])
            i += 4
            out.append(contentsOf: start)
            out.append(bytes + i, count: n)
            i += n
        }
        return out
    }

    func testAnnexBStreamDecodesIntoPicturesTheGpuCopies() throws {
        let frames = try annexBFrames(5)
        XCTAssertGreaterThanOrEqual(frames.count, 3, "the encoder gave no frames")
        var decoded: [CVPixelBuffer] = []
        let dec = H264Decoder { decoded.append($0) }
        for f in frames {
            let ok = f.withUnsafeBytes { dec.decode($0.bindMemory(to: UInt8.self)) }
            XCTAssertTrue(ok)
        }
        XCTAssertEqual(decoded.count, frames.count)
        let first = try XCTUnwrap(decoded.first)
        XCTAssertEqual(CVPixelBufferGetWidth(first), 320)
        let (rgba, w, h) = try FrameConverter(stretchLevels: true).rgba(first)
        XCTAssertEqual(w, 320)
        XCTAssertEqual(h, 180)
        // top light, bottom dark, as encoded (lossy: roughly)
        XCTAssertGreaterThan(Int(rgba[(10 * w + 10) * 4]), 120)
        XCTAssertLessThan(Int(rgba[((h - 10) * w + 10) * 4]), 40)
    }

    func testVisionReadsTheGamesText() throws {
        // dark text on a light background, as the core gives its crops (BGRA)
        let w = 600, h = 120
        let img = UIGraphicsImageRenderer(size: CGSize(width: w, height: h), format: { let f = UIGraphicsImageRendererFormat(); f.scale = 1; return f }()).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ("MISSION PASSED" as NSString).draw(at: CGPoint(x: 20, y: 30), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 48), .foregroundColor: UIColor.black])
        }
        let (rgba, iw, ih) = try XCTUnwrap(Reader.rgba(of: img.cgImage!))
        // (RGBA → BGRA: grey, the order doesn't matter, but as the core would give it)
        var bgra = rgba
        for i in stride(from: 0, to: bgra.count, by: 4) { bgra.swapAt(i, i + 2) }
        let words = VisionRecognizer().recognize(bgra: bgra, width: UInt32(iw), height: UInt32(ih))
        XCTAssertEqual(words.map(\.text).joined(separator: " ").uppercased(), "MISSION PASSED")
        XCTAssertTrue(words.allSatisfy { $0.line == 0 })
        XCTAssertLessThan(words[0].x, words[1].x)
    }
}
