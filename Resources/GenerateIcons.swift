import Foundation
import AppKit

// Anvil's mark: the anvil silhouette, drawn rather than shipped as a binary asset so
// both appearances come from one description.
func drawIcon(size: CGFloat, dark: Bool) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else { img.unlockFocus(); return img }

    let s = size
    // macOS icons sit in a squircle with a margin, per the HIG grid.
    let inset = s * 0.10
    let rect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let corner = rect.width * 0.2237                     // Apple's continuous-corner ratio
    let bg = CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil)

    ctx.saveGState()
    ctx.addPath(bg); ctx.clip()
    let colors: [CGColor] = dark
        ? [NSColor(srgbRed: 0.14, green: 0.16, blue: 0.22, alpha: 1).cgColor,
           NSColor(srgbRed: 0.05, green: 0.06, blue: 0.09, alpha: 1).cgColor]
        : [NSColor(srgbRed: 0.98, green: 0.97, blue: 0.95, alpha: 1).cgColor,
           NSColor(srgbRed: 0.85, green: 0.86, blue: 0.90, alpha: 1).cgColor]
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: colors as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: rect.minX, y: rect.maxY),
                           end: CGPoint(x: rect.maxX, y: rect.minY), options: [])

    // A warm spark behind the anvil — the one hint of colour, brighter on dark.
    let spark = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
        NSColor(srgbRed: 1.0, green: 0.52, blue: 0.16, alpha: dark ? 0.55 : 0.35).cgColor,
        NSColor(srgbRed: 1.0, green: 0.52, blue: 0.16, alpha: 0.0).cgColor,
    ] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(spark,
                           startCenter: CGPoint(x: rect.midX, y: rect.midY - s * 0.06), startRadius: 0,
                           endCenter: CGPoint(x: rect.midX, y: rect.midY - s * 0.06), endRadius: s * 0.34,
                           options: [])
    ctx.restoreGState()

    // The anvil itself, built from the classic profile: horn, waist, splayed base.
    let a = CGMutablePath()
    let cx = rect.midX, w = rect.width
    let top = rect.midY + rect.height * 0.16
    let bodyH = rect.height * 0.13
    let faceL = cx - w * 0.29, faceR = cx + w * 0.24

    a.move(to: CGPoint(x: faceL, y: top))
    a.addLine(to: CGPoint(x: faceR, y: top))                                    // top face
    a.addCurve(to: CGPoint(x: cx + w * 0.40, y: top - bodyH * 0.55),            // horn
               control1: CGPoint(x: cx + w * 0.34, y: top),
               control2: CGPoint(x: cx + w * 0.40, y: top - bodyH * 0.15))
    a.addCurve(to: CGPoint(x: faceR - w * 0.02, y: top - bodyH),
               control1: CGPoint(x: cx + w * 0.36, y: top - bodyH * 0.9),
               control2: CGPoint(x: cx + w * 0.30, y: top - bodyH))
    a.addLine(to: CGPoint(x: faceL + w * 0.02, y: top - bodyH))
    a.addLine(to: CGPoint(x: faceL - w * 0.04, y: top))
    a.closeSubpath()

    // Waist and base.
    let waistTop = top - bodyH
    let waistBot = waistTop - rect.height * 0.17
    a.move(to: CGPoint(x: cx - w * 0.11, y: waistTop))
    a.addCurve(to: CGPoint(x: cx - w * 0.15, y: waistBot),
               control1: CGPoint(x: cx - w * 0.15, y: waistTop - rect.height * 0.07),
               control2: CGPoint(x: cx - w * 0.17, y: waistBot + rect.height * 0.05))
    a.addLine(to: CGPoint(x: cx + w * 0.15, y: waistBot))
    a.addCurve(to: CGPoint(x: cx + w * 0.11, y: waistTop),
               control1: CGPoint(x: cx + w * 0.17, y: waistBot + rect.height * 0.05),
               control2: CGPoint(x: cx + w * 0.15, y: waistTop - rect.height * 0.07))
    a.closeSubpath()

    let baseH = rect.height * 0.075
    a.addRoundedRect(in: CGRect(x: cx - w * 0.26, y: waistBot - baseH,
                                width: w * 0.52, height: baseH),
                     cornerWidth: baseH * 0.3, cornerHeight: baseH * 0.3)

    ctx.saveGState()
    ctx.addPath(bg); ctx.clip()
    // The silhouette inverts between appearances so it keeps contrast either way.
    ctx.setFillColor(dark ? NSColor(srgbRed: 0.93, green: 0.94, blue: 0.97, alpha: 1).cgColor
                          : NSColor(srgbRed: 0.13, green: 0.15, blue: 0.20, alpha: 1).cgColor)
    ctx.addPath(a)
    ctx.fillPath()
    ctx.restoreGState()

    img.unlockFocus()
    return img
}

func writePNG(_ image: NSImage, to url: URL, pixels: Int) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                              isPlanar: false, colorSpaceName: .deviceRGB,
                              bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for (name, dark) in [("light", false), ("dark", true)] {
    for px in [16, 32, 64, 128, 256, 512, 1024] {
        let img = drawIcon(size: CGFloat(px), dark: dark)
        writePNG(img, to: out.appendingPathComponent("icon_\(name)_\(px).png"), pixels: px)
    }
}
print("wrote icons to \(out.path)")
