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
    /// Receives a key typed while the pointer is over the preview; returns true when handled.
    var onKey: ((NSEvent) -> Bool)?
    /// Called with the horizontal direction (-1 left, 1 right) after a two-finger swipe.
    var onSwipe: ((CGFloat) -> Void)?
    private var swipeSum: CGFloat = 0

    override func scrollWheel(with event: NSEvent) {
        guard Pref.bool("previewSwipe"), event.hasPreciseScrollingDeltas, abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) * 0.8 || swipeSum != 0 else {
            super.scrollWheel(with: event); return
        }
        swipeSum += event.scrollingDeltaX
        if event.phase == .ended || event.phase == .cancelled {
            let sum = swipeSum
            swipeSum = 0
            if abs(sum) > 90 { onSwipe?(sum > 0 ? 1 : -1) }
        }
    }

    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) { if onKey?(event) != true { super.keyDown(with: event) } }

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

    override func mouseEntered(with event: NSEvent) { window?.makeKey(); window?.makeFirstResponder(self); onEnter?() }
    override func mouseExited(with event: NSEvent) { onExit?() }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
}

/// Floating thumbnail shown in the screen corner after a capture: edit, copy, save, recognise text, pin, close.
@MainActor
final class PreviewController: NSObject {
    private static var open: [PreviewController] = []
    private static var scaleFactor: CGFloat {
        switch Pref.string("previewSize") { case "small": return 0.8; case "large": return 1.25; default: return 1 }
    }
    private static var width: CGFloat { (232 * scaleFactor).rounded() }
    private static let margin: CGFloat = 20
    /// Quick Access (re-shown Library items) stays until dismissed.
    private let persistent: Bool
    private static var showingRecent = false

    private let shot: Shot
    private let panel: PreviewWindow
    private let content: PreviewContent
    private let screen: NSScreen
    private let anchor: CGRect?
    private let anchorPoint: CGPoint?
    private let height: CGFloat
    private var closeWork: DispatchWorkItem?
    /// Extra horizontal travel when a swipe dismissed the card, so it leaves in the swipe direction.
    private var swipeShift: CGFloat = 0

    static func show(_ shot: Shot, persistent: Bool = false) {
        let c = PreviewController(shot: shot, persistent: persistent)
        open.append(c)
        c.present()
    }

    /// Quick Access: the latest Library captures stacked in the corner, or closed again when already shown.
    static func toggleRecent() {
        if showingRecent { dismissAll(); return }
        let urls = Array(History.items().prefix(4))
        guard !urls.isEmpty else { Toast.show(L("Screenshots you take will appear here."), symbol: "exclamationmark.triangle.fill"); return }
        showingRecent = true
        // Oldest first so the newest ends up nearest the corner.
        for url in urls.reversed() { if let s = History.shot(for: url) { show(s, persistent: true) } }
    }

    static func dismissAll() {
        showingRecent = false
        for c in open { c.dismiss() }
    }

