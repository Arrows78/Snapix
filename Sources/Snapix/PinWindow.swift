import AppKit

/// A screenshot floating above every other window.
@MainActor
final class PinController: NSObject, NSWindowDelegate {
    private static var pins: [PinController] = []

    private let panel: PinPanel
    private let shot: Shot
    private let view: PinView

    static func pin(_ shot: Shot) {
        let c = PinController(shot: shot)
        pins.append(c)
        c.panel.orderFrontRegardless()
    }

    private init(shot: Shot) {
        self.shot = shot
        let size = NSSize(width: CGFloat(shot.image.width) / shot.scale, height: CGFloat(shot.image.height) / shot.scale)
        view = PinView(frame: NSRect(origin: .zero, size: size), image: shot.image)
        panel = PinPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel, .resizable],
                         backing: .buffered, defer: false)
        super.init()

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = Pref.bool("pinsOnTop") ? .floating : .normal
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.contentView = view
        panel.contentAspectRatio = size
        panel.delegate = self
        view.owner = self

        if let r = shot.screenRect {
            panel.setFrameOrigin(r.origin)
        } else if let s = NSScreen.main {
            panel.setFrameOrigin(NSPoint(x: s.frame.midX - size.width / 2, y: s.frame.midY - size.height / 2))
        }
    }

    func close() {
        panel.orderOut(nil)
        PinController.pins.removeAll { $0 === self }
    }

    func copy() { Exporter.copy(shot.image, scale: shot.scale) }
    func save() { Exporter.save(shot.image, scale: shot.scale) }
    func edit() { EditorWindowController.open(shot); close() }
    func setOpacity(_ v: CGFloat) { panel.alphaValue = v }

    func zoom(by factor: CGFloat) {
        var f = panel.frame
        let newW = max(60, f.width * factor)
        let ratio = newW / f.width
        let center = NSPoint(x: f.midX, y: f.midY)
        f.size = NSSize(width: newW, height: f.height * ratio)
        f.origin = NSPoint(x: center.x - f.width / 2, y: center.y - f.height / 2)
        panel.setFrame(f, display: true)
    }

    func windowWillClose(_ notification: Notification) { PinController.pins.removeAll { $0 === self } }
}

private final class PinPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private final class PinView: NSView {
    weak var owner: PinController?
    private let image: CGImage
    private var hovering = false

    init(frame: NSRect, image: CGImage) {
        self.image = image
        super.init(frame: frame)
        wantsLayer = true
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }
    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }

    private var closeRect: CGRect { CGRect(x: 6, y: 6, width: 20, height: 20) }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: bounds, cornerWidth: 6, cornerHeight: 6, transform: nil))
        ctx.clip()
        ctx.interpolationQuality = .high
        ctx.drawFlipped(image, in: bounds)
        ctx.restoreGState()
        guard hovering else { return }
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.8).cgColor)
        ctx.setLineWidth(1.5)
        ctx.addPath(CGPath(roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75), cornerWidth: 6, cornerHeight: 6, transform: nil))
        ctx.strokePath()
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.7).cgColor)
        ctx.fillEllipse(in: closeRect)
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(1.5)
        let r = closeRect.insetBy(dx: 6, dy: 6)
        ctx.move(to: CGPoint(x: r.minX, y: r.minY)); ctx.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        ctx.move(to: CGPoint(x: r.maxX, y: r.minY)); ctx.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        ctx.strokePath()
    }

    override func mouseDown(with event: NSEvent) {
        if closeRect.contains(convert(event.locationInWindow, from: nil)) { owner?.close(); return }
        if event.clickCount == 2 { owner?.edit(); return }
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { owner?.close() } else { super.keyDown(with: event) }
    }

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.option), let w = window {
            w.alphaValue = max(0.1, min(1, w.alphaValue + event.scrollingDeltaY * 0.01))
        } else {
            owner?.zoom(by: 1 + event.scrollingDeltaY * 0.01)
        }
    }

    override func magnify(with event: NSEvent) { owner?.zoom(by: 1 + event.magnification) }

    override func menu(for event: NSEvent) -> NSMenu? {
        let m = NSMenu()
        func add(_ title: String, _ action: @escaping () -> Void) {
            let item = NSMenuItem(title: title, action: #selector(runBlock(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = action
            m.addItem(item)
        }
        add(L("Copy")) { [weak self] in self?.owner?.copy() }
        add(L("Save")) { [weak self] in self?.owner?.save() }
        add(L("Open in Editor")) { [weak self] in self?.owner?.edit() }
        m.addItem(.separator())
        for pct in [100, 75, 50, 25] { add(LF("Opacity %d%%", pct)) { [weak self] in self?.owner?.setOpacity(CGFloat(pct) / 100) } }
        m.addItem(.separator())
        add(L("Close")) { [weak self] in self?.owner?.close() }
        return m
    }

    @objc private func runBlock(_ sender: NSMenuItem) { (sender.representedObject as? () -> Void)?() }
}
