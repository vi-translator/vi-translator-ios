import SwiftUI
import UIKit

/**
 * The game picture (16:9), as the desktop's preview. In Play it shows the picture and the latest
 * translation of each area, nothing else. In the Read areas tab ([showAreas]) it also shows each read
 * area (a yellow dashed box) and where its translation goes (its region: a blue dashed box, as the
 * desktop's "band"); while the profile in use can be changed, the selected area moves when dragged
 * and resizes from its corner, and so does its blue region (a preset place then becomes a custom one,
 * from where it was). All stored as fractions of the picture.
 */
final class PreviewView: UIView {
    var cfg: Cfg?
    var picture: UIImage? { didSet { setNeedsDisplay() } }
    /** the latest translation of each area (area id -> text) */
    var shown: [String: String] = [:] { didSet { setNeedsDisplay() } }
    /** the sample text shown in every area when there is no translation (Show sample text) */
    var sample: String? { didSet { setNeedsDisplay() } }
    var selected: String? { didSet { setNeedsDisplay() } }
    var rtl = true
    /** draw the translations (off when the core's TV page draws them over this) */
    var drawText = true
    /** the read areas and their translation regions (the Read areas tab); not in Play */
    var showAreas = false
    /** areas can be dragged (the Read areas tab, a profile that can be changed) */
    var editable = false
    var moved: ((NSMutableDictionary) -> Void)?
    var tapped: ((String) -> Void)?

