import SwiftUI
import UIKit

/**
 * The game picture (16:9), as the desktop's preview and the Android app's PreviewView: the read
 * areas drawn over it (dashed boxes in the accent colour, the selected one with its corner handle),
 * and the latest translation of each area where it would show. While the profile in use can be
 * changed, an area moves when dragged and resizes from its corner (stored as fractions).
 */
final class PreviewView: UIView {
    var cfg: Cfg?
    var picture: UIImage? { didSet { setNeedsDisplay() } }
    /** drawn over the video (VideoView): no background of its own */
    var clear = false {
        didSet {
            isOpaque = !clear
            backgroundColor = clear ? .clear : .black
            setNeedsDisplay()
        }
    }
    /** the latest translation of each area (area id -> text) */
    var shown: [String: String] = [:] { didSet { setNeedsDisplay() } }
    /** the sample text shown in every area when there is no translation (Show sample text) */
    var sample: String? { didSet { setNeedsDisplay() } }
    var selected: String? { didSet { setNeedsDisplay() } }
    var rtl = true
    /** draw the translations (off when the core's TV page draws them over this) */
    var drawText = true
    /** areas can be dragged (the Read areas tab) */
    var editable = false
    var moved: ((NSMutableDictionary) -> Void)?
    var tapped: ((String) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = true
        contentMode = .redraw
        backgroundColor = .black
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ rect: CGRect) {
        guard let c = UIGraphicsGetCurrentContext() else { return }
        if !clear {
            UIColor(red: 7 / 255, green: 5 / 255, blue: 11 / 255, alpha: 1).setFill()
            c.fill(bounds)
            picture?.draw(in: bounds)
        }
        guard let cfg else { return }
        let style = cfg.style()
        for a in cfg.areaList() {
            let r = rectOf(a)
            let sel = Cfg.s(a, "id") == selected
            let enabled = Cfg.b(a, "enabled", true)
            c.saveGState()
            c.setStrokeColor(Kit.accent.withAlphaComponent(enabled ? 1 : 0.35).cgColor)
            c.setLineWidth(sel ? 2.2 : 1.4)
            c.setLineDash(phase: 0, lengths: [5, 4])
            c.stroke(r)
            c.restoreGState()
            // its name, in a little tab above the box
            let name = Cfg.s(a, "name") as NSString
            name.draw(at: CGPoint(x: r.minX + 3, y: max(r.minY - 14, 0)),
                      withAttributes: [.font: UIFont.boldSystemFont(ofSize: 10), .foregroundColor: Kit.accent])
            if sel && editable && !cfg.locked() {
                Kit.accent.setFill()
                c.fillEllipse(in: CGRect(x: r.maxX - 7, y: r.maxY - 7, width: 14, height: 14))
            }
            let t = (drawText ? shown[Cfg.s(a, "id")] : nil) ?? sample
            if let t, !t.isEmpty, enabled { drawTranslation(c, t, a, Cfg.styleOf(a, style), r) }
        }
    }

