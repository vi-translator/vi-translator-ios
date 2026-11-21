import Photos
import SwiftUI
import UIKit

/** A snapshot the core made: its JSON (the picture, its text blocks and their translations). */
struct SnapResult: Identifiable {
    let id = UUID()
    let json: NSDictionary
    let info: String
    let style: String
}

/**
 * Snapshots: the game's whole picture with every bit of its text translated in place, like a
 * translated photo (the desktop's Snapshot). The core translates (takeSnapshot); this draws it as
 * the desktop's ui/snapshot.js and the Android app do (each block's English covered, blurred or a
 * solid colour, and its translation fitted into the block, the game's colours kept), shows it, and
 * keeps it in Photos when the settings say so.
 */
enum Snaps {
    private static let rtlLangs: Set<String> = ["ar", "ur", "fa"]

    /** Translate the last frame read; [done] gets the snapshot or an error (on the main thread). */
    static func take(_ m: AppModel, done: @escaping (Result<SnapResult, Error>) -> Void) {
        guard let frame = m.reader?.last, let core = m.core else {
            done(.failure(CoreFailure(L("No picture yet"))))
            return
        }
        let style = m.cfg.str("snap_style", "blur")
        let save = m.cfg.bool("snap_save", true)
        m.io.async {
            do {
                let snap = Cfg.parse(try core.takeSnapshot(frame.0, width: frame.1, height: frame.2))
                let r = SnapResult(json: snap, info: info(snap), style: style)
                let blocks = (snap["blocks"] as? NSArray)?.count ?? 0
                if save && Cfg.s(snap, "translated_image").isEmpty && blocks > 0, let img = draw(snap, translated: true, style: style) {
                    keep(img)
                }
                DispatchQueue.main.async { done(.success(r)) }
            } catch {
                DispatchQueue.main.async { done(.failure(error)) }
            }
        }
    }

    static func info(_ snap: NSDictionary) -> String {
        let blocks = (snap["blocks"] as? NSArray)?.count ?? 0
        let s = String(format: "%.1f", Cfg.d(snap, "ms") / 1000)
        let service = TranslatorPanel.engineName(Cfg.s(snap, "service"))
        if !Cfg.s(snap, "translated_image").isEmpty { return L("Translated by {service} in {s} s", ("service", service), ("s", s)) }
        if blocks > 0 { return L("{n} text block(s) translated by {service} in {s} s", ("n", blocks), ("service", service), ("s", s)) }
        return L("No text found on the picture.")
    }