    /** the desktop's band colour (#5db6e5) */
    static let blue = UIColor(red: 0x5d / 255, green: 0xb6 / 255, blue: 0xe5 / 255, alpha: 1)

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = true
        contentMode = .redraw
        backgroundColor = .black
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ rect: CGRect) {
        guard let c = UIGraphicsGetCurrentContext() else { return }
        UIColor(red: 7 / 255, green: 5 / 255, blue: 11 / 255, alpha: 1).setFill()
        c.fill(bounds)
        picture?.draw(in: bounds)
        guard let cfg else { return }
        let style = cfg.style()
        for a in cfg.areaList() {
            let id = Cfg.s(a, "id")
            let sel = id == selected
            let enabled = Cfg.b(a, "enabled", true)
            let band = bandOf(a)
            if showAreas {
                // the translation region (blue), under the read area
                c.saveGState()
                if sel {
                    Self.blue.withAlphaComponent(0.06).setFill()
                    c.fill(band)
                }
                c.setStrokeColor(Self.blue.withAlphaComponent(sel ? 1 : 0.45).cgColor)
                c.setLineWidth(sel ? 2 : 1.5)
                c.setLineDash(phase: 0, lengths: [5, 4])
                c.stroke(band.insetBy(dx: 0.75, dy: 0.75))
                c.restoreGState()
                if sel {
                    tag(L("Translation · {name}", ("name", Cfg.s(a, "name"))), at: band, color: Self.blue)
                    if editable && !cfg.locked() { handle(at: CGPoint(x: band.maxX, y: band.maxY), Self.blue) }
                }
                // the read area (yellow)
                let r = rectOf(a)
                c.saveGState()
                c.setStrokeColor(Kit.accent.withAlphaComponent(enabled ? 1 : 0.35).cgColor)
                c.setLineWidth(sel ? 2.2 : 1.4)
                c.setLineDash(phase: 0, lengths: [5, 4])
                c.stroke(r)
                c.restoreGState()
                (Cfg.s(a, "name") as NSString).draw(at: CGPoint(x: r.minX + 3, y: max(r.minY - 14, 0)),
                                                    withAttributes: [.font: UIFont.boldSystemFont(ofSize: 10), .foregroundColor: Kit.accent])
                if sel && editable && !cfg.locked() { handle(at: CGPoint(x: r.maxX, y: r.maxY), Kit.accent) }
            }
            let t = (drawText ? shown[id] : nil) ?? sample
            if let t, !t.isEmpty, enabled { drawTranslation(c, t, a, Cfg.styleOf(a, style), band) }
        }
    }

    private func handle(at p: CGPoint, _ color: UIColor) {
        color.setFill()
        UIBezierPath(ovalIn: CGRect(x: p.x - 7, y: p.y - 7, width: 14, height: 14)).fill()
    }

    /** a small label above the top right of [r] (the desktop's band tag) */
    private func tag(_ s: String, at r: CGRect, color: UIColor) {
        let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.boldSystemFont(ofSize: 10),
                                                    .foregroundColor: UIColor(red: 4 / 255, green: 18 / 255, blue: 28 / 255, alpha: 1)]
        let size = (s as NSString).size(withAttributes: attrs)
        let box = CGRect(x: max(r.maxX - size.width - 8, 0), y: max(r.minY - size.height - 6, 0), width: size.width + 8, height: size.height + 4)
        color.setFill()
        UIBezierPath(roundedRect: box, cornerRadius: 3).fill()
        (s as NSString).draw(at: CGPoint(x: box.minX + 4, y: box.minY + 2), withAttributes: attrs)
    }

    /** The translation in the area's text style, scaled from 1080p to this preview, placed in its region. */
    private func drawTranslation(_ c: CGContext, _ s: String, _ a: NSDictionary, _ st: NSDictionary, _ out: CGRect) {
        let h = bounds.height
        let scale = h / 1080
        let size = max(CGFloat(Cfg.d(st, "font_size", 26) * Cfg.d(a, "font_scale", 1)) * scale, 7)
        var family = Cfg.s(a, "font_family")
        if family.isEmpty { family = Cfg.s(st, "font_family") }
        let font = Fonts.ui(family, size: size, bold: Cfg.b(st, "bold"))
        let color = Kit.parse(Cfg.s(st, "text_color", "#ffffff"))
        let pad = CGFloat(Cfg.d(st, "padding", 10)) * scale
        let al = Self.alignOf(Cfg.s(a, "placement", "above"), a)
        let tw = max(out.width - 2 * pad, 20)
        let para = NSMutableParagraphStyle()
        para.alignment = al.h == "center" ? .center : (al.h == "right" ? .right : .left)
        para.baseWritingDirection = rtl ? .rightToLeft : .leftToRight
        para.lineHeightMultiple = CGFloat(min(max(Cfg.d(st, "line_height", 1.5), 1), 2.2) * 0.8)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: para]
        let text = NSAttributedString(string: s, attributes: attrs)
        let box = text.boundingRect(with: CGSize(width: tw, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        let th = ceil(box.height), lw = min(ceil(box.width), tw)
        let top: CGFloat
        switch al.v {
        case "top": top = out.minY
        case "middle": top = out.midY - th / 2 - pad
        default: top = out.maxY - th - 2 * pad
        }
        let left: CGFloat
        switch al.h {
        case "left": left = out.minX
        case "right": left = out.maxX - lw - 2 * pad
        default: left = out.midX - lw / 2 - pad
        }
        let bg = Cfg.s(a, "background")
        if bg != "none" {
            let alpha = bg == "game" ? 0.7 : Cfg.d(st, "bg_opacity", 0.65)
            Kit.parse(Cfg.s(st, "bg_color", "#000000")).withAlphaComponent(CGFloat(min(max(alpha, 0), 1))).setFill()
            let r = CGFloat(Cfg.d(st, "radius", 10)) * scale
            UIBezierPath(roundedRect: CGRect(x: left, y: top, width: lw + 2 * pad, height: th + 2 * pad), cornerRadius: r).fill()
        }
        let textRect = CGRect(x: out.minX + pad, y: top + pad, width: tw, height: th)
        let ow = CGFloat(Cfg.d(st, "outline_width", 0)) * scale
        if ow > 0 || bg == "none" {
            var o = attrs
            o[.strokeColor] = Kit.parse(Cfg.s(st, "outline_color", "#000000"))
            // (a positive stroke width draws the outline only; it is in % of the font size)
            o[.strokeWidth] = max(ow * 2, bg == "none" ? 2 * scale + 1 : 0) / size * 100
            NSAttributedString(string: s, attributes: o).draw(with: textRect, options: [.usesLineFragmentOrigin], context: nil)
        }
        text.draw(with: textRect, options: [.usesLineFragmentOrigin], context: nil)
    }

    func rectOf(_ a: NSDictionary) -> CGRect {
        let w = bounds.width, h = bounds.height
        return CGRect(x: Cfg.d(a, "x") * w, y: Cfg.d(a, "y") * h, width: Cfg.d(a, "w") * w, height: Cfg.d(a, "h") * h)
    }

    /** The area's translation region in this view (the desktop's rectFor, at this size). */
    func bandOf(_ a: NSDictionary) -> CGRect {
        Self.rectFor(Cfg.s(a, "placement", "above"), rectOf(a), bounds.width, bounds.height, a)
    }

    /**
     * Where a translation goes, as the desktop's common.js rectFor: [a] the read area in pixels of a
     * [cw] x [ch] picture; a custom region is the area's out_* fractions.
     */
    static func rectFor(_ placement: String, _ a: CGRect, _ cw: CGFloat, _ ch: CGFloat, _ area: NSDictionary) -> CGRect {
        func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat { min(max(v, lo), hi) }
        if placement == "custom" {
            let w = clamp(Cfg.d(area, "out_w") * cw, 20, cw)
            let h = clamp(Cfg.d(area, "out_h") * ch, 20, ch)
            return CGRect(x: clamp(Cfg.d(area, "out_x") * cw, 0, cw - w), y: clamp(Cfg.d(area, "out_y") * ch, 0, ch - h), width: w, height: h)
        }
        if placement == "under_text" || placement == "above_text" {
            let h = min(a.height + floor(ch * 0.4), ch)
            let w = min(max(a.width, 50), cw)
            let y = placement == "under_text" ? a.minY : a.minY + a.height - h
            return CGRect(x: clamp(a.minX, 0, cw - w), y: clamp(y, 0, ch - h), width: w, height: h)
        }
        let band = floor(ch * 0.4), side = floor(cw * 0.35)
        let r: (CGFloat, CGFloat, CGFloat, CGFloat)
        switch placement {
        case "below": r = (a.minX, a.maxY, a.width, band)
        case "right": r = (a.maxX, a.minY, side, band)
        case "left": r = (a.minX - side, a.minY, side, band)
        case "over": r = (a.minX, a.maxY - band, a.width, band)
        default: r = (a.minX, a.minY - band, a.width, band)
        }
        let w = clamp(r.2, 50, cw), h = clamp(r.3, 50, ch)
        return CGRect(x: clamp(r.0, 0, cw - w), y: clamp(r.1, 0, ch - h), width: w, height: h)
    }

    /** Where the text sits in its region (the desktop's alignOf): v top|middle|bottom, h left|center|right. */
    static func alignOf(_ placement: String, _ area: NSDictionary) -> (v: String, h: String) {
        if placement == "under_text" { return ("top", "left") }
        if placement == "above_text" { return ("bottom", "center") }
        if placement == "custom" {
            let v = Cfg.s(area, "out_valign"), h = Cfg.s(area, "out_halign")
            return (v.isEmpty ? "bottom" : v, h.isEmpty ? "center" : h)
        }
        let tp = Cfg.s(area, "text_pos").split(separator: "-").map(String.init)
        if tp.count == 2 { return (tp[0], tp[1]) }
        return (placement == "above" || placement == "over" ? "bottom" : "top",
                placement == "right" ? "left" : placement == "left" ? "right" : "center")
    }

    /** A preset place becomes a custom region where it is now (the desktop's toCustom), so it can be dragged. */
    static func toCustom(_ a: NSMutableDictionary) {
        let placement = Cfg.s(a, "placement", "above")
        guard placement != "custom" else { return }
        let W: CGFloat = 1920, H: CGFloat = 1080
        let px = CGRect(x: Cfg.d(a, "x") * W, y: Cfg.d(a, "y") * H, width: Cfg.d(a, "w") * W, height: Cfg.d(a, "h") * H)
        let r = rectFor(placement, px, W, H, a)
        let al = alignOf(placement, a)
        func round4(_ v: CGFloat) -> Double { (Double(v) * 10000).rounded() / 10000 }
        a["out_x"] = round4(r.minX / W)
        a["out_y"] = round4(r.minY / H)
        a["out_w"] = round4(r.width / W)
        a["out_h"] = round4(r.height / H)
        a["out_valign"] = al.v
        a["out_halign"] = al.h
        a["placement"] = "custom"
    }

    // ---- dragging (the Read areas tab): the selected area or its region moves, their corners resize;
    //      a tap selects an area. Gestures, so a drag on an area wins over the page's scrolling.
    private enum Part { case area, areaCorner, band, bandCorner }
    private var dragArea: NSMutableDictionary?
    private var dragPart = Part.area
    private var last = CGPoint.zero

    private lazy var pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
    private lazy var tap = UITapGestureRecognizer(target: self, action: #selector(tappedAt(_:)))

    func installGestures() {
        addGestureRecognizer(pan)
        addGestureRecognizer(tap)
    }

    /** What is under [p]: the selected area's corners and region first, then the smallest area under it. */
    private func hit(_ p: CGPoint) -> (area: NSMutableDictionary, part: Part)? {
        guard let cfg, showAreas else { return nil }
        if editable, !cfg.locked(), let a = cfg.areaList().first(where: { Cfg.s($0, "id") == selected }) {
            let r = rectOf(a), b = bandOf(a)
            if hypot(p.x - r.maxX, p.y - r.maxY) < 22 { return (a, .areaCorner) }
            if hypot(p.x - b.maxX, p.y - b.maxY) < 22 { return (a, .bandCorner) }
            if r.contains(p) { return (a, .area) }
            if b.contains(p) { return (a, .band) }
        }
        let a = cfg.areaList().filter { rectOf($0).contains(p) }.min { Cfg.d($0, "w") * Cfg.d($0, "h") < Cfg.d($1, "w") * Cfg.d($1, "h") }
        return a.map { ($0, .area) }
    }

    @objc private func tappedAt(_ g: UITapGestureRecognizer) {
        guard let a = hit(g.location(in: self))?.area else { return }
        selected = Cfg.s(a, "id")
        tapped?(Cfg.s(a, "id"))
    }

    @objc private func panned(_ g: UIPanGestureRecognizer) {
        let p = g.location(in: self)
        switch g.state {
        case .began:
            guard let found = hit(p) else { return }
            dragArea = found.area
            dragPart = found.part
            last = p
            if found.part == .band || found.part == .bandCorner { Self.toCustom(found.area) }
        case .changed:
            guard let a = dragArea else { return }
            let dx = Double((p.x - last.x) / bounds.width), dy = Double((p.y - last.y) / bounds.height)
            last = p
            func round4(_ v: Double) -> Double { (v * 10000).rounded() / 10000 }
            let out = dragPart == .band || dragPart == .bandCorner
            let kx = out ? "out_x" : "x", ky = out ? "out_y" : "y", kw = out ? "out_w" : "w", kh = out ? "out_h" : "h"
            if dragPart == .areaCorner || dragPart == .bandCorner {
                a[kw] = round4(min(max(Cfg.d(a, kw) + dx, 0.02), 1 - Cfg.d(a, kx)))
                a[kh] = round4(min(max(Cfg.d(a, kh) + dy, 0.02), 1 - Cfg.d(a, ky)))
            } else {
                a[kx] = round4(min(max(Cfg.d(a, kx) + dx, 0), 1 - Cfg.d(a, kw)))
                a[ky] = round4(min(max(Cfg.d(a, ky) + dy, 0), 1 - Cfg.d(a, kh)))
            }
            setNeedsDisplay()
        default:
            if let a = dragArea { moved?(a) }
            dragArea = nil
        }
    }

    override func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        guard g === pan else { return true }
        // (only the selected area and its region move, and only when the profile can be changed)
        guard editable, let cfg, !cfg.locked(), let a = hit(g.location(in: self))?.area else { return false }
        return Cfg.s(a, "id") == selected
    }
}

/** The preview in SwiftUI: the picture, and the latest translation of each area from [lines]. */
struct PreviewRepresentable: UIViewRepresentable {
    @EnvironmentObject var m: AppModel
    let image: UIImage?
    let lines: [RecentLine]
    var drawText = true
    var sample: String?
    var selected: String?
    /** the read areas and their translation regions (the Read areas tab only) */
    var showAreas = false
    var editable = false
    /** (the settings' revision: drawn again when they change) */
    var rev = 0
    var moved: ((NSMutableDictionary) -> Void)?
    var tapped: ((String) -> Void)?

    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.installGestures()
        return v
    }

    func updateUIView(_ v: PreviewView, context: Context) {
        v.cfg = m.cfg
        v.picture = image
        var shown: [String: String] = [:]
        for l in lines where !l.text.isEmpty { shown[l.area] = l.text }
        v.shown = shown
        v.drawText = drawText
        v.sample = sample
        v.selected = selected
        v.showAreas = showAreas
        v.editable = editable
        v.rtl = m.core?.language(m.cfg.str("target_lang", "ar"))?.rtl ?? true
        v.moved = moved
        v.tapped = tapped
        v.setNeedsDisplay()
    }
}
