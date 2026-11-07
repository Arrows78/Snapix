import AppKit

/// A text stamp (name, handle, "Confidential"…) added to every image that leaves the app.
enum Watermark {
    static let positions = ["bottomRight", "bottomLeft", "topRight", "topLeft", "center"]

    static var isActive: Bool { Pref.bool("watermarkEnabled") && !Pref.string("watermarkText").trimmingCharacters(in: .whitespaces).isEmpty }

    /// Where the stamp's rectangle goes inside an image of `size` (top-left origin).
    static func frame(for textSize: CGSize, in size: CGSize, position: String) -> CGRect {
        let m = max(12, size.width * 0.02)
        let x: CGFloat, y: CGFloat
        switch position {
        case "bottomLeft": x = m; y = size.height - textSize.height - m
        case "topRight": x = size.width - textSize.width - m; y = m
        case "topLeft": x = m; y = m
        case "center": x = (size.width - textSize.width) / 2; y = (size.height - textSize.height) / 2
        default: x = size.width - textSize.width - m; y = size.height - textSize.height - m
        }
        return CGRect(x: x, y: y, width: textSize.width, height: textSize.height)
    }

    static func apply(to image: CGImage) -> CGImage {
        guard isActive else { return image }
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: Renderer.sRGB,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return image }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        // Flip so the text and the frame maths use a top-left origin.
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        let percent = max(1.5, min(10, Pref.double("watermarkSize")))
        let font = NSFont.systemFont(ofSize: max(10, CGFloat(w) * percent / 100 * 0.5), weight: .semibold)
        let opacity = max(0.1, min(1, Pref.double("watermarkOpacity")))
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.5 * opacity)
        shadow.shadowBlurRadius = font.pointSize * 0.15
        shadow.shadowOffset = NSSize(width: 0, height: -font.pointSize * 0.05)
        let text = NSAttributedString(string: Pref.string("watermarkText"), attributes: [
            .font: font, .foregroundColor: NSColor.white.withAlphaComponent(opacity), .shadow: shadow,
        ])
        let r = frame(for: text.size(), in: CGSize(width: w, height: h), position: Pref.string("watermarkPosition"))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        text.draw(at: r.origin)
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage() ?? image
    }
}
