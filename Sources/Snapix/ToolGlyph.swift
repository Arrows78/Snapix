import AppKit

/// The editor's icon family: every glyph is drawn on the same 20 pt grid with a 1.5 pt round-capped stroke
/// (no fills except where a shape is a solid mark), so the toolbar reads as one set. Images are templates, tinted by the button.
enum ToolGlyph {
    static let side: CGFloat = 20

    private static func make(_ draw: @escaping () -> Void) -> NSImage {
        let img = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            NSColor.black.set()
            draw()
            return true
        }
        img.isTemplate = true
        return img
    }

    private static func path(lineWidth: CGFloat = 1.5, _ build: (NSBezierPath) -> Void) -> NSBezierPath {
        let p = NSBezierPath()
        p.lineWidth = lineWidth
        p.lineCapStyle = .round
        p.lineJoinStyle = .round
        build(p)
        return p
    }

    private static func line(_ a: NSPoint, _ b: NSPoint) { path { $0.move(to: a); $0.line(to: b) }.stroke() }

    static func image(for tool: Tool) -> NSImage {
        switch tool {
        case .select: return make { // pointer
            let p = path { p in
                p.move(to: NSPoint(x: 5, y: 17)); p.line(to: NSPoint(x: 5, y: 3.5)); p.line(to: NSPoint(x: 8.6, y: 6.8))
                p.line(to: NSPoint(x: 11.4, y: 2.6)); p.line(to: NSPoint(x: 13.4, y: 3.8)); p.line(to: NSPoint(x: 10.8, y: 8)); p.line(to: NSPoint(x: 15.5, y: 8.3)); p.close()
            }
            p.stroke() }
        case .arrow: return make {
            line(NSPoint(x: 4, y: 4), NSPoint(x: 16, y: 16))
            path { $0.move(to: NSPoint(x: 8.5, y: 16)); $0.line(to: NSPoint(x: 16, y: 16)); $0.line(to: NSPoint(x: 16, y: 8.5)) }.stroke() }
        case .rect: return make { path { $0.appendRoundedRect(NSRect(x: 3.5, y: 5, width: 13, height: 10), xRadius: 2, yRadius: 2) }.stroke() }
        case .oval: return make { path { $0.appendOval(in: NSRect(x: 3, y: 4.5, width: 14, height: 11)) }.stroke() }
        case .line: return make {
            line(NSPoint(x: 4.5, y: 4.5), NSPoint(x: 15.5, y: 15.5))
            for c in [NSPoint(x: 4.5, y: 4.5), NSPoint(x: 15.5, y: 15.5)] { path { $0.appendOval(in: NSRect(x: c.x - 1.6, y: c.y - 1.6, width: 3.2, height: 3.2)) }.fill() } }
        case .pen: return make { // scribble
            path { p in
                p.move(to: NSPoint(x: 3.5, y: 6)); p.curve(to: NSPoint(x: 9, y: 13.5), controlPoint1: NSPoint(x: 5, y: 3), controlPoint2: NSPoint(x: 6, y: 13))
                p.curve(to: NSPoint(x: 13, y: 6.5), controlPoint1: NSPoint(x: 12, y: 14), controlPoint2: NSPoint(x: 10.5, y: 7))
                p.curve(to: NSPoint(x: 16.5, y: 14), controlPoint1: NSPoint(x: 15, y: 5.5), controlPoint2: NSPoint(x: 15.5, y: 12))
            }.stroke() }
        case .pencil: return make {
            path { p in
                p.move(to: NSPoint(x: 4, y: 4)); p.line(to: NSPoint(x: 4.6, y: 8)); p.line(to: NSPoint(x: 13, y: 16.4)); p.line(to: NSPoint(x: 16.4, y: 13)); p.line(to: NSPoint(x: 8, y: 4.6)); p.close()
            }.stroke()
            line(NSPoint(x: 11, y: 14.4), NSPoint(x: 14.4, y: 11)) }
        case .text: return make {
            line(NSPoint(x: 4.5, y: 16), NSPoint(x: 15.5, y: 16)); line(NSPoint(x: 10, y: 16), NSPoint(x: 10, y: 4.5))
            line(NSPoint(x: 8, y: 4.5), NSPoint(x: 12, y: 4.5)) }
        case .highlighter: return make {
            path { p in
                p.move(to: NSPoint(x: 6.5, y: 8.5)); p.line(to: NSPoint(x: 12, y: 14)); p.line(to: NSPoint(x: 15.5, y: 10.5)); p.line(to: NSPoint(x: 10, y: 5)); p.close()
            }.stroke()
            line(NSPoint(x: 4, y: 3.5), NSPoint(x: 11, y: 3.5)) }
        case .blur: return make { // mosaic
            for (x, y) in [(3.5, 3.5), (10.5, 3.5), (3.5, 10.5), (10.5, 10.5)] {
                let r = NSRect(x: x, y: y, width: 6, height: 6)
                let on = (x == 3.5) == (y == 3.5)
                let p = path(lineWidth: 1.3) { $0.appendRoundedRect(r, xRadius: 1.2, yRadius: 1.2) }
                if on { p.fill() } else { p.stroke() }
            } }
        case .spotlight: return make { // dim frame with a clear window
            let outer = path { $0.appendRoundedRect(NSRect(x: 2.5, y: 3.5, width: 15, height: 13), xRadius: 2.5, yRadius: 2.5) }
            outer.setLineDash([2, 2.2], count: 2, phase: 0); outer.stroke()
            path { $0.appendRoundedRect(NSRect(x: 6.5, y: 7, width: 7, height: 6), xRadius: 1.5, yRadius: 1.5) }.stroke() }
        case .counter: return make {
            path { $0.appendOval(in: NSRect(x: 3, y: 3, width: 14, height: 14)) }.stroke()
            path { $0.move(to: NSPoint(x: 8.4, y: 11.8)); $0.line(to: NSPoint(x: 10.4, y: 13.2)); $0.line(to: NSPoint(x: 10.4, y: 6.6)) }.stroke() }
        case .ruler: return make {
            path { $0.appendRoundedRect(NSRect(x: 2.5, y: 6.5, width: 15, height: 7), xRadius: 1.8, yRadius: 1.8) }.stroke()
            for x in [6.0, 9.0, 12.0, 15.0] { line(NSPoint(x: x, y: 13.2), NSPoint(x: x, y: x == 9 ? 9.5 : 10.8)) } }
        case .magnifier: return make {
            path { $0.appendOval(in: NSRect(x: 3, y: 7, width: 10, height: 10)) }.stroke()
            line(NSPoint(x: 12.2, y: 8), NSPoint(x: 16.5, y: 3.5))
            line(NSPoint(x: 6, y: 12), NSPoint(x: 10, y: 12)); line(NSPoint(x: 8, y: 10), NSPoint(x: 8, y: 14)) }
        case .overlay: return make {
            path { $0.appendRoundedRect(NSRect(x: 2.5, y: 7, width: 10, height: 10), xRadius: 2, yRadius: 2) }.stroke()
            path { $0.appendRoundedRect(NSRect(x: 7.5, y: 2.5, width: 10, height: 10), xRadius: 2, yRadius: 2) }.stroke() }
        case .crop: return make {
            path { $0.move(to: NSPoint(x: 6, y: 17)); $0.line(to: NSPoint(x: 6, y: 6)); $0.line(to: NSPoint(x: 17, y: 6)) }.stroke()
            path { $0.move(to: NSPoint(x: 3, y: 6)); $0.line(to: NSPoint(x: 6, y: 6)) }.stroke()
            path { $0.move(to: NSPoint(x: 14, y: 3)); $0.line(to: NSPoint(x: 14, y: 14)); $0.line(to: NSPoint(x: 3, y: 14)) }.stroke()
            path { $0.move(to: NSPoint(x: 14, y: 17)); $0.line(to: NSPoint(x: 14, y: 14)) }.stroke() }
        }
    }

    /// Backdrop (a framed picture on a coloured ground).
    static var backdrop: NSImage {
        make {
            path { $0.appendRoundedRect(NSRect(x: 2.5, y: 2.5, width: 15, height: 15), xRadius: 3.5, yRadius: 3.5) }.stroke()
            path { $0.appendRoundedRect(NSRect(x: 6.5, y: 6.5, width: 7, height: 7), xRadius: 1.6, yRadius: 1.6) }.fill()
        }
    }

    /// The "more" menu: three dots.
    static var more: NSImage {
        make { for x in [5.0, 10.0, 15.0] { path { $0.appendOval(in: NSRect(x: x - 1.4, y: 8.6, width: 2.8, height: 2.8)) }.fill() } }
    }
}
