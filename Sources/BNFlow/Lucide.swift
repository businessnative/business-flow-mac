import SwiftUI
import AppKit

/// Lucide ikon (ISC) a beágyazott útvonaladatokból: 24×24 viewBox, 1,5 px-es vonal, kerek végek és illesztések (a BN ikonstílusa).
struct LucideShape: Shape {
    let name: String
    func path(in rect: CGRect) -> Path {
        var p = Path()
        guard let d = LucideData.icons[name] else { return p }
        let s = min(rect.width, rect.height) / 24
        let ox = rect.minX + (rect.width - 24 * s) / 2, oy = rect.minY + (rect.height - 24 * s) / 2
        func pt(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: ox + CGFloat(x) * s, y: oy + CGFloat(y) * s) }
        var i = 0
        while i < d.count {
            switch Int(d[i]) {
            case 0: p.move(to: pt(d[i + 1], d[i + 2])); i += 3
            case 1: p.addLine(to: pt(d[i + 1], d[i + 2])); i += 3
            case 2: p.addCurve(to: pt(d[i + 5], d[i + 6]), control1: pt(d[i + 1], d[i + 2]), control2: pt(d[i + 3], d[i + 4])); i += 7
            default: p.closeSubpath(); i += 1
            }
        }
        return p
    }
}

struct LucideIcon: View {
    let name: String
    var size: CGFloat = 16
    var color: Color = BN.textMedium
    var lineWidth: CGFloat = 1.5
    init(_ name: String, size: CGFloat = 16, color: Color = BN.textMedium, lineWidth: CGFloat = 1.5) {
        self.name = name; self.size = size; self.color = color; self.lineWidth = lineWidth
    }
    var body: some View {
        LucideShape(name: name)
            .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
