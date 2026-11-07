import AppKit
import CoreImage

extension CGContext {
    /// Draws an image into a context whose origin is top-left (flipped).
    func drawFlipped(_ image: CGImage, in rect: CGRect) {
        saveGState()
        translateBy(x: rect.minX, y: rect.maxY)
        scaleBy(x: 1, y: -1)
        draw(image, in: CGRect(origin: .zero, size: rect.size))
        restoreGState()
    }
}

/// Draws a document. Every context handed to it uses a top-left origin and 1 unit = 1 image pixel.
enum Renderer {
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
    private static let ciContext = CIContext()
    private static var blurCache: [String: CGImage] = [:]
    private static var blurCacheOwner: UnsafeMutableRawPointer?

    /// Height of the title bar drawn above the screenshot when the backdrop's window frame is on.
    static func chromeHeight(_ s: DocState) -> CGFloat {
        guard s.backdrop.enabled, s.backdrop.windowFrame == true else { return 0 }
        return min(56, max(28, (CGFloat(s.image.width) * 0.035).rounded()))
    }

    static func canvasSize(_ s: DocState) -> CGSize {
        let p = s.backdrop.enabled ? s.backdrop.padding : 0
        var w = CGFloat(s.image.width) + 2 * p, h = CGFloat(s.image.height) + chromeHeight(s) + 2 * p
        if s.backdrop.enabled, let r = s.backdrop.ratio, r > 0 {
            // Grow the short side so the picture reaches the ratio; the screenshot never shrinks.
            if w / h < r { w = (h * r).rounded() } else { h = (w / r).rounded() }
        }
        return CGSize(width: w, height: h)
    }

    static func origin(_ s: DocState) -> CGPoint {
        guard s.backdrop.enabled else { return .zero }
        let size = canvasSize(s)
        let chrome = chromeHeight(s)
        return CGPoint(x: ((size.width - CGFloat(s.image.width)) / 2).rounded(),
                       y: ((size.height - CGFloat(s.image.height) - chrome) / 2).rounded() + chrome)
    }

    // MARK: Whole document

    static func draw(_ s: DocState, in ctx: CGContext, skipID: UUID? = nil) {
        let imgSize = CGSize(width: s.image.width, height: s.image.height)
        let o = origin(s)

        let chrome = chromeHeight(s)
        let block = CGRect(x: o.x, y: o.y - chrome, width: imgSize.width, height: imgSize.height + chrome)
        if s.backdrop.enabled { drawBackdrop(s, in: ctx, imageRect: block) }

        ctx.saveGState()
        ctx.translateBy(x: o.x, y: o.y)

        ctx.saveGState()
        if s.backdrop.enabled && s.backdrop.innerRadius > 0 {
            let r = s.backdrop.innerRadius
            ctx.addPath(CGPath(roundedRect: CGRect(x: 0, y: -chrome, width: imgSize.width, height: imgSize.height + chrome), cornerWidth: r, cornerHeight: r, transform: nil))
            ctx.clip()
        }
        if chrome > 0 { drawTitleBar(width: imgSize.width, height: chrome, in: ctx) }
        ctx.clip(to: CGRect(origin: .zero, size: imgSize))
        ctx.drawFlipped(s.image, in: CGRect(origin: .zero, size: imgSize))
        if let o = s.overlay {
            ctx.saveGState()
            ctx.setAlpha(o.opacity)
            ctx.drawFlipped(o.image, in: CGRect(origin: o.origin, size: o.size))
            ctx.restoreGState()
        }
        drawSpotlights(s.annotations.filter { $0.tool == .spotlight }, size: imgSize, in: ctx)
        ctx.restoreGState()

        for a in s.annotations where a.tool != .spotlight && a.id != skipID {
            draw(a, image: s.image, shadow: s.shadows, in: ctx)
        }
        ctx.restoreGState()
    }

    /// Flattens the document to a bitmap (backdrop included).
    static func render(_ s: DocState) -> CGImage? {
        let size = canvasSize(s)
        let w = Int(size.width), h = Int(size.height)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        draw(s, in: ctx)
        return ctx.makeImage()
    }

