import SwiftUI

/** The screens' parts, as the Android app's Kit builds them (the desktop's cards, callouts, fields). */

struct H3: View {
    @Environment(\.kit) var k
    let text: String
    init(_ t: String) { text = t }

    var body: some View {
        Text(text).font(k.font(k.base + 3, .bold)).foregroundColor(k.text)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 20).padding(.bottom, 6)
    }
}

struct Muted: View {
    @Environment(\.kit) var k
    let text: String
    var small = false
    init(_ t: String, small: Bool = false) {
        text = t
        self.small = small
    }

    var body: some View {
        Text(text).font(k.font(small ? k.base - 2 : k.base - 1)).foregroundColor(k.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct LabelText: View {
    @Environment(\.kit) var k
    let text: String
    init(_ t: String) { text = t }

    var body: some View {
        Text(text.uppercased()).font(k.font(k.base - 3.5, .bold)).foregroundColor(k.muted).tracking(0.6)
    }
}

/** A panel: the desktop's .card look. */
struct Card<Content: View>: View {
    @Environment(\.kit) var k
    var pad: CGFloat = 14
    var border: Color?
    var borderWidth: CGFloat = 1
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .padding(pad)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14).fill(k.panel))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(border ?? k.line, lineWidth: borderWidth))
    }
}

/** A note in a soft box (the desktop's .callout), in [color] when given. */
struct Callout: View {
    @Environment(\.kit) var k
    let text: String
    var color: Color?

    init(_ t: String, _ c: Color? = nil) {
        text = t
        color = c
    }

    var body: some View {
        Text(text).font(k.font(k.base - 1.5)).foregroundColor(color ?? k.text)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 10).fill((color ?? k.muted).opacity(0.1)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke((color ?? k.line).opacity(0.5), lineWidth: 1))
    }
}

struct Badge: View {
    @Environment(\.kit) var k
    let text: String
    var on = false

    init(_ t: String, on: Bool = false) {
        text = t
        self.on = on
    }

    var body: some View {
        Text(text).font(k.font(k.base - 3.5, .bold)).foregroundColor(on ? .white : k.muted)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(on ? AnyShapeStyle(Kit.sunset) : AnyShapeStyle(k.panel3)))
    }
}

/** The desktop's buttons: primary (the sunset), plain, or danger. */
struct KButton: View {
    @Environment(\.kit) var k
    @Environment(\.isEnabled) var enabled
    let title: String
    var icon: String?
    var primary = false
    var danger = false
    var full = true
    let action: () -> Void

    init(_ title: String, icon: String? = nil, primary: Bool = false, danger: Bool = false, full: Bool = true, action: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.primary = primary
        self.danger = danger
        self.full = full
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon { Image(systemName: icon).font(.system(size: 14, weight: .semibold)) }
                Text(title).font(k.font(k.base, .bold)).lineLimit(2).multilineTextAlignment(.center)
            }
            .foregroundColor(primary ? .white : (danger ? k.err : k.text))
            .padding(.horizontal, 14).padding(.vertical, 11)
            .frame(maxWidth: full ? .infinity : nil, minHeight: 44)
            .background(
                RoundedRectangle(cornerRadius: 9).fill(primary ? AnyShapeStyle(Kit.sunset) : AnyShapeStyle(k.panel2))
            )
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(primary ? Color.clear : (danger ? k.err.opacity(0.5) : k.line), lineWidth: 1))
            .opacity(enabled ? 1 : 0.45)
        }
        .buttonStyle(.plain)
    }
}

struct KLink: View {
    @Environment(\.kit) var k
    let title: String
    let action: () -> Void

    init(_ t: String, action: @escaping () -> Void) {
        title = t
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title).font(k.font(k.base - 1, .bold)).foregroundColor(k.accentUi)
                .padding(.vertical, 8)
        }.buttonStyle(.plain)
    }
}

/** A labelled control, with its help under it (the desktop's .field). */
struct Field<Content: View>: View {
    @Environment(\.kit) var k
    let label: String
    var help: String?
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(k.font(k.base - 1, .bold)).foregroundColor(k.text)
            content()
            if let help, !help.isEmpty { Muted(help, small: true) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 12)
    }
}

/** A choice from a list (a menu), showing the chosen one's words. Keys starting with "—" are group titles. */
struct Select: View {
    @Environment(\.kit) var k
    let options: [(String, String)]
    let value: String
    let changed: (String) -> Void

