// Generálja az AppIcon.iconset PNG-ket: sötét BN alap (#0a0a0b), világos pontmátrix-nyíl (#f6f3ec), lila (#c0c0e7) csúcs.
// Használat: swift scripts/make-icon.swift <kimeneti .iconset mappa>
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
let circles: [CGPoint] = [
    CGPoint(x: 1.4, y: 1.4), CGPoint(x: 1.4, y: 4.6), CGPoint(x: 1.4, y: 7.8), CGPoint(x: 1.4, y: 11),
    CGPoint(x: 5.4, y: 3), CGPoint(x: 5.4, y: 6.2), CGPoint(x: 5.4, y: 9.4),
    CGPoint(x: 9.4, y: 4.6), CGPoint(x: 9.4, y: 7.8), CGPoint(x: 13.4, y: 6.2),
]
func color(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: 1)
}
func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let S = CGFloat(px)
    // macOS-ikonrács: 824/1024-es lekerekített négyzet középen.
    let inset = S * 100 / 1024
    let box = NSRect(x: inset, y: inset, width: S - 2 * inset, height: S - 2 * inset)
    let bg = NSBezierPath(roundedRect: box, xRadius: box.width * 0.225, yRadius: box.width * 0.225)
    color(0x0a0a0b).setFill(); bg.fill()
    color(0x2b2b31).setStroke(); bg.lineWidth = max(1, S / 256); bg.stroke()
    let vb = CGSize(width: 15, height: 13)
    let scale = box.width * 0.56 / vb.width
    let ox = box.midX - vb.width * scale / 2, oy = box.midY - vb.height * scale / 2
    for (i, c) in circles.enumerated() {
        let r = 1.1 * scale
        (i == circles.count - 1 ? color(0xc0c0e7) : color(0xf6f3ec)).setFill()
        // AppKit y lefelé nő a viewBoxban → tükrözés.
        let y = oy + (vb.height - c.y) * scale
        NSBezierPath(ovalIn: NSRect(x: ox + c.x * scale - r, y: y - r, width: 2 * r, height: 2 * r)).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}
for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                   ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! render(px).write(to: URL(fileURLWithPath: "\(out)/icon_\(name).png"))
}
print("ikonok: \(out)")
