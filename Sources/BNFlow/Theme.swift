import AppKit
import SwiftUI
import CoreText

/// Business Native — dark (docs/tokens.json, businessnative-dark).
enum BN {
    static func rgb(_ hex: UInt32, _ a: Double = 1) -> Color {
        Color(.sRGB, red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255, blue: Double(hex & 0xff) / 255, opacity: a)
    }
    static func ns(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: a)
    }

    static let base = rgb(0x0a0a0b)
    static let lift = rgb(0x121212)
    static let lift80 = rgb(0x121212, 0.8)
    static let depth = rgb(0x212122)
    static let light = rgb(0xf6f3ec)
    static func light(_ a: Double) -> Color { rgb(0xf6f3ec, a) }
    static func dark(_ a: Double) -> Color { rgb(0x0a0a0b, a) }
    static let accent = rgb(0xc0c0e7)        // lavender, accent-primary
    static let tools = rgb(0xb9d5ed)         // accent-secondary-tools (parancs mód)
    static let warning = rgb(0xc56a21)       // instruct mód
    static let error = rgb(0xc94040)
    static let success = rgb(0x2ad87f)
    static let menuBorder = rgb(0x2b2b31)

    static let textStrong = light(0.88)
    static let textMedium = light(0.64)
    static let textWeak = light(0.48)
    static let border = light(0.16)
    static let inputBg = light(0.08)

    static let radius: CGFloat = 8
    static let radiusSmall: CGFloat = 4
    static let radiusLarge: CGFloat = 16

    /// cubic-bezier(0.22,1,0.36,1)
    static var ease: Animation { reduceMotion ? .linear(duration: 0) : .timingCurve(0.22, 1, 0.36, 1, duration: 0.35) }
    static var colorEase: Animation { reduceMotion ? .linear(duration: 0) : .easeInOut(duration: 0.18) }
    static var fade: Animation { reduceMotion ? .linear(duration: 0) : .easeOut(duration: 0.22) }
    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    // MARK: Betűk (Geist, OFL)
    enum W { case light, regular, medium, semibold }
    static func sans(_ size: CGFloat, _ w: W = .regular) -> Font {
        let name: String
        switch w { case .light: name = "Geist-Light"; case .regular: name = "Geist-Regular"; case .medium: name = "Geist-Medium"; case .semibold: name = "Geist-SemiBold" }
        return FontLoader.available ? .custom(name, fixedSize: size) : .system(size: size, weight: w == .medium ? .medium : w == .semibold ? .semibold : w == .light ? .light : .regular)
    }
    static func mono(_ size: CGFloat, _ w: W = .regular) -> Font {
        let name = w == .light ? "GeistMono-Light" : (w == .regular ? "GeistMono-Regular" : "GeistMono-Medium")
        return FontLoader.available ? .custom(name, fixedSize: size) : .system(size: size, design: .monospaced)
    }

    // Típusskála (tokens: typography.scaleDesktop)
    static let h4 = sans(32); static let h5 = sans(28); static let h6 = sans(24)
    static let body1 = sans(20); static let body2 = sans(16); static let body3 = sans(14)
    static let button1 = sans(14, .medium); static let button2 = sans(12, .medium)
    static let label1 = mono(12, .light); static let label2 = mono(10, .light)
}

enum FontLoader {
    static private(set) var available = false
    static func registerBundled() {
        let fm = FileManager.default
        var dirs: [URL] = []
        if let r = Bundle.main.resourceURL { dirs.append(r.appendingPathComponent("Fonts")) }
        // Fejlesztői futtatás (swift run): a repó Resources/Fonts mappája.
        dirs.append(URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("Resources/Fonts"))
        for d in dirs {
            guard let files = try? fm.contentsOfDirectory(at: d, includingPropertiesForKeys: nil) else { continue }
            for f in files where ["otf", "ttf"].contains(f.pathExtension.lowercased()) {
                CTFontManagerRegisterFontsForURL(f as CFURL, .process, nil)
            }
        }
        available = NSFont(name: "Geist-Regular", size: 12) != nil
    }
}

