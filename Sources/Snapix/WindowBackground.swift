import AppKit

/// What sits behind a captured window: nothing (transparent corners), the desktop picture or a plain colour.
enum WindowBackground {
    enum Mode: String { case transparent, wallpaper, solid }

    static var mode: Mode { Mode(rawValue: Pref.string("windowBackground")) ?? .transparent }

    /// Margin around the window, in pixels, proportional to its size.
    static func margin(for size: CGSize) -> Int { max(24, Int((min(size.width, size.height) * 0.08).rounded())) }

    /// The window centred on `fill`, with `margin` pixels around it. `picture` is scaled to cover the canvas; `color` is used when there is none.
    static func compose(window: CGImage, picture: CGImage?, color: CGColor, margin: Int) -> CGImage? {
        let w = window.width + 2 * margin, h = window.height + 2 * margin
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: Renderer.sRGB,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        ctx.setFillColor(color)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        if let picture {
            let k = max(CGFloat(w) / CGFloat(picture.width), CGFloat(h) / CGFloat(picture.height))
            let pw = CGFloat(picture.width) * k, ph = CGFloat(picture.height) * k
            ctx.interpolationQuality = .high
            ctx.draw(picture, in: CGRect(x: (CGFloat(w) - pw) / 2, y: (CGFloat(h) - ph) / 2, width: pw, height: ph))
        }
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -CGFloat(margin) * 0.2), blur: CGFloat(margin) * 0.5, color: NSColor.black.withAlphaComponent(0.4).cgColor)
        ctx.draw(window, in: CGRect(x: margin, y: margin, width: window.width, height: window.height))
        ctx.restoreGState()
        return ctx.makeImage()
    }

    /// Applies the user's choice to a freshly captured window; returns it unchanged for the transparent mode.
    @MainActor
    static func apply(to image: CGImage, on screen: NSScreen?) -> CGImage {
        let m = mode
        guard m != .transparent else { return image }
        let margin = margin(for: CGSize(width: image.width, height: image.height))
        var picture: CGImage?
        if m == .wallpaper, let screen, let url = NSWorkspace.shared.desktopImageURL(for: screen), let img = NSImage(contentsOf: url) {
            picture = img.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
        let color = NSColor(hex: UInt32(truncatingIfNeeded: UserDefaults.standard.object(forKey: "windowBackgroundColor") as? Int ?? 0x1B1B1E)).cgColor
        return compose(window: image, picture: picture, color: color, margin: margin) ?? image
    }
}
