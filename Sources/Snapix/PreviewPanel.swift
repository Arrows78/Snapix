import AppKit

private final class PreviewWindow: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Six dots at the top of the preview: grab and drag to drop the image elsewhere.
private final class GripView: NSView {
    var onDrag: ((NSEvent) -> Void)?

    override func draw(_ dirtyRect: NSRect) {
        NSColor(white: 1, alpha: 0.45).setFill()
        let d: CGFloat = 4, gap: CGFloat = 8
        for i in 0..<4 { NSBezierPath(ovalIn: NSRect(x: CGFloat(i) * (d + gap) + 1, y: bounds.maxY - d - 2, width: d, height: d)).fill() }
        for i in 0..<2 { NSBezierPath(ovalIn: NSRect(x: CGFloat(i) * (d + gap) + (d + gap) / 2 + 1 + (d + gap) / 2, y: 2, width: d, height: d)).fill() }
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func mouseDown(with event: NSEvent) {}
    override func mouseDragged(with event: NSEvent) { onDrag?(event) }
}

/// The captured image: click to open the editor, drag to drop it somewhere.
private final class ThumbView: NSView {
    let image: CGImage
    var onClick: (() -> Void)?
    var onDrag: ((NSEvent) -> Void)?
    private var downPoint: CGPoint?
    private var dragged = false

    init(frame: NSRect, image: CGImage) {
        self.image = image
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let path = CGPath(roundedRect: bounds, cornerWidth: 8, cornerHeight: 8, transform: nil)
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        ctx.interpolationQuality = .high
        ctx.draw(image, in: bounds)
        ctx.restoreGState()
        ctx.setStrokeColor(NSColor(white: 1, alpha: 0.18).cgColor)
        ctx.setLineWidth(1)
        ctx.addPath(CGPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 8, cornerHeight: 8, transform: nil))
        ctx.strokePath()
    }

    override func mouseDown(with event: NSEvent) { downPoint = event.locationInWindow; dragged = false }

    override func mouseDragged(with event: NSEvent) {
        guard let p = downPoint, !dragged, hypot(event.locationInWindow.x - p.x, event.locationInWindow.y - p.y) > 4 else { return }
        dragged = true
        onDrag?(event)
    }

    override func mouseUp(with event: NSEvent) { if !dragged { onClick?() } }
}

private final class PreviewContent: NSVisualEffectView, NSDraggingSource {
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        material = .hudWindow
        blendingMode = .behindWindow
        state = .active
        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true
        layer?.cornerRadius = 22
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(white: 1, alpha: 0.14).cgColor
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseEntered(with event: NSEvent) { onEnter?() }
    override func mouseExited(with event: NSEvent) { onExit?() }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
}

/// Floating thumbnail shown in the screen corner after a capture: edit, copy, save, recognise text, pin, close.
@MainActor
final class PreviewController: NSObject {
    private static var open: [PreviewController] = []
    private static let width: CGFloat = 232
    private static let margin: CGFloat = 20

    private let shot: Shot
    private let panel: PreviewWindow
    private let content: PreviewContent
    private let screen: NSScreen
    private let anchor: CGRect?
    private let anchorPoint: CGPoint?
    private let height: CGFloat
    private var closeWork: DispatchWorkItem?

    static func show(_ shot: Shot) {
        let c = PreviewController(shot: shot)
        open.append(c)
        c.present()
    }