/// Felirat-stílus: nagybetűs mono label.
struct BNLabel: View {
    let text: String
    var size: CGFloat = 12
    var color: Color = BN.textMedium
    init(_ text: String, size: CGFloat = 12, color: Color = BN.textMedium) { self.text = text; self.size = size; self.color = color }
    var body: some View {
        Text(text.uppercased()).font(BN.mono(size, .light)).tracking(0.75).foregroundColor(color)
            .accessibilityLabel(text) // VoiceOver a normál írásmódot olvassa, ne betűzze a nagybetűs címkét
    }
}

struct BNButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, tertiary, danger }
    var kind: Kind = .secondary
    var compact = false
    func makeBody(configuration: Configuration) -> some View {
        Inner(configuration: configuration, kind: kind, compact: compact)
    }
    struct Inner: View {
        let configuration: ButtonStyleConfiguration
        let kind: Kind
        let compact: Bool
        @State private var hover = false
        @Environment(\.isEnabled) private var enabled
        func palette() -> (Color, Color, Color) {
            switch kind {
            case .primary: return (hover ? BN.light(0.88) : BN.light, BN.base, BN.dark(0.08))
            case .secondary: return (hover ? BN.light : BN.inputBg, hover ? BN.base : BN.light, BN.light(0.08))
            case .tertiary: return (.clear, hover ? BN.light(0.88) : BN.light, .clear)
            case .danger: return (hover ? BN.error.opacity(0.85) : BN.error.opacity(0.16), hover ? BN.light : BN.error, BN.error.opacity(0.4))
            }
        }
        var body: some View {
            let p = palette()
            configuration.label
                .font(compact ? BN.button2 : BN.button1)
                .padding(.vertical, compact ? 5 : 8).padding(.horizontal, compact ? 10 : 16)
                .foregroundColor(p.1)
                .background(RoundedRectangle(cornerRadius: BN.radius).fill(p.0))
                .overlay(RoundedRectangle(cornerRadius: BN.radius).strokeBorder(p.2, lineWidth: 1))
                .modifier(BNBevel(radius: BN.radius, enabled: kind == .secondary && !hover))
                .opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
                .contentShape(Rectangle())
                .onHover { h in withAnimation(.easeInOut(duration: 0.3)) { hover = h && enabled } }
        }
    }
}

/// Hairline bevel: `0 -1px 0 0 light-16, 0 1px 0 0 light-8` (felül világosabb, alul halványabb 1 px-es él).
struct BNBevel: ViewModifier {
    var radius: CGFloat = BN.radius
    var enabled = true
    func body(content: Content) -> some View {
        content.overlay(
            ZStack {
                RoundedRectangle(cornerRadius: radius).stroke(BN.light(0.16), lineWidth: 1)
                    .mask(VStack(spacing: 0) { Rectangle().frame(height: radius + 1); Spacer(minLength: 0) })
                    .offset(y: -1)
                RoundedRectangle(cornerRadius: radius).stroke(BN.light(0.08), lineWidth: 1)
                    .mask(VStack(spacing: 0) { Spacer(minLength: 0); Rectangle().frame(height: radius + 1) })
                    .offset(y: 1)
            }
            .opacity(enabled ? 1 : 0)
            .allowsHitTesting(false)
        )
    }
}

extension View {
    func bnBevel(radius: CGFloat = BN.radius) -> some View { modifier(BNBevel(radius: radius)) }
}

/// Input: light-8 háttér és keret; fókuszban light-16 háttér, light-48 keret, #f6f3ec szöveg.
struct BNTextFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        BNFieldChrome { configuration.textFieldStyle(.plain) }
    }
}

struct BNFieldChrome<Content: View>: View {
    @ViewBuilder var content: Content
    @FocusState private var focused: Bool
    var body: some View {
        content
            .focused($focused)
            .font(BN.body3)
            .foregroundColor(focused ? BN.light : BN.textStrong)
            .padding(.vertical, 7).padding(.horizontal, 10)
            .background(RoundedRectangle(cornerRadius: BN.radius).fill(focused ? BN.light(0.16) : BN.inputBg))
            .overlay(RoundedRectangle(cornerRadius: BN.radius).strokeBorder(focused ? BN.light(0.48) : BN.light(0.08), lineWidth: 1))
            .animation(BN.colorEase, value: focused)
    }
}

