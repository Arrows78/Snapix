import AppKit
import SwiftUI

private final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposed: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposed)
        guard let doc = documentView else { return rect }
        if rect.width > doc.frame.width { rect.origin.x = (doc.frame.width - rect.width) / 2 }
        if rect.height > doc.frame.height { rect.origin.y = (doc.frame.height - rect.height) / 2 }
        return rect
    }
}

/// Drag from this button to drop the edited image into Finder, Mail, Slack, etc.
private final class ImageDragButton: NSButton, NSDraggingSource {
    var imageProvider: (() -> (image: CGImage, scale: CGFloat)?)?
    private var started = false

    override func mouseDown(with event: NSEvent) { started = false }

    override func mouseDragged(with event: NSEvent) {
        guard !started, let (img, scale) = imageProvider?() else { return }
        let prepared = Exporter.prepared(img, scale: scale)
        guard let (data, ext) = Exporter.encode(prepared.image, forceLossless: Exporter.hasTransparency(prepared.image)) else { return }
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("SnapixDrag", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(Exporter.filename(ext: ext))
        guard (try? data.write(to: url)) != nil else { return }
        started = true

        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        let preview = NSImage(cgImage: img, size: NSSize(width: 120, height: 120 * CGFloat(img.height) / CGFloat(max(1, img.width))))
        item.setDraggingFrame(NSRect(x: 0, y: 0, width: preview.size.width, height: preview.size.height), contents: preview)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
}

@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate {
    private static var open: [EditorWindowController] = []

    private let doc: Document
    private let canvas: CanvasView
    private let scroll = NSScrollView()
    private let toolControl = NSSegmentedControl()
    private let colorWell = NSColorWell(style: .minimal)
    private let widthSlider = NSSlider(value: 4, minValue: 1, maxValue: 30, target: nil, action: nil)
    private let styleButton = NSPopUpButton(frame: .zero, pullsDown: false)
    private let status = NSTextField(labelWithString: "")
    private var cursorInfo = ""
    private var backdropPopover: NSPopover?
    private var backdropModel: BackdropModel?

    // MARK: Entry points

    static func open(_ shot: Shot) {
        let c = EditorWindowController(shot: shot)
        open.append(c)
        NSApp.setActivationPolicy(.regular)
        c.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        c.fitToWindow()
    }

    static func openFromClipboard() {
        guard let img = NSImage(pasteboard: .general), let shot = Self.shot(from: img) else {
            Toast.show(L("No image in the clipboard"))
            return
        }
        open(shot)
    }

    static func openFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .gif, .heic, .tiff]
        panel.allowsMultipleSelection = true
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        openFiles(panel.urls)
    }

    static func openFiles(_ urls: [URL]) {
        for url in urls {
            if let img = NSImage(contentsOf: url), let shot = shot(from: img) { open(shot) }
        }
    }