    // MARK: Backdrop

    private static func drawBackdrop(_ s: DocState, in ctx: CGContext, imageRect: CGRect) {
        let b = s.backdrop
        let full = CGRect(origin: .zero, size: canvasSize(s))

        ctx.saveGState()
        if b.outerRadius > 0 {
            ctx.addPath(CGPath(roundedRect: full, cornerWidth: b.outerRadius, cornerHeight: b.outerRadius, transform: nil))
            ctx.clip()
        }
        if let bg = s.backdropImage {
            let k = max(full.width / CGFloat(bg.width), full.height / CGFloat(bg.height))
            let w = CGFloat(bg.width) * k, h = CGFloat(bg.height) * k
            ctx.interpolationQuality = .high
            ctx.drawFlipped(bg, in: CGRect(x: full.midX - w / 2, y: full.midY - h / 2, width: w, height: h)) // cover
        } else if b.gradient, b.radial, let g = CGGradient(colorsSpace: sRGB, colors: [b.from.cgColor, b.to.cgColor] as CFArray, locations: nil) {
            let c = CGPoint(x: full.midX, y: full.midY)
            ctx.drawRadialGradient(g, startCenter: c, startRadius: 0, endCenter: c, endRadius: hypot(full.width, full.height) / 2,
                                   options: [.drawsAfterEndLocation])
        } else if b.gradient, let g = CGGradient(colorsSpace: sRGB, colors: [b.from.cgColor, b.to.cgColor] as CFArray, locations: nil) {
            let rad = b.angle * .pi / 180
            let half = (abs(full.width * cos(rad)) + abs(full.height * sin(rad))) / 2
            let c = CGPoint(x: full.midX, y: full.midY)
            let d = CGPoint(x: cos(rad) * half, y: sin(rad) * half)
            ctx.drawLinearGradient(g, start: CGPoint(x: c.x - d.x, y: c.y - d.y), end: CGPoint(x: c.x + d.x, y: c.y + d.y),
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        } else {
            ctx.setFillColor(b.from.cgColor)
            ctx.fill(full)
        }
        ctx.restoreGState()

        if b.shadow {
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -b.padding * 0.25), blur: b.padding * 0.5,
                          color: NSColor.black.withAlphaComponent(0.45).cgColor)
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.addPath(CGPath(roundedRect: imageRect, cornerWidth: b.innerRadius, cornerHeight: b.innerRadius, transform: nil))
            ctx.fillPath()
            ctx.restoreGState()
        }
    }

    /// A flat dark title bar with the three window buttons, occupying y in -height..0 of the translated context.
    private static func drawTitleBar(width: CGFloat, height: CGFloat, in ctx: CGContext) {
        ctx.setFillColor(NSColor(hex: 0x2B2B2F).cgColor)
        ctx.fill(CGRect(x: 0, y: -height, width: width, height: height))
        let d = height * 0.3, gap = d * 0.8, x0 = height * 0.5
        for (i, hex) in [UInt32(0xFF5F57), 0xFEBC2E, 0x28C840].enumerated() {
            ctx.setFillColor(NSColor(hex: hex).cgColor)
            ctx.fillEllipse(in: CGRect(x: x0 + CGFloat(i) * (d + gap), y: -height / 2 - d / 2, width: d, height: d))
        }
    }

    // MARK: Annotations

    private static func drawSpotlights(_ spots: [Annotation], size: CGSize, in ctx: CGContext) {
        guard !spots.isEmpty else { return }
        let path = CGMutablePath()
        path.addRect(CGRect(origin: .zero, size: size))
        for s in spots { path.addRoundedRect(in: s.rect, cornerWidth: 6, cornerHeight: 6) }
        ctx.saveGState()
        ctx.addPath(path)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.55).cgColor)
        ctx.fillPath(using: .evenOdd)
        ctx.restoreGState()
    }

    static func draw(_ a: Annotation, image: CGImage, shadow: Bool = false, in ctx: CGContext) {
        ctx.saveGState()
        defer { ctx.restoreGState() }
        if shadow && ![.blur, .highlighter, .spotlight, .overlay, .select, .crop].contains(a.tool) {
            ctx.setShadow(offset: CGSize(width: 0, height: -2), blur: 6, color: NSColor.black.withAlphaComponent(0.45).cgColor)
        }
        ctx.setStrokeColor(a.color.cgColor)
        ctx.setFillColor(a.color.cgColor)
        ctx.setLineWidth(a.width)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        if a.dashed, [.rect, .oval, .line, .pen].contains(a.tool) {
            ctx.setLineDash(phase: 0, lengths: [a.width * 2.2, a.width * 1.8])
        }

        switch a.tool {
        case .rect:
            if a.filled { ctx.fill(a.rect) } else { ctx.stroke(a.rect) }
        case .oval:
            if a.filled { ctx.fillEllipse(in: a.rect) } else { ctx.strokeEllipse(in: a.rect) }
        case .line:
            ctx.move(to: a.p1)
            if let c = a.ctrl { ctx.addQuadCurve(to: a.p2, control: c) } else { ctx.addLine(to: a.p2) }
            ctx.strokePath()
        case .arrow:
            drawArrow(a, in: ctx)
        case .pen:
            strokePolyline(a.points, in: ctx)
        case .highlighter:
            ctx.setBlendMode(.multiply)
            ctx.setLineCap(.butt)
            ctx.setStrokeColor(a.color.withAlphaComponent(0.55).cgColor)
            strokePolyline(a.points, in: ctx)
        case .text:
            drawText(a, in: ctx)
        case .counter:
            drawCounter(a, in: ctx)
        case .ruler:
            drawRuler(a, in: ctx)
        case .blur:
            drawBlur(a, image: image, in: ctx)
        case .magnifier:
            drawMagnifier(a, image: image, in: ctx)
        case .spotlight, .select, .crop, .overlay:
            break
        }
    }

    /// A circular lens showing the screenshot magnified around its centre (p1); p2 sets the radius.
    private static func drawMagnifier(_ a: Annotation, image: CGImage, in ctx: CGContext) {
        let r = hypot(a.p2.x - a.p1.x, a.p2.y - a.p1.y)
        guard r >= 4 else { return }
        let lens = CGRect(x: a.p1.x - r, y: a.p1.y - r, width: 2 * r, height: 2 * r)

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -3), blur: 10, color: NSColor.black.withAlphaComponent(0.45).cgColor)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillEllipse(in: lens)
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addEllipse(in: lens)
        ctx.clip()
        let zoom: CGFloat = 2
        ctx.translateBy(x: a.p1.x, y: a.p1.y)
        ctx.scaleBy(x: zoom, y: zoom)
        ctx.translateBy(x: -a.p1.x, y: -a.p1.y)
        ctx.interpolationQuality = .high
        ctx.drawFlipped(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        ctx.restoreGState()

        ctx.strokeEllipse(in: lens)
    }

    private static func strokePolyline(_ pts: [CGPoint], in ctx: CGContext) {
        guard let first = pts.first else { return }
        ctx.move(to: first)
        if pts.count == 1 { ctx.addLine(to: first) }
        for p in pts.dropFirst() { ctx.addLine(to: p) }
        ctx.strokePath()
    }

    private static func drawArrow(_ a: Annotation, in ctx: CGContext) {
        let dx = a.p2.x - a.p1.x, dy = a.p2.y - a.p1.y
        let len = hypot(dx, dy)
        guard len > 1 else { return }
        let bend = a.style == 2 ? nil : a.ctrl // the tapered arrow stays straight
        let ang = bend.map { atan2(a.p2.y - $0.y, a.p2.x - $0.x) } ?? atan2(dy, dx)
        let head = min(len * 0.7, a.width * 3.5 + 12)
        func wing(_ delta: CGFloat) -> CGPoint {
            CGPoint(x: a.p2.x - cos(ang + delta) * head, y: a.p2.y - sin(ang + delta) * head)
        }
        switch a.style {
        case 1: // open chevron
            ctx.move(to: a.p1)
            if let c = bend { ctx.addQuadCurve(to: a.p2, control: c) } else { ctx.addLine(to: a.p2) }
            ctx.move(to: wing(0.5)); ctx.addLine(to: a.p2); ctx.addLine(to: wing(-0.5))
            ctx.strokePath()
        case 2: // tapered wedge
            let w = max(2, a.width * 1.6)
            let nx = -sin(ang), ny = cos(ang)
            let base = CGPoint(x: a.p2.x - cos(ang) * head * 0.8, y: a.p2.y - sin(ang) * head * 0.8)
            ctx.move(to: a.p1)
            ctx.addLine(to: CGPoint(x: base.x + nx * w, y: base.y + ny * w))
            ctx.addLine(to: wing(0.5)); ctx.addLine(to: a.p2); ctx.addLine(to: wing(-0.5))
            ctx.addLine(to: CGPoint(x: base.x - nx * w, y: base.y - ny * w))
            ctx.closePath(); ctx.fillPath()
        default: // classic filled head
            let base = CGPoint(x: a.p2.x - cos(ang) * head * 0.8, y: a.p2.y - sin(ang) * head * 0.8)
            ctx.move(to: a.p1)
            if let c = bend { ctx.addQuadCurve(to: base, control: c) } else { ctx.addLine(to: base) }
            ctx.strokePath()
            ctx.move(to: a.p2); ctx.addLine(to: wing(0.45)); ctx.addLine(to: wing(-0.45))
            ctx.closePath(); ctx.fillPath()
        }
    }

    static func contrastingColor(for c: NSColor) -> NSColor {
        ColorMath.luminance(c) > 0.45 ? NSColor.black : NSColor.white
    }

    private static func withGraphics(_ ctx: CGContext, _ body: () -> Void) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        body()
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func drawText(_ a: Annotation, in ctx: CGContext) {
        guard !a.text.isEmpty else { return }
        let size = a.textSize
        if a.filled {
            let bg = contrastingColor(for: a.color).withAlphaComponent(0.92)
            ctx.setFillColor(bg.cgColor)
            let r = CGRect(origin: a.p1, size: size).insetBy(dx: -8, dy: -4)
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: 6, cornerHeight: 6, transform: nil))
            ctx.fillPath()
        }
        withGraphics(ctx) {
            NSAttributedString(string: a.text, attributes: Annotation.textAttributes(size: a.fontSize, color: a.color))
                .draw(with: CGRect(origin: a.p1, size: CGSize(width: size.width + 4, height: size.height)), options: [.usesLineFragmentOrigin])
        }
    }

    private static func drawCounter(_ a: Annotation, in ctx: CGContext) {
        let r = a.counterRadius
        let rect = CGRect(x: a.p1.x - r, y: a.p1.y - r, width: 2 * r, height: 2 * r)
        ctx.fillEllipse(in: rect)
        let label = NSAttributedString(string: String(a.number), attributes: [
            .font: NSFont.systemFont(ofSize: r * 1.1, weight: .bold),
            .foregroundColor: contrastingColor(for: a.color),
        ])
        let ls = label.size()
        withGraphics(ctx) { label.draw(at: CGPoint(x: a.p1.x - ls.width / 2, y: a.p1.y - ls.height / 2)) }
    }

    private static func drawRuler(_ a: Annotation, in ctx: CGContext) {
        let dx = a.p2.x - a.p1.x, dy = a.p2.y - a.p1.y
        let horizontal = abs(dx) >= abs(dy)
        let end = horizontal ? CGPoint(x: a.p2.x, y: a.p1.y) : CGPoint(x: a.p1.x, y: a.p2.y)
        let length = horizontal ? abs(dx) : abs(dy)
        guard length >= 1 else { return }
        let cap: CGFloat = 7 + a.width
        ctx.setLineWidth(max(1, a.width / 2))
        ctx.move(to: a.p1); ctx.addLine(to: end)
        if horizontal {
            ctx.move(to: CGPoint(x: a.p1.x, y: a.p1.y - cap)); ctx.addLine(to: CGPoint(x: a.p1.x, y: a.p1.y + cap))
            ctx.move(to: CGPoint(x: end.x, y: end.y - cap)); ctx.addLine(to: CGPoint(x: end.x, y: end.y + cap))
        } else {
            ctx.move(to: CGPoint(x: a.p1.x - cap, y: a.p1.y)); ctx.addLine(to: CGPoint(x: a.p1.x + cap, y: a.p1.y))
            ctx.move(to: CGPoint(x: end.x - cap, y: end.y)); ctx.addLine(to: CGPoint(x: end.x + cap, y: end.y))
        }
        ctx.strokePath()

        let label = NSAttributedString(string: "\(Int(length.rounded())) px", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: contrastingColor(for: a.color),
        ])
        let ls = label.size()
        let mid = CGPoint(x: (a.p1.x + end.x) / 2, y: (a.p1.y + end.y) / 2)
        let box = CGRect(x: mid.x - ls.width / 2 - 6, y: mid.y - ls.height - cap - 6, width: ls.width + 12, height: ls.height + 4)
        ctx.setFillColor(a.color.cgColor)
        ctx.addPath(CGPath(roundedRect: box, cornerWidth: 5, cornerHeight: 5, transform: nil))
        ctx.fillPath()
        withGraphics(ctx) { label.draw(at: CGPoint(x: box.minX + 6, y: box.minY + 2)) }
    }

    // MARK: Blur / erase

    private static func drawBlur(_ a: Annotation, image: CGImage, in ctx: CGContext) {
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let r = a.rect.integral.intersection(bounds)
        guard r.width >= 1, r.height >= 1 else { return }

        if a.blur == .erase {
            ctx.setFillColor(edgeColor(image, around: r).cgColor)
            ctx.fill(r)
            return
        }
        if let patch = blurPatch(a, image: image, rect: r) { ctx.drawFlipped(patch, in: r) }
    }

    private static func blurPatch(_ a: Annotation, image: CGImage, rect r: CGRect) -> CGImage? {
        let owner = Unmanaged.passUnretained(image).toOpaque()
        if owner != blurCacheOwner { blurCache.removeAll(); blurCacheOwner = owner }
        let key = "\(r.debugDescription)-\(a.blur.rawValue)-\(a.width)"
        if let hit = blurCache[key] { return hit }

        let ci = CIImage(cgImage: image)
        let ciRect = CGRect(x: r.minX, y: CGFloat(image.height) - r.maxY, width: r.width, height: r.height)
        let src = ci.clampedToExtent()
        let out: CIImage
        if a.blur == .pixelate {
            out = src.applyingFilter("CIPixellate", parameters: [
                kCIInputScaleKey: max(4, a.width),
                kCIInputCenterKey: CIVector(x: ciRect.minX, y: ciRect.minY),
            ]).cropped(to: ciRect)
        } else {
            out = src.applyingGaussianBlur(sigma: Double(max(2, a.width))).cropped(to: ciRect)
        }
        guard let cg = ciContext.createCGImage(out, from: ciRect) else { return nil }
        if blurCache.count > 64 { blurCache.removeAll() }
        blurCache[key] = cg
        return cg
    }

    /// Average colour of a thin ring just outside `r`, used to "erase" content convincingly.
    private static func edgeColor(_ image: CGImage, around r: CGRect) -> NSColor {
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let t: CGFloat = 3
        let strips = [
            CGRect(x: r.minX, y: r.minY - t, width: r.width, height: t),
            CGRect(x: r.minX, y: r.maxY, width: r.width, height: t),
            CGRect(x: r.minX - t, y: r.minY, width: t, height: r.height),
            CGRect(x: r.maxX, y: r.minY, width: t, height: r.height),
        ].map { $0.intersection(bounds) }.filter { $0.width >= 1 && $0.height >= 1 }
        guard !strips.isEmpty else { return .white }

        var sum: (CGFloat, CGFloat, CGFloat) = (0, 0, 0)
        for s in strips {
            guard let crop = image.cropping(to: s), let c = ColorMath.averageColor(of: crop) else { continue }
            sum.0 += c.redComponent; sum.1 += c.greenComponent; sum.2 += c.blueComponent
        }
        let n = CGFloat(strips.count)
        return NSColor(srgbRed: sum.0 / n, green: sum.1 / n, blue: sum.2 / n, alpha: 1)
    }
}