    /** Into Photos (iOS asks once to allow adding). */
    static func keep(_ img: UIImage) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { st in
            guard st == .authorized || st == .limited else { return }
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAsset(from: img)
            }, completionHandler: nil)
        }
    }

    private static func picture(_ dataUrl: String) -> UIImage? {
        guard let r = dataUrl.range(of: "base64,") else { return nil }
        guard let d = Data(base64Encoded: String(dataUrl[r.upperBound...]), options: .ignoreUnknownCharacters) else { return nil }
        return UIImage(data: d)
    }

    /** The snapshot drawn: translated (or the original picture), with [style] "blur" or "solid" behind the text. */
    static func draw(_ snap: NSDictionary, translated: Bool, style: String) -> UIImage? {
        let ti = Cfg.s(snap, "translated_image")
        guard let img = picture(translated && !ti.isEmpty ? ti : Cfg.s(snap, "image")) else { return nil }
        if !translated || !ti.isEmpty { return img }
        let w = img.size.width, h = img.size.height
        let rtl = rtlLangs.contains(Cfg.s(snap, "lang"))
        let blurred = style == "solid" ? nil : blur(img)
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = img.scale
        return UIGraphicsImageRenderer(size: img.size, format: fmt).image { ctx in
            let c = ctx.cgContext
            img.draw(at: .zero)
            for case let b as NSDictionary in (snap["blocks"] as? NSArray) ?? [] {
                let ws = words(b)
                guard !ws.isEmpty, let r = b["rect"] as? [NSNumber], r.count >= 4 else { continue }
                let lh = max(8, CGFloat(Cfg.d(b, "line_h", 0.03)) * h)
                let pad = max(3, lh * 0.28)
                let box = CGRect(x: CGFloat(r[0].doubleValue) * w - pad, y: CGFloat(r[1].doubleValue) * h - pad,
                                 width: CGFloat(r[2].doubleValue) * w + 2 * pad, height: CGFloat(r[3].doubleValue) * h + 2 * pad)
                let bg = Kit.parse(Cfg.s(b, "bg", "#000000"))
                c.saveGState()
                let path = UIBezierPath(roundedRect: box, cornerRadius: min(8, pad))
                path.addClip()
                if let blurred {
                    blurred.draw(in: CGRect(x: 0, y: 0, width: w, height: h))
                    bg.withAlphaComponent(0.82).setFill()
                } else {
                    bg.setFill()
                }
                path.fill()
                c.restoreGState()
                let inner = box.insetBy(dx: pad * 0.4, dy: pad * 0.3)
                guard let laid = layout(ws, inner, start: lh * 0.95) else { continue }
                let (lines, size) = laid
                let font = UIFont(name: "Tajawal-Bold", size: size) ?? .boldSystemFont(ofSize: size)
                let lineH = size * 1.28
                var y = inner.minY + (inner.height - CGFloat(lines.count) * lineH) / 2
                let space = (" " as NSString).size(withAttributes: [.font: font]).width
                for line in lines {
                    let lw = line.reduce(0) { $0 + ($1.0 as NSString).size(withAttributes: [.font: font]).width } + space * CGFloat(line.count - 1)
                    var x: CGFloat
                    if Cfg.s(b, "align") == "center" { x = inner.minX + (inner.width - lw) / 2 }
                    else if rtl && lines.count > 1 { x = inner.maxX - lw }
                    else { x = inner.minX }
                    // (right to left: the first word on the right)
                    for (word, color) in rtl ? line.reversed() : line {
                        let shadow = NSShadow()
                        shadow.shadowBlurRadius = size * 0.18
                        shadow.shadowColor = light(color) ? UIColor.black.withAlphaComponent(0.65) : UIColor.white.withAlphaComponent(0.55)
                        let a: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .shadow: shadow]
                        (word as NSString).draw(at: CGPoint(x: x, y: y + (lineH - font.lineHeight) / 2), withAttributes: a)
                        x += (word as NSString).size(withAttributes: [.font: font]).width + space
                    }
                    y += lineH
                }
            }
        }
    }

    /** A blurred copy of the whole picture: what shows through behind a block's text. */
    private static func blur(_ img: UIImage) -> UIImage? {
        let small = CGSize(width: max(1, img.size.width / 24), height: max(1, img.size.height / 24))
        let tiny = UIGraphicsImageRenderer(size: small).image { _ in img.draw(in: CGRect(origin: .zero, size: small)) }
        return UIGraphicsImageRenderer(size: img.size).image { ctx in
            ctx.cgContext.interpolationQuality = .high
            tiny.draw(in: CGRect(origin: .zero, size: img.size))
        }
    }

    /** A block's translation as words, each with its colour (the game's highlights kept; icons left out). */
    private static func words(_ b: NSDictionary) -> [(String, UIColor)] {
        var out: [(String, UIColor)] = []
        let fg = Kit.parse(Cfg.s(b, "fg", "#ffffff"))
        for case let s as NSArray in (b["segs"] as? NSArray) ?? [] {
            let t = s.count > 0 ? (s[0] as? String ?? "") : ""
            let c = s.count > 1 ? (s[1] as? String ?? "") : ""
            if c.hasPrefix("icon:") { continue }
            let color: UIColor
            if c.range(of: "^#[0-9a-fA-F]{6}$", options: .regularExpression) != nil { color = Kit.parse(c) }
            else if c.range(of: "^name:#[0-9a-fA-F]{6}$", options: .regularExpression) != nil { color = Kit.parse(String(c.dropFirst(5))) }
            else { color = fg }
            for w in t.split(whereSeparator: \.isWhitespace) { out.append((String(w), color)) }
        }
        return out
    }

    /** The biggest size at which the words wrap into the box (a little taller allowed). */
    private static func layout(_ words: [(String, UIColor)], _ box: CGRect, start: CGFloat) -> ([[(String, UIColor)]], CGFloat)? {
        var size = start
        while size >= 7 {
            let font = UIFont(name: "Tajawal-Bold", size: size) ?? .boldSystemFont(ofSize: size)
            let space = (" " as NSString).size(withAttributes: [.font: font]).width
            var lines: [[(String, UIColor)]] = []
            var line: [(String, UIColor)] = []
            var width: CGFloat = 0
            var fits = true
            for wd in words {
                let ww = (wd.0 as NSString).size(withAttributes: [.font: font]).width
                if !line.isEmpty && width + space + ww > box.width {
                    lines.append(line)
                    line = []
                    width = 0
                }
                if ww > box.width * 1.02 { fits = false }
                width += (line.isEmpty ? 0 : space) + ww
                line.append(wd)
            }
            if !line.isEmpty { lines.append(line) }
            if (fits && CGFloat(lines.count) * size * 1.28 <= box.height * 1.25) || size * 0.92 < 7 { return (lines, size) }
            size *= 0.92
        }
        return nil
    }

    private static func light(_ c: UIColor) -> Bool {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getRed(&r, green: &g, blue: &b, alpha: &a)
        return (0.299 * r + 0.587 * g + 0.114 * b) * 255 > 140
    }
}

/** Full screen: Translated / Original, Save, Close (the desktop's Snap.show). */
struct SnapView: View {
    @Environment(\.kit) var k
    @Environment(\.dismiss) var dismiss
    let snap: SnapResult
    @State private var translated = true
    @State private var image: UIImage?
    @State private var saved: String?

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.ignoresSafeArea()
            if let image {
                Image(uiImage: image).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView().tint(.white)
            }
            HStack(spacing: 8) {
                Text(saved ?? snap.info).font(k.font(k.base - 1.5)).foregroundColor(.white)
                Spacer(minLength: 4)
                KButton(translated ? L("Original") : L("Translated"), full: false) { translated.toggle() }
                KButton(L("Save"), primary: true, full: false) {
                    if let image {
                        Snaps.keep(image)
                        saved = L("Saved ✓")
                    }
                }
                KButton(L("Close"), full: false) { dismiss() }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Color.black.opacity(0.8))
        }
        .task(id: translated) {
            let s = snap, t = translated
            image = await Task.detached { Snaps.draw(s.json, translated: t, style: s.style) }.value
        }
    }
}