    private init(shot: Shot) {
        self.shot = shot
        anchor = shot.placeAtRegion ? shot.screenRect : nil
        anchorPoint = shot.placeAtRegion ? shot.anchorPoint : nil
        let center = shot.screenRect.map { CGPoint(x: $0.midX, y: $0.midY) } ?? NSEvent.mouseLocation
        screen = NSScreen.screens.first { $0.frame.contains(center) } ?? NSScreen.main ?? NSScreen.screens[0]

        // Thumbnail box: fits 208 x 230 keeping the aspect ratio.
        let iw = CGFloat(shot.image.width), ih = CGFloat(shot.image.height)
        let k = min(208 / iw, 230 / ih, 1.5 / shot.scale * shot.scale)
        let tw = max(60, (iw * k).rounded()), th = max(40, (ih * k).rounded())
        height = 52 + th + 18 + 56
        let w = Self.width

        content = PreviewContent(frame: NSRect(x: 0, y: 0, width: w, height: height))
        panel = PreviewWindow(contentRect: content.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.contentView = content

        let close = IconButton(symbol: "xmark", tip: L("Close"), target: self, action: #selector(closeTapped), size: NSSize(width: 30, height: 28), pointSize: 13)
        close.translatesAutoresizingMaskIntoConstraints = true
        close.frame = NSRect(x: 12, y: height - 40, width: 30, height: 28)
        content.addSubview(close)

        let grip = GripView(frame: NSRect(x: (w - 44) / 2, y: height - 38, width: 44, height: 18))
        grip.onDrag = { [weak self] e in self?.beginDrag(e, from: grip) }
        content.addSubview(grip)

        let thumb = ThumbView(frame: NSRect(x: (w - tw) / 2, y: 56 + 4, width: tw, height: th), image: shot.image)
        thumb.onClick = { [weak self] in self?.edit() }
        thumb.onDrag = { [weak self] e in self?.beginDrag(e, from: thumb) }
        content.addSubview(thumb)

        let actions: [(String, String, Selector)] = [
            ("pencil", "Open in Editor", #selector(editTapped)),
            ("doc.on.doc", "Copy", #selector(copyTapped)),
            ("square.and.arrow.down", "Save", #selector(saveTapped)),
            ("text.viewfinder", "Recognize text / QR code", #selector(ocrTapped)),
            ("pin", "Pin to screen", #selector(pinTapped)),
        ]
        let bw: CGFloat = 40
        let gap = (w - 24 - bw * CGFloat(actions.count)) / CGFloat(actions.count - 1)
        for (i, a) in actions.enumerated() {
            let b = IconButton(symbol: a.0, tip: L(a.1), target: self, action: a.2, size: NSSize(width: bw, height: 36), pointSize: 17)
            b.translatesAutoresizingMaskIntoConstraints = true
            b.frame = NSRect(x: 12 + CGFloat(i) * (bw + gap), y: 14, width: bw, height: 36)
            content.addSubview(b)
        }

        content.onEnter = { [weak self] in self?.closeWork?.cancel() }
        content.onExit = { [weak self] in self?.scheduleClose() }
    }

    // MARK: Showing / hiding

    /// Preview next to the point where the selection ended: below-right of it, flipping left/above when there is no room.
    static func frame(near p: CGPoint, size: NSSize, visible vf: CGRect) -> NSRect {
        let gap: CGFloat = 16
        var o = NSPoint(x: p.x + gap, y: p.y - gap - size.height)
        if o.x + size.width > vf.maxX - 8 { o.x = p.x - gap - size.width }
        if o.y < vf.minY + 8 { o.y = p.y + gap }
        o.x = max(vf.minX + 8, min(vf.maxX - size.width - 8, o.x))
        o.y = max(vf.minY + 8, min(vf.maxY - size.height - 8, o.y))
        return NSRect(origin: o, size: size)
    }

    private func anchoredTarget(size: NSSize, visible vf: CGRect) -> NSRect? {
        if let p = anchorPoint { return Self.frame(near: p, size: size, visible: vf) }
        if let r = anchor { return Self.anchoredFrame(region: r, size: size, visible: vf) }
        return nil
    }

    /// Where a preview for a captured region goes: inside its bottom-right corner when it fits, otherwise beside it
    /// (right, left, then below), always kept on screen.
    static func anchoredFrame(region r: CGRect, size: NSSize, visible vf: CGRect) -> NSRect {
        let m: CGFloat = 12
        var o: NSPoint
        if r.width >= size.width + 2 * m && r.height >= size.height + 2 * m {
            o = NSPoint(x: r.maxX - size.width - m, y: r.minY + m)
        } else if r.maxX + m + size.width <= vf.maxX {
            o = NSPoint(x: r.maxX + m, y: r.minY)
        } else if r.minX - m - size.width >= vf.minX {
            o = NSPoint(x: r.minX - m - size.width, y: r.minY)
        } else {
            o = NSPoint(x: r.maxX - size.width, y: r.minY - size.height - m)
        }
        o.x = max(vf.minX + m, min(vf.maxX - size.width - m, o.x))
        o.y = max(vf.minY + m, min(vf.maxY - size.height - m, o.y))
        return NSRect(origin: o, size: size)
    }

    private func present() {
        let vf = screen.visibleFrame
        if var start = anchoredTarget(size: NSSize(width: Self.width, height: height), visible: vf) {
            // Fade in on the spot, rising a few points.
            start.origin.y -= 14
            panel.setFrame(start, display: false)
        } else {
            // Corner previews slide in from the right edge.
            panel.setFrame(NSRect(x: vf.maxX, y: vf.minY + Self.margin, width: Self.width, height: height), display: false)
        }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        Self.layoutAll()
        scheduleClose()
    }

    /// Stacks previews bottom-up in the corner of their screen (newest at the bottom).
    private static func layoutAll() {
        var offsets: [ObjectIdentifier: CGFloat] = [:]
        for c in open.reversed() {
            let key = ObjectIdentifier(c.screen)
            let y = offsets[key] ?? 0
            let vf = c.screen.visibleFrame
            let target: NSRect
            if let t = c.anchoredTarget(size: NSSize(width: width, height: c.height), visible: vf) {
                target = t
            } else {
                target = NSRect(x: vf.maxX - width - margin, y: vf.minY + margin + y, width: width, height: c.height)
                offsets[key] = y + c.height + 12
            }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.28
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                c.panel.animator().setFrame(target, display: true)
                c.panel.animator().alphaValue = 1
            }
        }
    }

    private func scheduleClose() {
        closeWork?.cancel()
        let setting = Pref.string("previewClosing")
        guard setting != "never", let secs = Double(setting) else { return }
        let work = DispatchWorkItem { [weak self] in self?.dismiss() }
        closeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + secs, execute: work)
    }

    private func dismiss() {
        closeWork?.cancel()
        guard Self.open.contains(where: { $0 === self }) else { return }
        Self.open.removeAll { $0 === self }
        let vf = screen.visibleFrame
        var out = panel.frame
        if anchor != nil || anchorPoint != nil { out.origin.y -= 14 } else { out.origin.x = vf.maxX + 10 }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.22
            panel.animator().setFrame(out, display: true)
            panel.animator().alphaValue = 0
        }, completionHandler: { [panel] in panel.orderOut(nil) })
        Self.layoutAll()
    }

    // MARK: Actions

    private func beginDrag(_ event: NSEvent, from view: NSView) {
        closeWork?.cancel()
        ImageDrag.begin(from: view, source: content, event: event, image: shot.image, scale: shot.scale)
    }

    private func edit() { EditorWindowController.open(shot); dismiss() }

    @objc private func closeTapped() { dismiss() }
    @objc private func editTapped() { edit() }
    @objc private func copyTapped() { Exporter.copy(shot.image, scale: shot.scale); scheduleClose() }
    @objc private func saveTapped() { Exporter.save(shot.image, scale: shot.scale); scheduleClose() }
    @objc private func ocrTapped() { OCR.recognizeAndCopy(shot.image); scheduleClose() }
    @objc private func pinTapped() { PinController.pin(shot); dismiss() }
}
