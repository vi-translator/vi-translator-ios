import CoreGraphics
import Foundation
import Vision

/**
 * Apple's Vision text recognition (on the phone, Latin script), in place of the Android app's ML
 * Kit: called synchronously by the core, several times per area and frame, with a grey crop (BGRA).
 * The words come back with the line they are in (top to bottom), in pixels of the crop.
 */
final class VisionRecognizer: TextRecognizer, @unchecked Sendable {
    /** .accurate reads the game's small, styled text far better than .fast */
    var level: VNRequestTextRecognitionLevel = .accurate

    func recognize(bgra: Data, width: UInt32, height: UInt32) -> [OcrWord] {
        let w = Int(width), h = Int(height)
        guard w > 0, h > 0, bgra.count >= w * h * 4, let image = Self.image(bgra, w, h) else { return [] }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = level
        request.recognitionLanguages = ["en-US"]
        // (the game's words are read as they are: names, slang and numbers aren't "corrected")
        request.usesLanguageCorrection = false
        if #available(iOS 16.0, *) {
            request.revision = VNRecognizeTextRequestRevision3
            request.automaticallyDetectsLanguage = false
        }
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        do {
            try handler.perform([request])
        } catch {
            NSLog("Vision text recognition failed: \(error)")
            return []
        }
        return Self.words(of: request.results ?? [], width: w, height: h)
    }

    // (0: the core's default, 2600 px)
    func maxDimension() -> UInt32 { 0 }

    /** The BGRA bytes as an image (no copy of the pixels' order: grey, so it doesn't matter). */
    static func image(_ bgra: Data, _ w: Int, _ h: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: bgra as CFData) else { return nil }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info, provider: provider,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /**
     * Vision's lines as words: each observation is a line (sorted top to bottom, then left to
     * right); its words are the runs between spaces, each with its own box. Vision's boxes are
     * fractions with the origin at the bottom left: here pixels from the top left.
     */
    static func words(of lines: [VNRecognizedTextObservation], width w: Int, height h: Int) -> [OcrWord] {
        let sorted = lines.sorted { a, b in
            let ta = 1 - a.boundingBox.maxY, tb = 1 - b.boundingBox.maxY
            if abs(ta - tb) > 0.02 { return ta < tb }
            return a.boundingBox.minX < b.boundingBox.minX
        }
        var out: [OcrWord] = []
        for (i, obs) in sorted.enumerated() {
            guard let best = obs.topCandidates(1).first else { continue }
            let s = best.string
            for range in wordRanges(s) {
                let box = (try? best.boundingBox(for: range))?.boundingBox ?? obs.boundingBox
                let r = pixels(box, w, h)
                out.append(OcrWord(line: UInt32(i), text: String(s[range]), x: Double(r.minX), y: Double(r.minY), w: Double(r.width), h: Double(r.height)))
            }
        }
        return out
    }

    /** The words of [s]: its runs of characters between spaces. */
    static func wordRanges(_ s: String) -> [Range<String.Index>] {
        var out: [Range<String.Index>] = []
        var start: String.Index? = nil
        var i = s.startIndex
        while i < s.endIndex {
            if s[i].isWhitespace {
                if let st = start { out.append(st..<i) }
                start = nil
            } else if start == nil {
                start = i
            }
            i = s.index(after: i)
        }
        if let st = start { out.append(st..<s.endIndex) }
        return out
    }

    /** A Vision box (fractions, origin bottom left) in pixels from the top left, inside the picture. */
    static func pixels(_ b: CGRect, _ w: Int, _ h: Int) -> CGRect {
        let x = max(0, b.minX) * CGFloat(w)
        let y = max(0, 1 - b.maxY) * CGFloat(h)
        let rw = min(b.width * CGFloat(w), CGFloat(w) - x)
        let rh = min(b.height * CGFloat(h), CGFloat(h) - y)
        return CGRect(x: x.rounded(), y: y.rounded(), width: max(1, rw.rounded()), height: max(1, rh.rounded()))
    }
}
