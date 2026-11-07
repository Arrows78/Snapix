import CoreGraphics

/// Turns a rough highlighter stroke into a clean band over the text line it covers.
enum HighlightSnap {
    /// Fraction of `stroke` that overlaps `box`, used to pick the line the user meant.
    static func overlap(_ stroke: CGRect, _ box: CGRect) -> CGFloat {
        let i = stroke.intersection(box)
        guard !i.isNull, stroke.width * stroke.height > 0 || stroke.width > 0 else { return 0 }
        let strokeArea = max(1, stroke.width) * max(1, stroke.height)
        return (max(1, i.width) * max(1, i.height)) / strokeArea
    }

    /// The two end points and the stroke width of the snapped band, or nil when no text line matches well enough.
    static func snapped(stroke: CGRect, boxes: [CGRect]) -> (points: [CGPoint], width: CGFloat)? {
        guard let best = boxes.max(by: { overlap(stroke, $0) < overlap(stroke, $1) }), overlap(stroke, best) > 0.15 else { return nil }
        var x1 = max(stroke.minX, best.minX), x2 = min(stroke.maxX, best.maxX)
        if x2 - x1 < 4 { x1 = best.minX; x2 = best.maxX }
        return ([CGPoint(x: x1, y: best.midY), CGPoint(x: x2, y: best.midY)], best.height * 1.15)
    }
}