    private static func shot(from image: NSImage) -> Shot? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let scale = image.size.width > 0 ? max(1, CGFloat(cg.width) / image.size.width) : 1
        return Shot(image: cg, scale: scale, screenRect: nil)
    }

    // MARK: Setup

    private init(shot: Shot) {
        doc = Document(image: shot.image, scale: shot.scale)
        canvas = CanvasView(doc: doc)

        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 900, height: 360)
        super.init(window: w)
        w.delegate = self
        w.title = "Snapix"
        w.setFrameAutosaveName("")

        doc.onChange = { [weak self] in self?.documentChanged() }
        canvas.onCursorMove = { [weak self] p, c in self?.updateCursor(p, c) }
        canvas.onEscape = { [weak self] in self?.finishWithEscape() }
        canvas.onToolShortcut = { [weak self] t in self?.selectTool(t) }
        canvas.onToggleBackdrop = { [weak self] in self?.toggleBackdrop() }
        canvas.onSelectionChanged = { [weak self] a in self?.selectionChanged(a) }
        canvas.color = NSColor(hex: 0xFF3B30)
        buildUI(in: w, size: shot)
        selectTool(.arrow)
        refreshTitle()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func symbolImage(_ name: String, _ tip: String) -> NSImage {
        let img = NSImage(systemSymbolName: name, accessibilityDescription: tip) ?? NSImage()
        return img
    }

    private func button(_ symbol: String, _ tip: String, _ action: Selector) -> NSButton {
        let b = NSButton(image: symbolImage(symbol, tip), target: self, action: action)
        b.bezelStyle = .texturedRounded
        b.toolTip = L(tip)
        b.imagePosition = .imageOnly
        return b
    }

    private func dragButton() -> NSButton {
        let b = ImageDragButton(image: symbolImage("hand.draw", "Drag the image into another app"), target: nil, action: nil)
        b.bezelStyle = .texturedRounded
        b.imagePosition = .imageOnly
        b.toolTip = L("Drag the edited image into another app")
        b.imageProvider = { [weak self] in
            guard let self, let img = self.flattened() else { return nil }
            return (img, self.doc.scale)
        }
        return b
    }

    private func buildUI(in w: NSWindow, size shot: Shot) {
        let content = NSView()
        w.contentView = content

        toolControl.segmentCount = Tool.allCases.count
        toolControl.trackingMode = .selectOne
        toolControl.segmentStyle = .texturedRounded
        for (i, t) in Tool.allCases.enumerated() {
            toolControl.setImage(symbolImage(t.symbol, t.title), forSegment: i)
            toolControl.setWidth(28, forSegment: i)
            toolControl.setToolTip("\(t.title) (\(t.key.uppercased()))", forSegment: i)
        }
        toolControl.target = self
        toolControl.action = #selector(toolPicked(_:))

        colorWell.color = canvas.color
        colorWell.target = self
        colorWell.action = #selector(colorPicked(_:))
        colorWell.widthAnchor.constraint(equalToConstant: 38).isActive = true

        widthSlider.target = self
        widthSlider.action = #selector(widthPicked(_:))
        widthSlider.widthAnchor.constraint(equalToConstant: 90).isActive = true
        widthSlider.toolTip = L("Size / thickness")

        styleButton.target = self
        styleButton.action = #selector(stylePicked(_:))
        styleButton.controlSize = .small

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let bar = NSStackView(views: [
            toolControl, colorWell, widthSlider, styleButton, spacer,
            button("rectangle.dashed.badge.record", "Backdrop (K)", #selector(showBackdrop(_:))),
            button("text.viewfinder", "Recognize text / QR code", #selector(runOCR(_:))),
            button("arrow.uturn.backward", "Undo", #selector(undo(_:))),
            dragButton(),
            button("pin", "Pin to screen", #selector(pinImage(_:))),
            button("doc.on.doc", "Copy (⌘C)", #selector(copy(_:))),
            button("square.and.arrow.down", "Save (⌘S)", #selector(saveDocument(_:))),
        ])
        bar.orientation = .horizontal
        bar.spacing = 8
        bar.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)

        scroll.contentView = CenteringClipView()
        scroll.documentView = canvas
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.02
        scroll.maxMagnification = 32
        scroll.drawsBackground = true
        scroll.backgroundColor = .underPageBackgroundColor
        NotificationCenter.default.addObserver(self, selector: #selector(zoomChanged), name: NSScrollView.didEndLiveMagnifyNotification, object: scroll)

        status.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail

        for v in [bar, scroll, status] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: content.topAnchor),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: bar.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -4),
            status.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            status.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            status.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -4),
        ])

        let screen = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1400, height: 900)
        let natural = Renderer.canvasSize(doc.state)
        let k = 1 / doc.scale
        w.setContentSize(NSSize(width: min(max(natural.width * k + 40, 820), screen.width * 0.92),
                                height: min(max(natural.height * k + 100, 420), screen.height * 0.9)))
        w.center()
    }

    // MARK: Zoom

    private func fitToWindow() {
        let natural = Renderer.canvasSize(doc.state)
        let avail = scroll.contentSize
        guard natural.width > 0, natural.height > 0, avail.width > 0 else { return }
        let m = min(1 / doc.scale, (avail.width - 16) / natural.width, (avail.height - 16) / natural.height)
        scroll.magnification = max(scroll.minMagnification, m)
        zoomChanged()
    }

    @objc private func zoomChanged() { updateStatus() }

    @objc func zoomInAction(_ sender: Any?) { scroll.animator().magnification = min(scroll.maxMagnification, scroll.magnification * 1.25); zoomSoon() }
    @objc func zoomOutAction(_ sender: Any?) { scroll.animator().magnification = max(scroll.minMagnification, scroll.magnification / 1.25); zoomSoon() }
    @objc func zoomActualAction(_ sender: Any?) { scroll.animator().magnification = 1 / doc.scale; zoomSoon() }
    @objc func zoomFitAction(_ sender: Any?) { fitToWindow() }

    private func zoomSoon() { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.updateStatus() } }

    // MARK: State sync

    private func documentChanged() {
        canvas.documentChanged()
        refreshTitle()
        updateStatus()
    }

    private func refreshTitle() {
        window?.title = "Snapix — \(doc.state.image.width) × \(doc.state.image.height)"
    }

    private func updateCursor(_ p: CGPoint?, _ c: NSColor?) {
        if let p, let c { cursorInfo = "  ·  \(Int(p.x)), \(Int(p.y))  \(ColorFormat.hex.string(for: c))" } else { cursorInfo = "" }
        updateStatus()
    }

    private func updateStatus() {
        let pct = Int((scroll.magnification * (window?.backingScaleFactor ?? 2) * 100).rounded())
        var parts = "\(doc.state.image.width) × \(doc.state.image.height) px  ·  \(pct)%"
        if doc.state.backdrop.enabled { parts += "  ·  " + L("backdrop") }
        status.stringValue = parts + cursorInfo
    }

    private func selectionChanged(_ a: Annotation?) {
        guard let a else { return }
        colorWell.color = a.color
        widthSlider.doubleValue = Double(a.width)
        refreshStyleMenu(for: a.tool)
    }

    // MARK: Tool / style controls

    private func selectTool(_ t: Tool) {
        if t == .overlay, doc.state.overlay == nil, !loadOverlay() {
            toolControl.selectedSegment = Tool.allCases.firstIndex(of: canvas.tool) ?? 0
            return
        }
        if t == .overlay { widthSlider.doubleValue = Double((doc.state.overlay?.opacity ?? 0.5) * 30) }
        canvas.tool = t
        toolControl.selectedSegment = Tool.allCases.firstIndex(of: t) ?? 0
        refreshStyleMenu(for: t)
        window?.makeFirstResponder(canvas)
    }

    private func refreshStyleMenu(for t: Tool) {
        styleButton.removeAllItems()
        switch t {
        case .arrow:
            styleButton.addItems(withTitles: ["Classic arrow", "Open arrow", "Tapered arrow"].map { L($0) })
            styleButton.selectItem(at: canvas.arrowStyle)
            styleButton.isHidden = false
        case .blur:
            styleButton.addItems(withTitles: BlurMode.allCases.map(\.title))
            styleButton.selectItem(at: canvas.blurMode.rawValue)
            styleButton.isHidden = false
        case .rect, .oval:
            styleButton.addItems(withTitles: ["Outline", "Filled"].map { L($0) })
            styleButton.selectItem(at: canvas.filled ? 1 : 0)
            styleButton.isHidden = false
        case .text:
            styleButton.addItems(withTitles: ["Plain text", "Text with background"].map { L($0) })
            styleButton.selectItem(at: canvas.filled ? 1 : 0)
            styleButton.isHidden = false
        default:
            styleButton.isHidden = true
        }
    }

    @objc private func toolPicked(_ s: NSSegmentedControl) { selectTool(Tool.allCases[s.selectedSegment]); }

    @objc private func colorPicked(_ s: NSColorWell) { canvas.color = s.color }

    @objc private func widthPicked(_ s: NSSlider) {
        if canvas.tool == .overlay { // the slider doubles as overlay opacity
            doc.state.overlay?.opacity = CGFloat(s.doubleValue / 30)
            canvas.needsDisplay = true
            return
        }
        canvas.lineWidth = CGFloat(s.doubleValue)
        canvas.fontSize = max(12, CGFloat(s.doubleValue) * 6 + 8)
    }

    @objc private func stylePicked(_ s: NSPopUpButton) {
        let i = s.indexOfSelectedItem
        switch canvas.tool {
        case .arrow: canvas.arrowStyle = i
        case .blur: canvas.blurMode = BlurMode(rawValue: i) ?? .pixelate
        case .rect, .oval, .text: canvas.filled = i == 1
        default: break
        }
        window?.makeFirstResponder(canvas)
    }

    // MARK: Backdrop

    private func toggleBackdrop() {
        doc.checkpoint()
        doc.state.backdrop.enabled.toggle()
        doc.state.backdrop.save()
        doc.onChange?()
        backdropModel?.cfg = doc.state.backdrop
    }

    @objc private func showBackdrop(_ sender: NSButton) {
        if let p = backdropPopover, p.isShown { p.close(); return }
        doc.checkpoint()
        let model = BackdropModel(doc: doc) { [weak self] in self?.documentChanged() }
        backdropModel = model
        let pop = NSPopover()
        pop.behavior = .transient
        pop.contentViewController = NSHostingController(rootView: BackdropPanel(model: model))
        pop.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        backdropPopover = pop
    }

    // MARK: Actions

    private func flattened() -> CGImage? { Renderer.render(doc.state) }

    private func croppedFocus() -> CGImage? {
        let r = canvas.focusRect.integral
        return doc.state.image.cropping(to: r) ?? doc.state.image
    }

    @objc func undo(_ sender: Any?) { doc.undo() }
    @objc func redo(_ sender: Any?) { doc.redo() }

    @objc func copy(_ sender: Any?) {
        if let img = flattened() { Exporter.copy(img, scale: doc.scale) }
    }

    @objc func saveDocument(_ sender: Any?) {
        if let img = flattened() { Exporter.save(img, scale: doc.scale) }
    }

    @objc func saveDocumentAs(_ sender: Any?) {
        if let img = flattened() { Exporter.saveAs(img, scale: doc.scale, window: window) }
    }

    @objc func uploadImage(_ sender: Any?) {
        if let img = flattened() { Exporter.upload(img, scale: doc.scale) }
    }

    @objc private func pinImage(_ sender: Any?) {
        guard let img = flattened() else { return }
        PinController.pin(Shot(image: img, scale: doc.scale, screenRect: nil))
        Toast.show(L("Pinned"))
    }

    @objc private func runOCR(_ sender: Any?) {
        if let img = croppedFocus() { OCR.recognizeAndCopy(img) }
    }

    @objc func contrastAction(_ sender: Any?) {
        guard let img = croppedFocus(), let pair = ColorMath.dominantPair(in: img) else {
            Toast.show(L("Select an area with text and a background (crop tool or a shape)"), duration: 3)
            return
        }
        ColorTools.report(text: pair.text, background: pair.background)
    }

    @objc func cropAction(_ sender: Any?) { selectTool(.crop) }

    @objc func resizeImage(_ sender: Any?) {
        let w0 = doc.state.image.width, h0 = doc.state.image.height
        let wField = NSTextField(string: "\(w0)"), hField = NSTextField(string: "\(h0)")
        wField.frame = NSRect(x: 0, y: 0, width: 80, height: 24)
        hField.frame = NSRect(x: 100, y: 0, width: 80, height: 24)
        let x = NSTextField(labelWithString: "×")
        x.frame = NSRect(x: 84, y: 2, width: 14, height: 20)
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 184, height: 26))
        [wField, x, hField].forEach(box.addSubview)

        let alert = NSAlert()
        alert.messageText = L("Resize image")
        alert.informativeText = L("Width × height in pixels (aspect ratio is kept if you only change one value).")
        alert.accessoryView = box
        alert.addButton(withTitle: L("Resize"))
        alert.addButton(withTitle: L("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        var nw = Int(wField.stringValue) ?? w0, nh = Int(hField.stringValue) ?? h0
        if nw != w0 && nh == h0 { nh = Int((Double(h0) * Double(nw) / Double(w0)).rounded()) }
        else if nh != h0 && nw == w0 { nw = Int((Double(w0) * Double(nh) / Double(h0)).rounded()) }
        guard nw > 0, nh > 0, nw * nh <= 100_000_000, (nw, nh) != (w0, h0),
              let ctx = CGContext(data: nil, width: nw, height: nh, bitsPerComponent: 8, bytesPerRow: 0, space: Renderer.sRGB,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return }
        ctx.interpolationQuality = .high
        ctx.draw(doc.state.image, in: CGRect(x: 0, y: 0, width: nw, height: nh))
        guard let resized = ctx.makeImage() else { return }
        let sx = CGFloat(nw) / CGFloat(w0), sy = CGFloat(nh) / CGFloat(h0)
        doc.mutate { s in
            s.image = resized
            s.uncrop = nil
            if var o = s.overlay {
                o.origin = CGPoint(x: o.origin.x * sx, y: o.origin.y * sy)
                o.scale *= sx
                s.overlay = o
            }
            for i in s.annotations.indices {
                func f(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * sx, y: p.y * sy) }
                s.annotations[i].p1 = f(s.annotations[i].p1)
                s.annotations[i].p2 = f(s.annotations[i].p2)
                s.annotations[i].points = s.annotations[i].points.map(f)
            }
        }
        fitToWindow()
    }

    // MARK: Image menu

    @discardableResult
    private func loadOverlay() -> Bool {
        guard let img = NSImage(pasteboard: .general), let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            Toast.show(L("Copy an image first, then choose Image Overlay"), duration: 3)
            return false
        }
        let imgScale = img.size.width > 0 ? max(1, CGFloat(cg.width) / img.size.width) : 1
        let docScale = doc.scale
        doc.mutate { $0.overlay = OverlayImage(image: cg, origin: .zero, opacity: 0.5, scale: docScale / imgScale) }
        Toast.show(L("Drag to align · slider = opacity · Delete removes the overlay"), duration: 3.5)
        return true
    }

    @objc func overlayAction(_ sender: Any?) {
        guard loadOverlay() else { return }
        selectTool(.overlay)
    }

    @objc func uncropAction(_ sender: Any?) { canvas.uncrop() }

    /// Bakes annotations (and overlay) into the pixels so they can no longer be moved.
    @objc func rasterizeAction(_ sender: Any?) {
        var s = doc.state
        s.backdrop.enabled = false
        guard let img = Renderer.render(s) else { return }
        doc.mutate { $0.image = img; $0.annotations = []; $0.overlay = nil; $0.uncrop = nil }
        Toast.show(L("Annotations merged into the image"))
    }

    @objc func printDocument(_ sender: Any?) {
        guard let img = flattened(), let w = window else { return }
        let size = NSSize(width: CGFloat(img.width) / doc.scale, height: CGFloat(img.height) / doc.scale)
        let view = NSImageView(frame: NSRect(origin: .zero, size: size))
        view.image = NSImage(cgImage: img, size: size)
        view.imageScaling = .scaleProportionallyUpOrDown
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.isHorizontallyCentered = true
        info.isVerticallyCentered = true
        info.horizontalPagination = .fit
        info.verticalPagination = .fit
        NSPrintOperation(view: view, printInfo: info).runModal(for: w, delegate: nil, didRun: nil, contextInfo: nil)
    }

    // MARK: Closing

    private func finishWithEscape() {
        if Pref.bool("escCopy") || Pref.bool("escSave"), let img = flattened() {
            if Pref.bool("escCopy") { Exporter.copy(img, scale: doc.scale) }
            if Pref.bool("escSave") { Exporter.save(img, scale: doc.scale, quiet: Pref.bool("escCopy")) }
        }
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        canvas.commitText()
        EditorWindowController.open.removeAll { $0 === self }
        if EditorWindowController.open.isEmpty { NSApp.setActivationPolicy(.accessory) }
    }
}
