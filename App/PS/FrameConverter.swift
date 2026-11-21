import CoreImage
import CoreVideo
import Foundation
import Metal

/**
 * The decoder's picture through the GPU, as the Android app's GlFrames: Core Image (on Metal) draws
 * the CVPixelBuffer, whatever format the decoder wrote, into a plain RGBA picture, top row first. The
 * CPU never reads the decoder's own buffers (on Android some decoders write a compressed layout that
 * crashed a CPU read; the GPU reads any).
 *
 * The YUV becomes RGB with the buffer's own matrix (BT.709 for the PS5's HD stream, limited range
 * to full). Then the studio levels are stretched once more (16–235 to 0–255), as on Android: the
 * PS5's Remote Play picture comes out with blacks at ~32 and whites at ~228 where its HDMI picture
 * has ~15 and ~248, and the game pages' colour checks are tuned on the HDMI picture (GTA VI's pause
 * menu isn't recognised without this).
 */
final class FrameConverter: @unchecked Sendable {
    private let context: CIContext
    /** stretch the studio levels (the PS5); off for pictures already full range */
    let stretchLevels: Bool

    init(stretchLevels: Bool = true) {
        self.stretchLevels = stretchLevels
        // (no colour management: the values stay as the stream has them, as the desktop reads them)
        let opts: [CIContextOption: Any] = [
            .workingColorSpace: NSNull(),
            .outputColorSpace: NSNull(),
            .cacheIntermediates: false,
        ]
        if let device = MTLCreateSystemDefaultDevice() {
            context = CIContext(mtlDevice: device, options: opts)
        } else {
            context = CIContext(options: opts)
        }
    }

    /** the studio levels' stretch: (c - 16/255) * 255/219 */
    static let gain = 255.0 / 219.0
    static let bias = -16.0 / 219.0

    /** The picture as RGBA bytes (width x height x 4, top row first). */
    func rgba(_ buffer: CVPixelBuffer) throws -> (Data, Int, Int) {
        let w = CVPixelBufferGetWidth(buffer)
        let h = CVPixelBufferGetHeight(buffer)
        // (an untagged buffer: the PS5's HD stream is BT.709)
        if CVBufferCopyAttachment(buffer, kCVImageBufferYCbCrMatrixKey, nil) == nil {
            CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        }
        var image = CIImage(cvPixelBuffer: buffer, options: [.colorSpace: NSNull()])
        if stretchLevels {
            let g = CGFloat(Self.gain), b = CGFloat(Self.bias)
            image = image.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: g, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: g, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: g, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
                "inputBiasVector": CIVector(x: b, y: b, z: b, w: 0),
            ]).applyingFilter("CIColorClamp")
        }
        var out = Data(count: w * h * 4)
        out.withUnsafeMutableBytes { (p: UnsafeMutableRawBufferPointer) in
            context.render(image, toBitmap: p.baseAddress!, rowBytes: w * 4,
                           bounds: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBA8, colorSpace: nil)
        }
        // (opaque: the alpha the decoder's YUV has none of)
        out.withUnsafeMutableBytes { (p: UnsafeMutableRawBufferPointer) in
            let px = p.bindMemory(to: UInt8.self)
            var i = 3
            while i < px.count {
                px[i] = 255
                i += 4
            }
        }
        return (out, w, h)
    }
}

/** A decoded frame: the CVPixelBuffer is only held, then drawn into RGBA on the reading thread. */
struct PixelBufferFrame: Frame {
    let buffer: CVPixelBuffer
    let converter: FrameConverter

    func snapshot() throws -> Snapshot { PixelSnapshot(buffer: buffer, converter: converter) }
}

private struct PixelSnapshot: Snapshot {
    let buffer: CVPixelBuffer
    let converter: FrameConverter
    var width: Int { CVPixelBufferGetWidth(buffer) }
    var height: Int { CVPixelBufferGetHeight(buffer) }

    func rgba() throws -> Data { try converter.rgba(buffer).0 }
}