    private init(shot: Shot, persistent: Bool) {
        self.persistent = persistent
        self.shot = shot
        anchor = shot.placeAtRegion ? shot.screenRect : nil
        anchorPoint = shot.placeAtRegion ? shot.anchorPoint : nil
        let center = shot.screenRect.map { CGPoint(x: $0.midX, y: $0.midY) } ?? NSEvent.mouseLocation
        screen = NSScreen.screens.first { $0.frame.contains(center) } ?? NSScreen.main ?? NSScreen.screens[0]

        // Thumbnail box: fits 208 x 230 keeping the aspect ratio.
        let iw = CGFloat(shot.image.width), ih = CGFloat(shot.image.height)
        let f = Self.scaleFactor
        let k = min(208 * f / iw, 230 * f / ih, 1.5)
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

        let actions: [(String, String, Selector)] = shot.fileURL != nil ? [
            ("play.fill", "Open", #selector(editTapped)),
            ("doc.on.doc", "Copy as File", #selector(copyFileTapped)),
            ("folder", "Reveal in Finder", #selector(revealTapped)),
            ("square.and.arrow.up", "Share…", #selector(shareTapped(_:))),
            ("trash", "Move to Trash", #selector(deleteTapped)),
            ("ellipsis", "More tools and actions", #selector(moreTapped(_:))),
        ] : [
            ("pencil", "Open in Editor", #selector(editTapped)),
            ("doc.on.doc", "Copy", #selector(copyTapped)),
            ("square.and.arrow.down", "Save", #selector(saveTapped)),
            ("text.viewfinder", "Recognize text / QR code", #selector(ocrTapped)),
            ("pin", "Pin to screen", #selector(pinTapped)),
            ("ellipsis", "More tools and actions", #selector(moreTapped(_:))),
        ]
        let bw: CGFloat = 32
        let gap = max(0, (w - 24 - bw * CGFloat(actions.count)) / CGFloat(actions.count - 1))
        for (i, a) in actions.enumerated() {
            let b = IconButton(symbol: a.0, tip: L(a.1), target: self, action: a.2, size: NSSize(width: bw, height: 36), pointSize: 15)
            b.translatesAutoresizingMaskIntoConstraints = true
            b.frame = NSRect(x: 12 + CGFloat(i) * (bw + gap), y: 14, width: bw, height: 36)
            content.addSubview(b)
        }

        content.onKey = { [weak self] e in self?.handleKey(e) ?? false }
        content.onSwipe = { [weak self] dir in self?.performSwipe(dir) }
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

    private enum Corner {
        case bottomRight, bottomLeft, topRight, topLeft, centerTop, centerBottom
        init() { self = Corner(rawValue: Pref.string("previewCorner")) ?? .bottomRight }
        init?(rawValue: String) {
            switch rawValue {
            case "bottomRight": self = .bottomRight
            case "bottomLeft": self = .bottomLeft
            case "topRight": self = .topRight
            case "topLeft": self = .topLeft
            case "centerTop": self = .centerTop
            case "centerBottom": self = .centerBottom
            default: return nil
            }
        }
        var onRight: Bool { self == .bottomRight || self == .topRight }
        var onBottom: Bool { self == .bottomRight || self == .bottomLeft || self == .centerBottom }
        var centered: Bool { self == .centerTop || self == .centerBottom }
    }

    private func present() {
        let vf = screen.visibleFrame
        let corner = Corner()
        if var start = anchoredTarget(size: NSSize(width: Self.width, height: height), visible: vf) {
            // Fade in on the spot, rising a few points.
            start.origin.y -= 14
            panel.setFrame(start, display: false)
        } else {
            // Corner previews slide in from the right edge.
            let fade = Pref.string("previewAnimation") == "fade"
            let restX = corner.centered ? vf.midX - Self.width / 2 : (corner.onRight ? vf.maxX - Self.width - Self.margin : vf.minX + Self.margin)
            let restY = corner.onBottom ? vf.minY + Self.margin : vf.maxY - Self.margin - height
            let startX = fade || corner.centered ? restX : (corner.onRight ? vf.maxX : vf.minX - Self.width)
            var startY = restY
            if fade { startY -= 14 } else if corner.centered { startY = corner.onBottom ? vf.minY - height : vf.maxY }
            panel.setFrame(NSRect(x: startX, y: startY, width: Self.width, height: height), display: false)
        }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        if Pref.bool("quickAccessSounds") { NSSound(named: "Pop")?.play() }
        Self.layoutAll()
        scheduleClose()
    }

    /// Stacks previews bottom-up in the corner of their screen (newest at the bottom).
    private static func layoutAll() {
        var offsets: [ObjectIdentifier: CGFloat] = [:]
        let corner = Corner()
        for c in open.reversed() {
            let key = ObjectIdentifier(c.screen)
            let y = offsets[key] ?? 0
            let vf = c.screen.visibleFrame
            let target: NSRect
            if let t = c.anchoredTarget(size: NSSize(width: width, height: c.height), visible: vf) {
                target = t
            } else {
                let x = corner.centered ? vf.midX - width / 2 : (corner.onRight ? vf.maxX - width - margin : vf.minX + margin)
                let ty = corner.onBottom ? vf.minY + margin + y : vf.maxY - margin - y - c.height
                target = NSRect(x: x, y: ty, width: width, height: c.height)
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
        guard !persistent else { return }
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
        let corner = Corner()
        if anchor != nil || anchorPoint != nil || Pref.string("previewAnimation") == "fade" { out.origin.y -= 14 }
        else if corner.centered { out.origin.y = corner.onBottom ? vf.minY - out.height : vf.maxY }
        else { out.origin.x = corner.onRight ? vf.maxX + 10 : vf.minX - out.width - 10 }
        out.origin.x += swipeShift
        if Self.open.isEmpty { Self.showingRecent = false }
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
        if let file = shot.fileURL { ImageDrag.beginFile(from: view, source: content, event: event, url: file, preview: shot.image) }
        else { ImageDrag.begin(from: view, source: content, event: event, image: shot.image, scale: shot.scale) }
    }

    private func edit() {
        if let file = shot.fileURL { NSWorkspace.shared.open(file) } else { EditorWindowController.open(shot) }
        dismiss()
    }

    /// Runs the action chosen in Preferences for a swipe to the right (dir > 0) or the left.
    private func performSwipe(_ dir: CGFloat) {
        let action = Pref.string(dir > 0 ? "previewSwipeRight" : "previewSwipeLeft")
        let isFile = shot.fileURL != nil
        switch action {
        case "none": break
        case "save": if isFile { revealTapped() } else { saveTapped() }
        case "copy": if isFile { copyFileTapped() } else { copyTapped() }
        case "edit": edit()
        case "pin": if isFile { dismiss() } else { pinTapped() }
        default: swipeShift = dir * 160; dismiss()
        }
    }

    /// Typed while hovering: ⌘C copy, ⌘S save, ⌘E or Return edit, ⌘P pin, ⌫ delete from the Library, Esc close.
    private func handleKey(_ e: NSEvent) -> Bool {
        let cmd = e.modifierFlags.contains(.command)
        switch (e.charactersIgnoringModifiers ?? "", e.keyCode) {
        case (_, 53): dismiss()
        case (_, 36): edit()
        case ("c", _) where cmd: if shot.fileURL != nil { copyFileTapped() } else { copyTapped() }
        case ("s", _) where cmd: saveTapped()
        case ("e", _) where cmd: edit()
        case ("p", _) where cmd: pinTapped()
        case (_, 51), (_, 117): if shot.fileURL != nil { trashRecording() } else { deleteFromLibrary() }
        default: return false
        }
        return true
    }

    @objc private func moreTapped(_ sender: NSButton) {
        closeWork?.cancel()
        let menu = NSMenu()
        if shot.fileURL != nil {
            let i = NSMenuItem(title: L("Close All"), action: #selector(closeAllTapped), keyEquivalent: "")
            i.target = self
            menu.addItem(i)
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
            scheduleClose()
            return
        }
        func add(_ title: String, _ sel: Selector, _ symbol: String) {
            let i = NSMenuItem(title: L(title), action: sel, keyEquivalent: "")
            i.target = self
            i.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            menu.addItem(i)
        }
        add("Save As…", #selector(saveAsTapped), "square.and.arrow.down.on.square")
        add("Share…", #selector(shareTapped(_:)), "square.and.arrow.up")
        add("Copy as File", #selector(copyFileTapped), "doc.badge.arrow.up")
        add("Upload", #selector(uploadTapped), "icloud.and.arrow.up")
        add("Hide Sensitive Data", #selector(redactTapped), "eye.slash")
        menu.addItem(.separator())
        if shot.historyURL != nil { add("Delete from Library", #selector(deleteTapped), "trash") }
        add("Close All", #selector(closeAllTapped), "xmark.circle")
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
        scheduleClose()
    }

    private func deleteFromLibrary() {
        guard let url = shot.historyURL else { return }
        try? FileManager.default.removeItem(at: url)
        Toast.show(L("Deleted from the Library"), symbol: "checkmark.circle.fill")
        dismiss()
    }

    @objc private func saveAsTapped() { Exporter.saveAs(shot.image, scale: shot.scale, window: nil) }
    @objc private func shareTapped(_ sender: NSButton) {
        if let file = shot.fileURL {
            NSSharingServicePicker(items: [file]).show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            return
        }
        let size = NSSize(width: CGFloat(shot.image.width) / shot.scale, height: CGFloat(shot.image.height) / shot.scale)
        NSSharingServicePicker(items: [NSImage(cgImage: shot.image, size: size)]).show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
    }
    @objc private func revealTapped() { if let f = shot.fileURL { NSWorkspace.shared.activateFileViewerSelecting([f]) } }

    private func trashRecording() {
        guard let file = shot.fileURL else { return }
        try? FileManager.default.trashItem(at: file, resultingItemURL: nil)
        RecordingLog.remove(path: file.path)
        Toast.show(L("Moved to the Trash"), symbol: "checkmark.circle.fill")
        dismiss()
    }

    @objc private func copyFileTapped() {
        if let file = shot.fileURL {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([file as NSURL])
            Toast.show(L("Copied as file"), symbol: "checkmark.circle.fill")
            return
        }
        let prepared = Exporter.prepared(shot.image, scale: shot.scale)
        guard let (data, ext) = Exporter.encode(prepared.image, forceLossless: Exporter.hasTransparency(prepared.image)) else { return }
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("SnapixCopy", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(Exporter.filename(ext: ext))
        guard (try? data.write(to: url)) != nil else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([url as NSURL])
        Toast.show(L("Copied as file"), symbol: "checkmark.circle.fill")
    }
    @objc private func uploadTapped() { Exporter.upload(shot.image, scale: shot.scale) }
    /// Opens the editor with every sensitive piece of text already pixelated.
    @objc private func redactTapped() {
        Redaction.findBoxes(in: shot.image) { [shot] boxes in
            guard !boxes.isEmpty else { Toast.show(L("No sensitive data found")); return }
            var out = shot.image
            let doc = DocState(image: shot.image, annotations: boxes.map {
                let b = $0.insetBy(dx: -4, dy: -3)
                return Annotation(tool: .blur, p1: CGPoint(x: b.minX, y: b.minY), p2: CGPoint(x: b.maxX, y: b.maxY), color: .black, width: 8)
            })
            var plain = doc
            plain.backdrop.enabled = false
            if let img = Renderer.render(plain) { out = img }
            var redacted = shot
            redacted.image = out
            Exporter.copy(out, scale: shot.scale, quiet: true)
            Toast.show(LF("%d sensitive regions hidden", boxes.count) + " · " + L("Copied to the clipboard"), duration: 2.5, symbol: "checkmark.circle.fill")
            EditorWindowController.open(redacted)
        }
    }
    @objc private func deleteTapped() { if shot.fileURL != nil { trashRecording() } else { deleteFromLibrary() } }
    @objc private func closeAllTapped() { Self.dismissAll() }

    @objc private func closeTapped() { dismiss() }
    @objc private func editTapped() { edit() }
    @objc private func copyTapped() { Exporter.copy(shot.image, scale: shot.scale); cue(); scheduleClose() }
    @objc private func saveTapped() { Exporter.save(shot.image, scale: shot.scale); cue(); scheduleClose() }
    private func cue() { if Pref.bool("quickAccessSounds") { NSSound(named: "Tink")?.play() } }
    @objc private func ocrTapped() { OCR.recognizeAndCopy(shot.image); scheduleClose() }
    @objc private func pinTapped() { PinController.pin(shot); dismiss() }
}
