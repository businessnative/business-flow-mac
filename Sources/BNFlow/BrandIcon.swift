import AppKit
import SwiftUI

/// A Business Native pontmátrix-nyíl (10 kör, viewBox 15×13, r=1.1) — saját rajzolás a BN wordmark geometriájából.
enum BrandIcon {
    static let circles: [CGPoint] = [
        CGPoint(x: 1.4, y: 1.4), CGPoint(x: 1.4, y: 4.6), CGPoint(x: 1.4, y: 7.8), CGPoint(x: 1.4, y: 11),
        CGPoint(x: 5.4, y: 3), CGPoint(x: 5.4, y: 6.2), CGPoint(x: 5.4, y: 9.4),
        CGPoint(x: 9.4, y: 4.6), CGPoint(x: 9.4, y: 7.8), CGPoint(x: 13.4, y: 6.2),
    ]
    static let viewBox = CGSize(width: 15, height: 13)

    /// Menüsor-ikon (template: a rendszer színezi).
    static func menuBarImage(recording: Bool = false) -> NSImage {
        let size = NSSize(width: 18, height: 16)
        let img = NSImage(size: size, flipped: true) { rect in
            let s = min(rect.width / viewBox.width, rect.height / viewBox.height)
            let ox = (rect.width - viewBox.width * s) / 2, oy = (rect.height - viewBox.height * s) / 2
            NSColor.black.setFill()
            for (i, c) in circles.enumerated() {
                let r: CGFloat = 1.1 * s * (recording && i == circles.count - 1 ? 1.35 : 1)
                NSBezierPath(ovalIn: CGRect(x: ox + c.x * s - r, y: oy + c.y * s - r, width: r * 2, height: r * 2)).fill()
            }
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = "Business Flow"
        return img
    }
}

struct BrandArrow: View {
    var color: Color = BN.light
    var body: some View {
        Canvas { ctx, size in
            let s = min(size.width / BrandIcon.viewBox.width, size.height / BrandIcon.viewBox.height)
            let ox = (size.width - BrandIcon.viewBox.width * s) / 2, oy = (size.height - BrandIcon.viewBox.height * s) / 2
            for c in BrandIcon.circles {
                let r = 1.1 * s
                ctx.fill(Path(ellipseIn: CGRect(x: ox + c.x * s - r, y: oy + c.y * s - r, width: r * 2, height: r * 2)), with: .color(color))
            }
        }
    }
}

struct Wordmark: View {
    var body: some View {
        HStack(spacing: 6) {
            BrandArrow().frame(width: 15, height: 13)
            Text("business · native").font(BN.sans(14, .semibold)).tracking(-0.28).foregroundColor(BN.light)
        }
    }
}
