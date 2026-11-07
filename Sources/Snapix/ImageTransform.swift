import CoreGraphics

/// Rotation and mirroring of bitmaps, in whole quarter turns so no pixel is resampled.
enum ImageTransform {
    private static func context(_ w: Int, _ h: Int) -> CGContext? {
        CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: Renderer.sRGB,
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    }

    static func rotated(_ image: CGImage, clockwise: Bool) -> CGImage? {
        let w = image.width, h = image.height
        guard let ctx = context(h, w) else { return nil }
        // CoreGraphics' y axis points up, so a clockwise turn on screen is a negative angle.
        ctx.translateBy(x: CGFloat(h) / 2, y: CGFloat(w) / 2)
        ctx.rotate(by: clockwise ? -.pi / 2 : .pi / 2)
        ctx.draw(image, in: CGRect(x: -CGFloat(w) / 2, y: -CGFloat(h) / 2, width: CGFloat(w), height: CGFloat(h)))
        return ctx.makeImage()
    }

    /// Adds empty space around the image; `fill` nil leaves it transparent.
    static func expanded(_ image: CGImage, top: Int, right: Int, bottom: Int, left: Int, fill: CGColor?) -> CGImage? {
        let w = image.width + left + right, h = image.height + top + bottom
        guard left >= 0, right >= 0, top >= 0, bottom >= 0, w > 0, h > 0, w * h <= 200_000_000, let ctx = context(w, h) else { return nil }
        if let fill { ctx.setFillColor(fill); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h)) }
        // CoreGraphics' origin is bottom-left: the bottom margin is the y offset.
        ctx.draw(image, in: CGRect(x: left, y: bottom, width: image.width, height: image.height))
        return ctx.makeImage()
    }

    static func flipped(_ image: CGImage, horizontal: Bool) -> CGImage? {
        let w = image.width, h = image.height
        guard let ctx = context(w, h) else { return nil }
        if horizontal { ctx.translateBy(x: CGFloat(w), y: 0); ctx.scaleBy(x: -1, y: 1) }
        else { ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: 1, y: -1) }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }
}
