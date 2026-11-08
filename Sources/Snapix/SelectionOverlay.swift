import AppKit

final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// User-tunable look of the selection overlay.
enum Overlay {
    /// How dark the area outside the selection is, 0...0.8.
    static var dim: CGFloat { CGFloat(max(0, min(0.8, UserDefaults.standard.object(forKey: "overlayDim") as? Double ?? 0.4))) }
    static var showLoupe: Bool { UserDefaults.standard.object(forKey: "showLoupe") as? Bool ?? true }
    /// Pixels shown across the magnifier: fewer pixels means a stronger zoom (odd, so one pixel sits at the centre).
    static func loupeCells(for setting: String?) -> Int {
        switch setting { case "high": return 9; case "low": return 21; default: return 15 }
    }

    static var loupeCells: Int { loupeCells(for: UserDefaults.standard.string(forKey: "loupeZoom")) }

    static var loupeSize: CGFloat {
        switch UserDefaults.standard.string(forKey: "loupeSize") { case "small": return 90; case "large": return 160; default: return 120 }
    }
}

/// Full-screen frozen-screenshot overlays used to pick an area or a window.
@MainActor
final class SelectionOverlay {
    enum Mode { case area, window, element }
    enum Result {
        /// Frozen screen, pixel rect inside its image, rect in AppKit global coordinates, and where the selection ended
        /// (cursor position, AppKit global coordinates).
        case area(Frozen, CGRect, CGRect, CGPoint)
        case window(CGWindowID)
        case cancelled
    }

    private static var current: SelectionOverlay?
    private var windows: [OverlayWindow] = []
    private var continuation: CheckedContinuation<Result, Never>?

    static func run(frozen: [Frozen], mode: Mode, live: Bool = false) async -> Result {
        let overlay = SelectionOverlay()
        current = overlay
        return await withCheckedContinuation { cont in
            overlay.continuation = cont
            overlay.show(frozen, mode: mode, live: live)
        }
    }