    /** The translation in the area's text style, scaled from 1080p to this preview. */
    private func drawTranslation(_ c: CGContext, _ s: String, _ a: NSDictionary, _ st: NSDictionary, _ area: CGRect) {
        let h = bounds.height, w = bounds.width
        let scale = h / 1080
        let size = max(CGFloat(Cfg.d(st, "font_size", 26) * Cfg.d(a, "font_scale", 1)) * scale, 7)
        var family = Cfg.s(a, "font_family")
        if family.isEmpty { family = Cfg.s(st, "font_family") }
        let font = Fonts.ui(family, size: size, bold: Cfg.b(st, "bold"))
        let color = Kit.parse(Cfg.s(st, "text_color", "#ffffff"))
        let pad = CGFloat(Cfg.d(st, "padding", 10)) * scale
        // (where the translation goes: its custom region, else over the area)
        let out = Cfg.s(a, "placement") == "custom"
            ? CGRect(x: Cfg.d(a, "out_x") * w, y: Cfg.d(a, "out_y") * h, width: Cfg.d(a, "out_w") * w, height: Cfg.d(a, "out_h") * h)
            : area
        let tw = max(out.width - 2 * pad, 20)
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.baseWritingDirection = rtl ? .rightToLeft : .leftToRight
        para.lineHeightMultiple = CGFloat(min(max(Cfg.d(st, "line_height", 1.5), 1), 2.2) * 0.8)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: para]
        let text = NSAttributedString(string: s, attributes: attrs)
        let box = text.boundingRect(with: CGSize(width: tw, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        let th = ceil(box.height), lw = min(ceil(box.width), tw)
        let top: CGFloat
        switch Cfg.s(a, "out_valign", "bottom") {
        case "top": top = out.minY
        case "middle": top = out.midY - th / 2 - pad
        default: top = out.maxY - th - 2 * pad
        }
        let bg = Cfg.s(a, "background")
        if bg != "none" {
            let alpha = bg == "game" ? 0.7 : Cfg.d(st, "bg_opacity", 0.65)
            Kit.parse(Cfg.s(st, "bg_color", "#000000")).withAlphaComponent(CGFloat(min(max(alpha, 0), 1))).setFill()
            let r = CGFloat(Cfg.d(st, "radius", 10)) * scale
            UIBezierPath(roundedRect: CGRect(x: out.midX - lw / 2 - pad, y: top, width: lw + 2 * pad, height: th + 2 * pad), cornerRadius: r).fill()
        }
        let textRect = CGRect(x: out.midX - tw / 2, y: top + pad, width: tw, height: th)
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

    // ---- dragging an area (move), or its corner (resize); a tap selects one. Gestures, so a drag
    //      on an area wins over the page's scrolling (and a drag elsewhere still scrolls)
    private var drag: NSMutableDictionary?
    private var resizing = false
    private var last = CGPoint.zero

    private lazy var pan: UIPanGestureRecognizer = {
        UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
    }()

    private lazy var tap = UITapGestureRecognizer(target: self, action: #selector(tappedAt(_:)))

    func installGestures() {
        addGestureRecognizer(pan)
        addGestureRecognizer(tap)
    }

    /** the area under [p]: the selected one's corner first, then the smallest under it */
    private func hit(_ p: CGPoint) -> (NSMutableDictionary, Bool)? {
        guard let cfg else { return nil }
        for a in cfg.areaList() where Cfg.s(a, "id") == selected && editable && !cfg.locked() {
            let r = rectOf(a)
            if hypot(p.x - r.maxX, p.y - r.maxY) < 22 { return (a, true) }
        }
        let a = cfg.areaList().filter { rectOf($0).contains(p) }.min { Cfg.d($0, "w") * Cfg.d($0, "h") < Cfg.d($1, "w") * Cfg.d($1, "h") }
        return a.map { ($0, false) }
    }

    @objc private func tappedAt(_ g: UITapGestureRecognizer) {
        guard let a = hit(g.location(in: self))?.0 else { return }
        selected = Cfg.s(a, "id")
        tapped?(Cfg.s(a, "id"))
    }

    @objc private func panned(_ g: UIPanGestureRecognizer) {
        let p = g.location(in: self)
        switch g.state {
        case .began:
            guard let found = hit(p) else { return }
            drag = found.0
            resizing = found.1
            last = p
        case .changed:
            guard let a = drag else { return }
            let dx = Double((p.x - last.x) / bounds.width), dy = Double((p.y - last.y) / bounds.height)
            last = p
            func round4(_ v: Double) -> Double { (v * 10000).rounded() / 10000 }
            if resizing {
                a["w"] = round4(min(max(Cfg.d(a, "w") + dx, 0.02), 1 - Cfg.d(a, "x")))
                a["h"] = round4(min(max(Cfg.d(a, "h") + dy, 0.02), 1 - Cfg.d(a, "y")))
            } else {
                a["x"] = round4(min(max(Cfg.d(a, "x") + dx, 0), 1 - Cfg.d(a, "w")))
                a["y"] = round4(min(max(Cfg.d(a, "y") + dy, 0), 1 - Cfg.d(a, "h")))
            }
            setNeedsDisplay()
        default:
            if let a = drag { moved?(a) }
            drag = nil
        }
    }

    override func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        guard g === pan else { return true }
        // (only the selected area moves, and only when the profile can be changed)
        guard editable, let cfg, !cfg.locked(), let a = hit(g.location(in: self))?.0 else { return false }
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
    var editable = false
    /** (the settings' revision: drawn again when they change) */
    var rev = 0
    var moved: ((NSMutableDictionary) -> Void)?
    var tapped: ((String) -> Void)?
    /** over the video (VideoView) */
    var clear = false

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
        v.editable = editable
        v.rtl = m.core?.language(m.cfg.str("target_lang", "ar"))?.rtl ?? true
        v.moved = moved
        v.tapped = tapped
        if v.clear != clear { v.clear = clear }
        v.setNeedsDisplay()
    }
}
