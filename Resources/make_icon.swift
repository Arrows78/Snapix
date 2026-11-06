// Usage: swift make_icon.swift <output.png>   (renders the 1024px app icon)
import AppKit

let size: CGFloat = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
let nsctx = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.current = nsctx
let ctx = nsctx.cgContext

let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let path = CGPath(roundedRect: body, cornerWidth: 184, cornerHeight: 184, transform: nil)

// Drop shadow under the tile.
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
ctx.setFillColor(NSColor.black.cgColor)
ctx.addPath(path); ctx.fillPath()
ctx.restoreGState()

// Gradient tile.
ctx.saveGState()
ctx.addPath(path); ctx.clip()
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let g = CGGradient(colorsSpace: space, colors: [NSColor(srgbRed: 0.50, green: 0.35, blue: 0.94, alpha: 1).cgColor,
                                                NSColor(srgbRed: 0.17, green: 0.69, blue: 0.74, alpha: 1).cgColor] as CFArray, locations: nil)!
ctx.drawLinearGradient(g, start: CGPoint(x: 100, y: 924), end: CGPoint(x: 924, y: 100), options: [])
// Soft top highlight.
let hl = CGGradient(colorsSpace: space, colors: [NSColor.white.withAlphaComponent(0.22).cgColor, NSColor.white.withAlphaComponent(0).cgColor] as CFArray, locations: nil)!
ctx.drawLinearGradient(hl, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 560), options: [])
ctx.restoreGState()

// Viewfinder corners.
ctx.setStrokeColor(NSColor.white.cgColor)
ctx.setLineWidth(46)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
let inner = body.insetBy(dx: 190, dy: 190)
let arm: CGFloat = 130
for (cx, cy, dx, dy) in [(inner.minX, inner.minY, 1.0, 1.0), (inner.maxX, inner.minY, -1.0, 1.0),
                         (inner.minX, inner.maxY, 1.0, -1.0), (inner.maxX, inner.maxY, -1.0, -1.0)] as [(CGFloat, CGFloat, CGFloat, CGFloat)] {
    ctx.move(to: CGPoint(x: cx + dx * arm, y: cy))
    ctx.addLine(to: CGPoint(x: cx, y: cy))
    ctx.addLine(to: CGPoint(x: cx, y: cy + dy * arm))
    ctx.strokePath()
}
// Centre dot.
ctx.setFillColor(NSColor.white.cgColor)
ctx.fillEllipse(in: CGRect(x: 512 - 62, y: 512 - 62, width: 124, height: 124))
NSGraphicsContext.restoreGraphicsState()

try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