    private func show(_ frozen: [Frozen], mode: Mode, live: Bool) {
        let windowList = mode == .area ? [] : Capture.visibleWindows()
        for f in frozen {
            let w = OverlayWindow(contentRect: f.screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.setFrame(f.screen.frame, display: false)
            w.level = .screenSaver
            w.isOpaque = !live
            w.backgroundColor = live ? .clear : .black
            w.hasShadow = false
            w.isReleasedWhenClosed = false
            w.acceptsMouseMovedEvents = true
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let view = OverlayView(frame: NSRect(origin: .zero, size: f.screen.frame.size), frozen: f, mode: mode, live: live, windows: windowList, owner: self)
            w.contentView = view
            w.makeKeyAndOrderFront(nil)
            w.makeFirstResponder(view)
            windows.append(w)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    fileprivate func finish(_ result: Result) {
        guard let c = continuation else { return }
        continuation = nil
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        SelectionOverlay.current = nil
        c.resume(returning: result)
    }
}

private final class OverlayView: NSView {
    let frozen: Frozen
    let mode: SelectionOverlay.Mode
    /// Live selection: the real screen shows through instead of a frozen copy.
    let live: Bool
    let windowRects: [(id: CGWindowID, rect: CGRect)] // view coordinates
    private let windowPIDs: [CGWindowID: pid_t]
    /// Element mode: the element under the cursor and its ancestors (view coordinates), smallest first; ↑ / ↓ move along it.
    private var elementChain: [CGRect] = []
    private var elementIndex = 0
    unowned let owner: SelectionOverlay

    /// Handle direction: -1 = left/top edge, 0 = middle, 1 = right/bottom edge.
    private struct Handle { var dx: Int; var dy: Int }
    private enum Adjust { case move(last: CGPoint), resize(Handle, original: CGRect) }

    private var dragStart: CGPoint?
    private var mouse: CGPoint?
    private var hover: (id: CGWindowID, rect: CGRect)?
    private var locked: CGRect?       // selection waiting for confirmation (adjust mode)
    private var adjust: Adjust?
    private var spaceDown = false

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(frame: NSRect, frozen: Frozen, mode: SelectionOverlay.Mode, live: Bool, windows: [WindowInfo], owner: SelectionOverlay) {
        self.frozen = frozen
        self.mode = mode
        self.live = live
        self.owner = owner
        windowPIDs = Dictionary(windows.map { ($0.id, $0.pid) }, uniquingKeysWith: { a, _ in a })
        let sf = frozen.screen.frame
        windowRects = windows.filter { $0.rect.intersects(sf) }.map { w in
            (w.id, CGRect(x: w.rect.minX - sf.minX, y: sf.maxY - w.rect.maxY, width: w.rect.width, height: w.rect.height))
        }
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    private var creationRect: CGRect? {
        guard let s = dragStart, let m = mouse else { return nil }
        return CGRect(x: min(s.x, m.x), y: min(s.y, m.y), width: abs(m.x - s.x), height: abs(m.y - s.y))
    }

    private var selection: CGRect? { locked ?? creationRect }

    private var pixelScale: CGFloat { live ? frozen.screen.backingScaleFactor : CGFloat(frozen.image.width) / bounds.width }

    // MARK: Handles

    private func handlePoints(_ r: CGRect) -> [(Handle, CGPoint)] {
        var out: [(Handle, CGPoint)] = []
        for dy in -1...1 { for dx in -1...1 where !(dx == 0 && dy == 0) {
            out.append((Handle(dx: dx, dy: dy), CGPoint(x: dx < 0 ? r.minX : (dx > 0 ? r.maxX : r.midX),
                                                        y: dy < 0 ? r.minY : (dy > 0 ? r.maxY : r.midY))))
        } }
        return out
    }

    private func handle(at p: CGPoint, in r: CGRect) -> Handle? {
        handlePoints(r).first { hypot($0.1.x - p.x, $0.1.y - p.y) <= 9 }?.0
    }

    private func resized(_ r: CGRect, handle h: Handle, to p: CGPoint) -> CGRect {
        var x0 = r.minX, x1 = r.maxX, y0 = r.minY, y1 = r.maxY
        if h.dx < 0 { x0 = p.x } else if h.dx > 0 { x1 = p.x }
        if h.dy < 0 { y0 = p.y } else if h.dy > 0 { y1 = p.y }
        return CGRect(x: min(x0, x1), y: min(y0, y1), width: abs(x1 - x0), height: abs(y1 - y0)).intersection(bounds)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        if !live { ctx.drawFlipped(frozen.image, in: bounds) }
        let highlight = mode == .area ? selection : (mode == .element ? elementChain[safe: elementIndex] : hover?.rect)
        // A live overlay stays slightly opaque so it keeps receiving clicks even with no dimming.
        ctx.setFillColor(NSColor.black.withAlphaComponent(live ? max(0.02, Overlay.dim) : Overlay.dim).cgColor)
        if live, let r = highlight, r.width > 0, r.height > 0 {
            let cut = CGMutablePath()
            cut.addRect(bounds); cut.addRect(r)
            ctx.addPath(cut)
            ctx.fillPath(using: .evenOdd)
        } else {
            ctx.fill(bounds)
        }
        if let r = highlight, r.width > 0, r.height > 0 {
            if !live {
                ctx.saveGState()
                ctx.clip(to: r)
                ctx.drawFlipped(frozen.image, in: bounds)
                ctx.restoreGState()
            }
            ctx.setStrokeColor(NSColor.white.cgColor)
            ctx.setLineWidth(1)
            ctx.stroke(r.insetBy(dx: 0.5, dy: 0.5))
            if mode == .element {
                drawLabel("\(Int(r.width)) × \(Int(r.height))  ↑↓", near: CGPoint(x: r.midX, y: r.maxY + 10), in: ctx)
            }
            if mode == .area {
                let hint = locked != nil ? "  ↩ capture" : ""
                drawLabel("\(Int(r.width)) × \(Int(r.height))\(hint)", near: CGPoint(x: r.midX, y: r.maxY + 10), in: ctx)
            }
            if locked != nil {
                for (_, pt) in handlePoints(r) {
                    let hr = CGRect(x: pt.x - 4.5, y: pt.y - 4.5, width: 9, height: 9)
                    ctx.setFillColor(NSColor.white.cgColor)
                    ctx.fillEllipse(in: hr)
                    ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.5).cgColor)
                    ctx.strokeEllipse(in: hr)
                }
            }
        }

        if mode == .area, let m = mouse {
            if dragStart == nil && locked == nil {
                ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.55).cgColor)
                ctx.setLineWidth(1)
                ctx.move(to: CGPoint(x: 0, y: m.y + 0.5)); ctx.addLine(to: CGPoint(x: bounds.width, y: m.y + 0.5))
                ctx.move(to: CGPoint(x: m.x + 0.5, y: 0)); ctx.addLine(to: CGPoint(x: m.x + 0.5, y: bounds.height))
                ctx.strokePath()
            }
            if Overlay.showLoupe && !live { drawLoupe(at: m, in: ctx) }
        }
    }

