import AppKit

enum ColorMath {
    private static func linear(_ c: CGFloat) -> CGFloat {
        c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }

    private static func rgb(_ c: NSColor) -> (CGFloat, CGFloat, CGFloat) {
        let s = c.usingColorSpace(.sRGB) ?? c
        return (s.redComponent, s.greenComponent, s.blueComponent)
    }

    /// WCAG relative luminance.
    static func luminance(_ c: NSColor) -> CGFloat {
        let (r, g, b) = rgb(c)
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }

    /// WCAG 2.x contrast ratio (1...21).
    static func wcagRatio(_ a: NSColor, _ b: NSColor) -> CGFloat {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// APCA lightness contrast (Lc), text on background. Positive = dark text on light, negative = light on dark.
    static func apca(text: NSColor, background: NSColor) -> CGFloat {
        func y(_ c: NSColor) -> CGFloat {
            let (r, g, b) = rgb(c)
            var v = 0.2126729 * pow(r, 2.4) + 0.7151522 * pow(g, 2.4) + 0.0721750 * pow(b, 2.4)
            if v < 0.022 { v += pow(0.022 - v, 1.414) }
            return v
        }
        let yt = y(text), yb = y(background)
        guard abs(yb - yt) >= 0.0005 else { return 0 }
        if yb > yt {
            let c = (pow(yb, 0.56) - pow(yt, 0.57)) * 1.14
            return c < 0.1 ? 0 : (c - 0.027) * 100
        }
        let c = (pow(yb, 0.65) - pow(yt, 0.62)) * 1.14
        return c > -0.1 ? 0 : (c + 0.027) * 100
    }

    static func averageColor(of image: CGImage) -> NSColor? {
        var px = [UInt8](repeating: 0, count: 4)
        guard let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: Renderer.sRGB,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return NSColor(srgbRed: CGFloat(px[0]) / 255, green: CGFloat(px[1]) / 255, blue: CGFloat(px[2]) / 255, alpha: 1)
    }

    /// Finds the dominant background and the most contrasting frequent colour of an image region.
    static func dominantPair(in image: CGImage) -> (text: NSColor, background: NSColor)? {
        let maxSide: CGFloat = 200
        let k = min(1, maxSide / CGFloat(max(image.width, image.height)))
        let w = max(1, Int(CGFloat(image.width) * k)), h = max(1, Int(CGFloat(image.height) * k))
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: Renderer.sRGB,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .none
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        var counts: [UInt32: Int] = [:]
        for i in stride(from: 0, to: buf.count, by: 4) {
            let key = (UInt32(buf[i] >> 3) << 10) | (UInt32(buf[i + 1] >> 3) << 5) | UInt32(buf[i + 2] >> 3)
            counts[key, default: 0] += 1
        }
        func color(_ key: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat((key >> 10) & 31) / 31, green: CGFloat((key >> 5) & 31) / 31, blue: CGFloat(key & 31) / 31, alpha: 1)
        }
        guard let bgKey = counts.max(by: { $0.value < $1.value })?.key else { return nil }
        let bg = color(bgKey)
        let minCount = max(2, w * h / 200)
        let fg = counts.filter { $0.value >= minCount && $0.key != bgKey }
            .map { color($0.key) }
            .max(by: { wcagRatio($0, bg) < wcagRatio($1, bg) })
        guard let fg else { return nil }
        return (fg, bg)
    }
}

enum ColorFormat: String, CaseIterable {
    case hex, hexNoHash, rgb, rgba, hsl, swift, csharp

    var title: String {
        switch self {
        case .hex: return "HEX  #FFC200"
        case .hexNoHash: return "HEX  FFC200"
        case .rgb: return "RGB  255, 194, 0"
        case .rgba: return "CSS  rgba(255, 194, 0, 1)"
        case .hsl: return "CSS  hsl(45, 100%, 50%)"
        case .swift: return "Swift  NSColor(...)"
        case .csharp: return "C#  Color.FromArgb(...)"
        }
    }

    func string(for color: NSColor) -> String {
        let c = color.usingColorSpace(.sRGB) ?? color
        let r = Int((c.redComponent * 255).rounded()), g = Int((c.greenComponent * 255).rounded()), b = Int((c.blueComponent * 255).rounded())
        switch self {
        case .hex: return String(format: "#%02X%02X%02X", r, g, b)
        case .hexNoHash: return String(format: "%02X%02X%02X", r, g, b)
        case .rgb: return "\(r), \(g), \(b)"
        case .rgba: return "rgba(\(r), \(g), \(b), 1)"
        case .hsl:
            let h = Int((c.hueComponent * 360).rounded())
            let mx = max(c.redComponent, c.greenComponent, c.blueComponent), mn = min(c.redComponent, c.greenComponent, c.blueComponent)
            let l = (mx + mn) / 2
            let s = mx == mn ? 0 : (mx - mn) / (1 - abs(2 * l - 1))
            return "hsl(\(h), \(Int((s * 100).rounded()))%, \(Int((l * 100).rounded()))%)"
        case .swift:
            return String(format: "NSColor(srgbRed: %.3f, green: %.3f, blue: %.3f, alpha: 1)", c.redComponent, c.greenComponent, c.blueComponent)
        case .csharp: return "Color.FromArgb(\(r), \(g), \(b))"
        }
    }

