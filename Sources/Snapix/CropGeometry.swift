import AppKit

/// Aspect-ratio handling for the crop tool.
enum CropGeometry {
    /// Width / height presets, in the order shown in the options card; nil is free-form.
    static let ratios: [(label: String, value: CGFloat?)] = [
        ("Free", nil), ("1:1", 1), ("4:3", 4.0 / 3), ("3:4", 3.0 / 4), ("3:2", 3.0 / 2), ("2:3", 2.0 / 3), ("16:9", 16.0 / 9), ("9:16", 9.0 / 16),
    ]

    /// The rectangle dragged from `start` towards `end`, kept inside `bounds` and, when `ratio` is set, shrunk to that aspect ratio.
    static func rect(from start: CGPoint, to end: CGPoint, ratio: CGFloat?, bounds: CGRect) -> CGRect {
        let sx: CGFloat = end.x < start.x ? -1 : 1, sy: CGFloat = end.y < start.y ? -1 : 1
        let availW = sx > 0 ? bounds.maxX - start.x : start.x - bounds.minX
        let availH = sy > 0 ? bounds.maxY - start.y : start.y - bounds.minY
        var w = max(0, min(abs(end.x - start.x), availW)), h = max(0, min(abs(end.y - start.y), availH))
        if let ratio, ratio > 0, w > 0, h > 0 {
            if w / h > ratio { w = h * ratio } else { h = w / ratio }
        }
        return CGRect(x: sx > 0 ? start.x : start.x - w, y: sy > 0 ? start.y : start.y - h, width: w, height: h)
    }

    /// Re-fits an existing crop box to `ratio`, keeping its centre where possible.
    static func refit(_ r: CGRect, ratio: CGFloat?, bounds: CGRect) -> CGRect {
        guard let ratio, ratio > 0, r.width > 0, r.height > 0 else { return r }
        var w = r.width, h = r.width / ratio
        if h > r.height { h = r.height; w = h * ratio }
        w = min(w, bounds.width); h = min(h, bounds.height)
        if w / h > ratio { w = h * ratio } else { h = w / ratio }
        let x = max(bounds.minX, min(bounds.maxX - w, r.midX - w / 2)), y = max(bounds.minY, min(bounds.maxY - h, r.midY - h / 2))
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// Small outline of the ratio for the options card (template image).
    static func glyph(ratio: CGFloat?) -> NSImage {
        let img = NSImage(size: NSSize(width: 22, height: 16), flipped: false) { _ in
            NSColor.black.set()
            let side: CGFloat = 13
            let r = ratio ?? 1.25
            let w = r >= 1 ? side * 1.45 : side * r * 1.0, h = r >= 1 ? side * 1.45 / r : side
            let box = NSRect(x: (22 - min(w, 20)) / 2, y: (16 - min(h, 14)) / 2, width: min(w, 20), height: min(h, 14))
            let p = NSBezierPath(roundedRect: box, xRadius: 1.5, yRadius: 1.5)
            p.lineWidth = 1.6
            if ratio == nil { p.setLineDash([2.5, 2], count: 2, phase: 0) }
            p.stroke()
            return true
        }
        img.isTemplate = true
        return img
    }
}