    var body: some View {
        Menu {
            ForEach(Array(options.enumerated()), id: \.offset) { _, o in
                if o.0.hasPrefix(Select.group) {
                    Divider()
                    Button(o.1) {}.disabled(true)
                } else {
                    Button {
                        changed(o.0)
                    } label: {
                        if o.0 == value { Label(o.1, systemImage: "checkmark") } else { Text(o.1) }
                    }
                }
            }
        } label: {
            HStack {
                Text(options.first { $0.0 == value }?.1 ?? value).font(k.font(k.base)).foregroundColor(k.text)
                    .lineLimit(2).multilineTextAlignment(.leading)
                Spacer(minLength: 8)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 12, weight: .semibold)).foregroundColor(k.muted)
            }
            .padding(.horizontal, 12).padding(.vertical, 11)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(RoundedRectangle(cornerRadius: 9).fill(k.panel2))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(k.line, lineWidth: 1))
        }
    }

    static let group = "—group:"
}

/** A switch with its words (the desktop's checkboxes). */
struct Check: View {
    @Environment(\.kit) var k
    let label: String
    let on: Bool
    var small = false
    let changed: (Bool) -> Void

    var body: some View {
        Toggle(isOn: Binding(get: { on }, set: { changed($0) })) {
            Text(label).font(k.font(small ? k.base - 1.5 : k.base)).foregroundColor(k.text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .tint(k.accentUi)
        .padding(.vertical, small ? 2 : 6)
    }
}

/** A slider with its value shown. */
struct KSlider: View {
    @Environment(\.kit) var k
    let range: ClosedRange<Double>
    let step: Double
    let value: Double
    let format: (Double) -> String
    let changed: (Double) -> Void
    @State private var v: Double?

    var body: some View {
        HStack(spacing: 12) {
            Slider(value: Binding(get: { v ?? value }, set: { v = $0 }), in: range, step: step) { editing in
                if !editing, let x = v { changed(x) }
            }
            .tint(k.accentUi)
            Text(format(v ?? value)).font(k.font(k.base - 1, .bold)).foregroundColor(k.text).frame(minWidth: 52, alignment: .trailing)
                .environment(\.layoutDirection, .leftToRight)
        }
        .onChange(of: value) { _ in v = nil }
    }
}

/** A text field, saved as it is typed. */
struct KInput: View {
    @Environment(\.kit) var k
    let value: String
    var placeholder = ""
    var secure = false
    var ltr = false
    var number = false
    let changed: (String) -> Void
    @State private var text: String?

    var body: some View {
        Group {
            if secure {
                SecureField(placeholder, text: binding)
            } else {
                TextField(placeholder, text: binding)
            }
        }
        .font(k.font(k.base))
        .foregroundColor(k.text)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .keyboardType(number ? .numberPad : .default)
        .multilineTextAlignment(ltr ? .leading : .leading)
        .environment(\.layoutDirection, ltr ? .leftToRight : (I18n.rtl ? .rightToLeft : .leftToRight))
        .padding(.horizontal, 12).padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: 9).fill(k.panel2))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(k.line, lineWidth: 1))
    }

    private var binding: Binding<String> {
        Binding(get: { text ?? value }, set: {
            text = $0
            changed($0)
        })
    }
}

/** A colour, from the system's colour picker, as "#rrggbb". */
struct ColorPick: View {
    let value: String
    let changed: (String) -> Void

    var body: some View {
        ColorPicker("", selection: Binding(get: { Color(Kit.parse(value)) }, set: { changed(Kit.hex(UIColor($0))) }), supportsOpacity: false)
            .labelsHidden()
    }
}

/** An icon in a soft square (the glance cards', the console choice's). */
struct IconTile: View {
    @Environment(\.kit) var k
    let name: String
    var color: Color?
    var size: CGFloat = 38

    var body: some View {
        Image(systemName: name).font(.system(size: size * 0.45, weight: .semibold)).foregroundColor(color ?? k.accentUi)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: 10).fill((color ?? k.accentUi).opacity(0.13)))
    }
}

/** The Android drawables' counterparts, in SF Symbols. */
enum Icon {
    static let source = "gamecontroller"
    static let tv = "tv"
    static let show = "tv.and.mediabox"
    static let snapshot = "camera.viewfinder"
    static let translator = "character.bubble"
    static let profile = "person.crop.square"
    static let areas = "rectangle.dashed"
    static let pages = "doc.richtext"
    static let setup = "slider.horizontal.3"
    static let play = "play.fill"
    static let globe = "globe"
    static let sun = "sun.max"
    static let moon = "moon"
    static let camera = "camera"
    static let fullscreen = "arrow.up.left.and.arrow.down.right"
    static let eyeOff = "eye.slash"
    static let check = "checkmark"
    static let lock = "lock.fill"
    static let trash = "trash"
    static let chevron = "chevron.right"
}

extension View {
    /** a soft pop-up's frame (the dialogs) */
    func sheetCard(_ k: Kit) -> some View {
        self.padding(18)
            .frame(maxWidth: 520)
            .background(k.bg.ignoresSafeArea())
    }
}