    static var current: ColorFormat { ColorFormat(rawValue: Pref.string("colorFormat")) ?? .hex }
}

/// Raw RGBA copy of an image for fast per-pixel lookups (colour under cursor).
final class PixelBuffer {
    let width: Int, height: Int
    private var data: [UInt8]

    init?(_ image: CGImage) {
        width = image.width; height = image.height
        data = [UInt8](repeating: 0, count: width * height * 4)
        guard let ctx = CGContext(data: &data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: Renderer.sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }

    private func luma(_ x: Int, _ y: Int) -> Int {
        let i = (y * width + x) * 4
        return (Int(data[i]) * 299 + Int(data[i + 1]) * 587 + Int(data[i + 2]) * 114) / 1000
    }

    /// Pulls `p` onto the strongest nearby vertical/horizontal edge of the image (within `radius` pixels), per axis.
    func snap(_ p: CGPoint, radius: Int) -> CGPoint {
        let px = Int(p.x.rounded()), py = Int(p.y.rounded())
        let span = 6
        guard px >= radius + 1, py >= radius + 1, px < width - radius - 1, py < height - radius - 1,
              py - span >= 0, py + span < height, px - span >= 0, px + span < width else { return p }
        var best = (x: px, score: 0)
        for x in max(1, px - radius)...min(width - 1, px + radius) {
            var s = 0
            for y in (py - span)...(py + span) { s += abs(luma(x, y) - luma(x - 1, y)) }
            let score = s - 4 * abs(x - px) * (2 * span + 1) / 13
            if s >= 24 * (2 * span + 1) / 2 && score > best.score { best = (x, score) }
        }
        var bestY = (y: py, score: 0)
        for y in max(1, py - radius)...min(height - 1, py + radius) {
            var s = 0
            for x in (px - span)...(px + span) { s += abs(luma(x, y) - luma(x, y - 1)) }
            let score = s - 4 * abs(y - py) * (2 * span + 1) / 13
            if s >= 24 * (2 * span + 1) / 2 && score > bestY.score { bestY = (y, score) }
        }
        return CGPoint(x: best.score > 0 ? CGFloat(best.x) : p.x, y: bestY.score > 0 ? CGFloat(bestY.y) : p.y)
    }

    /// Bounding box of the connected area around (x, y) whose colour stays within `tolerance` of the starting pixel.
    func similarRegion(from x: Int, _ y: Int, tolerance: Int = 14, maxPixels: Int = 6_000_000) -> CGRect? {
        guard x >= 0, y >= 0, x < width, y < height else { return nil }
        let s = (y * width + x) * 4
        let (r0, g0, b0) = (Int(data[s]), Int(data[s + 1]), Int(data[s + 2]))
        var visited = [Bool](repeating: false, count: width * height)
        var stack = [y * width + x]
        visited[y * width + x] = true
        var minX = x, maxX = x, minY = y, maxY = y, count = 0
        while let idx = stack.popLast() {
            count += 1
            if count > maxPixels { return nil }
            let cx = idx % width, cy = idx / width
            minX = min(minX, cx); maxX = max(maxX, cx); minY = min(minY, cy); maxY = max(maxY, cy)
            for (nx, ny) in [(cx + 1, cy), (cx - 1, cy), (cx, cy + 1), (cx, cy - 1)] where nx >= 0 && ny >= 0 && nx < width && ny < height {
                let n = ny * width + nx
                if visited[n] { continue }
                let i = n * 4
                if abs(Int(data[i]) - r0) <= tolerance && abs(Int(data[i + 1]) - g0) <= tolerance && abs(Int(data[i + 2]) - b0) <= tolerance {
                    visited[n] = true
                    stack.append(n)
                }
            }
        }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    func color(x: Int, y: Int) -> NSColor? {
        guard x >= 0, y >= 0, x < width, y < height else { return nil }
        let i = (y * width + x) * 4
        return NSColor(srgbRed: CGFloat(data[i]) / 255, green: CGFloat(data[i + 1]) / 255, blue: CGFloat(data[i + 2]) / 255, alpha: 1)
    }
}

@MainActor
enum ColorTools {
    private static var sampler: NSColorSampler?

    static func sample(_ done: @escaping (NSColor) -> Void) {
        let s = NSColorSampler()
        sampler = s
        s.show { color in
            sampler = nil
            if let color { done(color) }
        }
    }

    static func pickAndCopy() {
        sample { color in
            let text = ColorFormat.current.string(for: color)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            Toast.show(LF("Copied %@", text))
        }
    }

    /// Two-step sampling: text colour, then background colour.
    static func contrastCheck() {
        Toast.show(L("Pick the TEXT colour"), duration: 3)
        sample { fg in
            Toast.show(L("Now pick the BACKGROUND colour"), duration: 3)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                sample { bg in report(text: fg, background: bg) }
            }
        }
    }

    static func report(text: NSColor, background: NSColor) {
        let ratio = ColorMath.wcagRatio(text, background)
        let lc = ColorMath.apca(text: text, background: background)
        let verdict = ratio >= 7 ? "AAA" : ratio >= 4.5 ? "AA" : ratio >= 3 ? "AA Large / UI only" : "Fails WCAG"
        let msg = String(format: "WCAG %.2f:1 (%@) · APCA Lc %.0f", ratio, verdict, lc)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(msg, forType: .string)
        Toast.show(msg, duration: 4)
    }
}
