import CoreGraphics

/// Joins several screenshots into one image, in a column or a row.
enum Combine {
    static func images(_ images: [CGImage], horizontal: Bool, spacing: Int = 0) -> CGImage? {
        guard images.count > 1 else { return images.first }
        let gaps = spacing * (images.count - 1)
        let w = horizontal ? images.map(\.width).reduce(0, +) + gaps : images.map(\.width).max() ?? 0
        let h = horizontal ? images.map(\.height).max() ?? 0 : images.map(\.height).reduce(0, +) + gaps
        guard w > 0, h > 0, w * h <= 200_000_000,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: Renderer.sRGB,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        var cursor = 0
        for img in images {
            // Each image is centred on the cross axis; CoreGraphics' origin is bottom-left, so the first image goes on top.
            let x = horizontal ? cursor : (w - img.width) / 2
            let y = horizontal ? (h - img.height) / 2 : h - cursor - img.height
            ctx.draw(img, in: CGRect(x: x, y: y, width: img.width, height: img.height))
            cursor += (horizontal ? img.width : img.height) + spacing
        }
        return ctx.makeImage()
    }
}