    private func drawLabel(_ text: String, near p: CGPoint, in ctx: CGContext) {
        let s = NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white,
        ])
        let size = s.size()
        var box = CGRect(x: p.x - size.width / 2 - 6, y: p.y, width: size.width + 12, height: size.height + 6)
        box.origin.x = max(4, min(bounds.width - box.width - 4, box.origin.x))
        box.origin.y = min(bounds.height - box.height - 4, box.origin.y)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.75).cgColor)
        ctx.addPath(CGPath(roundedRect: box, cornerWidth: 6, cornerHeight: 6, transform: nil))
        ctx.fillPath()
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        s.draw(at: CGPoint(x: box.minX + 6, y: box.minY + 3))
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Pixel magnifier next to the cursor, with coordinates.
    private func drawLoupe(at m: CGPoint, in ctx: CGContext) {
        let cells = Overlay.loupeCells, size = Overlay.loupeSize
        let px = Int(m.x * pixelScale), py = Int(m.y * pixelScale)
        let src = CGRect(x: px - cells / 2, y: py - cells / 2, width: cells, height: cells)
        guard CGRect(x: 0, y: 0, width: frozen.image.width, height: frozen.image.height).contains(src),
              let crop = frozen.image.cropping(to: src) else { return }

        var origin = CGPoint(x: m.x + 22, y: m.y + 22)
        if origin.x + size > bounds.width - 4 { origin.x = m.x - 22 - size }
        if origin.y + size + 24 > bounds.height - 4 { origin.y = m.y - 22 - size - 24 }
        let box = CGRect(origin: origin, size: CGSize(width: size, height: size))

        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: box, cornerWidth: 8, cornerHeight: 8, transform: nil))
        ctx.clip()
        ctx.interpolationQuality = .none
        ctx.drawFlipped(crop, in: box)
        let cell = size / CGFloat(cells)
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(1.5)
        ctx.stroke(CGRect(x: box.minX + cell * CGFloat(cells / 2), y: box.minY + cell * CGFloat(cells / 2), width: cell, height: cell))
        ctx.restoreGState()
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.8).cgColor)
        ctx.setLineWidth(1)
        ctx.addPath(CGPath(roundedRect: box, cornerWidth: 8, cornerHeight: 8, transform: nil))
        ctx.strokePath()
        drawLabel("\(px), \(py)", near: CGPoint(x: box.midX, y: box.maxY + 4), in: ctx)
    }

    // MARK: Events

    override func mouseMoved(with event: NSEvent) {
        mouse = convert(event.locationInWindow, from: nil)
        if mode == .window { hover = windowRects.first { $0.rect.contains(mouse!) } }
        if mode == .element { updateElementChain(at: mouse!) }
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        mouse = p
        if mode == .element {
            updateElementChain(at: p)
            if let r = elementChain[safe: elementIndex] { confirm(r) }
            return
        }
        if mode == .window {
            if let h = hover ?? windowRects.first(where: { $0.rect.contains(p) }) { owner.finish(.window(h.id)) }
            return
        }
        if let r = locked {
            if event.clickCount == 2, r.contains(p) { confirm(r); return }
            if let h = handle(at: p, in: r) { adjust = .resize(h, original: r); return }
            if r.contains(p) { adjust = .move(last: p); return }
            locked = nil // click outside: start over
        }
        dragStart = p
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        defer { mouse = p; needsDisplay = true }
        switch adjust {
        case let .move(last)?:
            guard var r = locked else { return }
            r.origin.x = max(0, min(bounds.width - r.width, r.origin.x + p.x - last.x))
            r.origin.y = max(0, min(bounds.height - r.height, r.origin.y + p.y - last.y))
            locked = r
            adjust = .move(last: p)
        case let .resize(h, original)?:
            locked = resized(original, handle: h, to: p)
        case nil:
            // Holding Space while dragging moves the whole selection instead of resizing it.
            if spaceDown, let s = dragStart, let m = mouse {
                dragStart = CGPoint(x: s.x + p.x - m.x, y: s.y + p.y - m.y)
            }
        }
    }

    /// Asks the app owning the window under `p` for the element there; falls back to the window itself.
    private func updateElementChain(at p: CGPoint) {
        let sf = frozen.screen.frame
        guard let w = windowRects.first(where: { $0.rect.contains(p) }), let pid = windowPIDs[w.id] else { elementChain = []; needsDisplay = true; return }
        // View (top-left, screen-local) -> global coordinates with a top-left origin, as the Accessibility API expects.
        let originY = Capture.primaryHeight - sf.maxY
        let cgPoint = CGPoint(x: sf.minX + p.x, y: originY + p.y)
        let rects = ElementPicker.chain(at: cgPoint, pid: pid).map {
            CGRect(x: $0.minX - sf.minX, y: $0.minY - originY, width: $0.width, height: $0.height).intersection(bounds)
        }.filter { !$0.isNull && $0.width >= 4 && $0.height >= 4 }
        let chain = rects + [w.rect]
        if chain != elementChain { elementChain = chain; elementIndex = 0 }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard mode == .area else { return }
        let p = convert(event.locationInWindow, from: nil)
        if adjust != nil { adjust = nil; mouse = p; needsDisplay = true; return }
        mouse = p
        guard let r = creationRect, r.width >= 3, r.height >= 3 else {
            dragStart = nil
            needsDisplay = true
            return
        }
        dragStart = nil
        if Pref.bool("areaAdjust") {
            locked = r
            needsDisplay = true
        } else {
            confirm(r)
        }
    }

    private func confirm(_ r: CGRect) {
        let k = pixelScale
        let px = CGRect(x: r.minX * k, y: r.minY * k, width: r.width * k, height: r.height * k).integral
        let sf = frozen.screen.frame
        let global = CGRect(x: sf.minX + r.minX, y: sf.maxY - r.maxY, width: r.width, height: r.height)
        let end = mouse ?? CGPoint(x: r.maxX, y: r.maxY)
        owner.finish(.area(frozen, px, global, CGPoint(x: sf.minX + end.x, y: sf.maxY - end.y)))
    }

    override func rightMouseDown(with event: NSEvent) { owner.finish(.cancelled) }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: owner.finish(.cancelled)
        case 36, 76: if let r = locked { confirm(r) }
        case 49: spaceDown = true
        case 125 where mode == .element, 126 where mode == .element:
            elementIndex = max(0, min(elementChain.count - 1, elementIndex + (event.keyCode == 126 ? 1 : -1)))
            needsDisplay = true
        case 123, 124, 125, 126:
            guard var r = locked else { return super.keyDown(with: event) }
            let d: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
            switch event.keyCode {
            case 123: r.origin.x -= d
            case 124: r.origin.x += d
            case 125: r.origin.y += d
            default: r.origin.y -= d
            }
            locked = r.intersection(bounds).width == r.width && r.intersection(bounds).height == r.height ? r : locked
            needsDisplay = true
        default: super.keyDown(with: event)
        }
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49 { spaceDown = false } else { super.keyUp(with: event) }
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