/// Kártya: #121212, 1 px light-16 keret, radius 16, belső margó 24, hairline bevel; hoverkor #c0c0e7 keret (250 ms).
struct BNCard<Content: View>: View {
    var padding: CGFloat = 24
    var hoverable = true
    @ViewBuilder var content: Content
    @State private var hover = false
    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: BN.radiusLarge).fill(BN.lift))
            .overlay(RoundedRectangle(cornerRadius: BN.radiusLarge).strokeBorder(hover && hoverable ? BN.accent : BN.border, lineWidth: 1))
            .bnBevel(radius: BN.radiusLarge)
            .onHover { h in withAnimation(BN.reduceMotion ? nil : .easeInOut(duration: 0.25)) { hover = h } }
    }
}

struct BNToggle: View {
    let title: String
    var detail: String? = nil
    @Binding var isOn: Bool
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(BN.body3).foregroundColor(BN.light)
                if let detail { Text(detail).font(BN.sans(12)).foregroundColor(BN.textMedium).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer()
            BNSwitch(isOn: $isOn, label: title)
        }
        .padding(.vertical, 6)
    }
}

/// Kapcsoló: kikapcsolva light-16, bekapcsolva #c0c0e7, a gomb mindig #f6f3ec, 180 ms. Gomb, így billentyűzettel
/// és kisegítő technológiával (AX „press”) is kapcsolható.
struct BNSwitch: View {
    @Binding var isOn: Bool
    var label: String = ""
    var body: some View {
        Button { withAnimation(BN.reduceMotion ? nil : .easeInOut(duration: 0.18)) { isOn.toggle() } } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                RoundedRectangle(cornerRadius: 6).fill(isOn ? BN.accent : BN.light(0.16)).frame(width: 34, height: 20)
                RoundedRectangle(cornerRadius: 4).fill(BN.light).frame(width: 14, height: 14).padding(3)
                    .shadow(color: BN.dark(0.24), radius: 1, y: 0.5)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? "be" : "ki")
    }
}

/// Görgetősáv a tokenek szerint (thumb #232327, radius 3): a SwiftUI ScrollView alá tett NSScrollView szkrollerét cseréli.
struct BNScrollerStyler: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ nsView: NSView, context: Context) {}
    final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in
                guard let sv = self?.enclosingScrollView else { return }
                if !(sv.verticalScroller is BNScroller) {
                    let sc = BNScroller(); sc.scrollerStyle = .overlay
                    sv.verticalScroller = sc
                }
                sv.scrollerStyle = .overlay
            }
        }
    }
}

final class BNScroller: NSScroller {
    override class var isCompatibleWithOverlayScrollers: Bool { true }
    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}
    override func drawKnob() {
        let r = rect(for: .knob).insetBy(dx: 3, dy: 2)
        guard r.width > 0, r.height > 0 else { return }
        BN.ns(0x232327).setFill()
        NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3).fill()
    }
}

extension View {
    /// ScrollView tartalmára téve a görgetősávot BN-stílusúra cseréli.
    func bnScroller() -> some View { background(BNScrollerStyler().frame(width: 0, height: 0)) }
}

struct BNDivider: View {
    var body: some View { Rectangle().fill(BN.light(0.08)).frame(height: 1) }
}

/// Tartalom-megjelenés: „rise” 28 px-ről, 750 ms, BN easing, 80 ms-os lépcsővel (csökkentett mozgásnál nincs).
struct BNRise: ViewModifier {
    var index: Int = 0
    @State private var shown = false
    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 28)
            .onAppear {
                if BN.reduceMotion || TestMode.staticUI { shown = true; return }
                withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.75).delay(Double(index) * 0.08)) { shown = true }
            }
    }
}

extension View {
    func bnRise(_ index: Int = 0) -> some View { modifier(BNRise(index: index)) }
}
