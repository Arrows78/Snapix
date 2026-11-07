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
private final class ImageDragButton: IconButton, NSDraggingSource {
    var imageProvider: (() -> (image: CGImage, scale: CGFloat)?)?
    private var started = false

    override func mouseDown(with event: NSEvent) { started = false }

    override func mouseDragged(with event: NSEvent) {
        guard !started, let (img, scale) = imageProvider?() else { return }
        started = ImageDrag.begin(from: self, source: self, event: event, image: img, scale: scale)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
}

@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate {
    private static var open: [EditorWindowController] = []
    static var hasOpenEditors: Bool { !open.isEmpty }

    private let doc: Document
    private let canvas: CanvasView
    private let scroll = ZoomScrollView()
    private var toolButtons: [Tool: IconButton] = [:]
    private var backdropButton: IconButton?
    private let options = OptionsPanel()
    private let colorChip = Chip(), sizeChip = Chip(), zoomChip = Chip()
    private var lastCursorColor: NSColor?
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
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.appearance = NSAppearance(named: .darkAqua)
        w.backgroundColor = Theme.window
        w.minSize = NSSize(width: 980, height: 420)
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
        canvas.onCopyColor = { [weak self] in self?.copyCursorColor() }
        canvas.color = NSColor(hex: 0xFF3B30)
        buildUI(in: w, size: shot)
        selectTool(.arrow)
        refreshTitle()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func iconButton(_ symbol: String, _ tip: String, _ action: Selector) -> IconButton {
        IconButton(symbol: symbol, tip: L(tip), target: self, action: action)
    }

    private func dragButton() -> IconButton {
        let b = ImageDragButton(symbol: "hand.draw", tip: L("Drag the edited image into another app"), target: nil, action: nil)
        b.imageProvider = { [weak self] in
            guard let self, let img = self.flattened() else { return nil }
            return (img, self.doc.scale)
        }
        return b
    }

    private func buildUI(in w: NSWindow, size shot: Shot) {
        let content = NSView()
        content.wantsLayer = true
        content.layer?.backgroundColor = Theme.window.cgColor
        w.contentView = content

        let wordmark = NSTextField(labelWithString: "snapix")
        var wordFont = NSFont.systemFont(ofSize: 19, weight: .semibold)
        if let d = wordFont.fontDescriptor.withDesign(.rounded), let f = NSFont(descriptor: d, size: 19) { wordFont = f }
        wordmark.font = wordFont
        wordmark.textColor = NSColor(hex: 0xA78BFA)

        // Every tool on one row, in one rounded group; the active tool is lit in the accent colour.
        let toolSize = NSSize(width: 25, height: 26)
        let toolStack = NSStackView()
        toolStack.spacing = 2
        toolStack.edgeInsets = NSEdgeInsets(top: 3, left: 3, bottom: 3, right: 3)
        toolStack.wantsLayer = true
        toolStack.layer?.backgroundColor = Theme.pill.cgColor
        toolStack.layer?.cornerRadius = 8
        for t in Tool.allCases {
            let b = IconButton(symbol: t.symbol, tip: "\(t.title) (\(t.key.uppercased()))", target: self, action: #selector(toolPicked(_:)),
                               size: toolSize, pointSize: 13)
            b.tag = Tool.allCases.firstIndex(of: t) ?? 0
            toolButtons[t] = b
            toolStack.addArrangedSubview(b)
        }
        let backdrop = IconButton(symbol: "rectangle.dashed.badge.record", tip: L("Backdrop (K)"), target: self, action: #selector(showBackdrop(_:)),
                                  size: toolSize, pointSize: 13)
        backdropButton = backdrop
        toolStack.addArrangedSubview(backdrop)
        toolStack.addArrangedSubview(IconButton(symbol: "ellipsis", tip: L("More tools and actions"), target: self, action: #selector(showMore(_:)),
                                                size: toolSize, pointSize: 13))

        options.setColor(canvas.color)
        options.onColor = { [weak self] c in self?.canvas.color = c }
        options.onSlider = { [weak self] v in self?.sliderChanged(v) }
        options.onOption = { [weak self] i in self?.optionPicked(i) }

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let bar = NSStackView(views: [
            wordmark,
            iconButton("doc.on.doc", "Copy (⌘C)", #selector(copy(_:))),
            iconButton("square.and.arrow.down", "Save (⌘S)", #selector(saveDocument(_:))),
            iconButton("pin", "Pin to screen", #selector(pinImage(_:))),
            dragButton(),
            verticalSeparator(), toolStack, spacer,
            colorChip, sizeChip, zoomChip,
        ])
        bar.orientation = .horizontal
        bar.alignment = .centerY
        bar.spacing = 8
        bar.setCustomSpacing(16, after: wordmark)
        bar.setCustomSpacing(16, after: colorChip)
        bar.setCustomSpacing(16, after: sizeChip)
        bar.edgeInsets = NSEdgeInsets(top: 0, left: 84, bottom: 0, right: 16)

        let topBar = NSView()
        topBar.wantsLayer = true
        topBar.layer?.backgroundColor = Theme.bar.cgColor
        let topLine = NSView()
        topLine.wantsLayer = true
        topLine.layer?.backgroundColor = Theme.line.cgColor

        // The checkerboard fills the whole workspace; the (transparent) scroll view floats above it.
        let checker = CheckerView()
        let clip = CenteringClipView()
        clip.drawsBackground = false
        scroll.contentView = clip
        scroll.documentView = canvas
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.autohidesScrollers = true
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.02
        scroll.maxMagnification = 32
        scroll.drawsBackground = false
        NotificationCenter.default.addObserver(self, selector: #selector(zoomChanged), name: NSScrollView.didEndLiveMagnifyNotification, object: scroll)

        for v in [topBar, bar, topLine, checker, scroll, options] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false }
        for v in [checker, scroll, topBar, topLine, bar, options] as [NSView] { content.addSubview(v) } // options above the canvas
        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: content.topAnchor),
            topBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            topBar.heightAnchor.constraint(equalToConstant: 46),
            bar.topAnchor.constraint(equalTo: topBar.topAnchor),
            bar.bottomAnchor.constraint(equalTo: topBar.bottomAnchor),
            bar.leadingAnchor.constraint(equalTo: topBar.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: topBar.trailingAnchor),
            topLine.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            topLine.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            topLine.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            topLine.heightAnchor.constraint(equalToConstant: 1),
            scroll.topAnchor.constraint(equalTo: topLine.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            checker.topAnchor.constraint(equalTo: topLine.bottomAnchor),
            checker.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            checker.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            checker.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            options.topAnchor.constraint(equalTo: topLine.bottomAnchor, constant: 10),
            options.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
        ])

        let screen = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1400, height: 900)
        let natural = Renderer.canvasSize(doc.state)
        let k = 1 / doc.scale
        let grow: CGFloat = Pref.bool("largerWindow") ? 1.3 : 1
        w.setContentSize(NSSize(width: min(max(natural.width * k * grow, 1040), screen.width * 0.92),
                                height: min(max((natural.height * k + 47) * grow, 460), screen.height * 0.9)))
        w.center()
        if Pref.bool("editorOnTop") { w.level = .floating }
        colorChip.set("—", caption: L("Tab to copy"))
    }

    // MARK: "More" menu

    @objc private func showMore(_ sender: NSButton) {
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector, symbol: String) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            menu.addItem(item)
        }
        add(L("Recognize text / QR code"), #selector(runOCR(_:)), symbol: "text.viewfinder")
        add(L("Check Contrast of Selection"), #selector(contrastAction(_:)), symbol: "circle.lefthalf.filled")
        add(L("Resize Image…"), #selector(resizeImage(_:)), symbol: "arrow.up.left.and.arrow.down.right")
        add(L("Uncrop"), #selector(uncropAction(_:)), symbol: "arrow.uturn.left")
        add(L("Merge Annotations Into Image"), #selector(rasterizeAction(_:)), symbol: "square.stack.3d.down.right")
        add(L("Erase Text in Selection"), #selector(eraseTextAction(_:)), symbol: "text.badge.minus")
        menu.addItem(.separator())
        add(L("Zoom to Selection"), #selector(zoomSelectionAction(_:)), symbol: "plus.magnifyingglass")
        add(L("Annotation Shadows"), #selector(toggleShadows(_:)), symbol: "shadow")
        menu.items.last?.state = doc.state.shadows ? .on : .off
        add(L("Copy as File"), #selector(copyAsFile(_:)), symbol: "doc.badge.arrow.up")
        menu.addItem(.separator())
        add(L("Upload"), #selector(uploadImage(_:)), symbol: "icloud.and.arrow.up")
        add(L("Print…"), #selector(printDocument(_:)), symbol: "printer")
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
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
        lastCursorColor = c
        if let c {
            colorChip.set(ColorFormat.hex.string(for: c), caption: L("Tab to copy"), swatch: c)
        } else {
            colorChip.set("—", caption: L("Tab to copy"))
        }
    }

    private func copyCursorColor() {
        guard let c = lastCursorColor else { return }
        let text = ColorFormat.current.string(for: c)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        Toast.show(LF("Copied %@", text))
    }

    private func updateStatus() {
        let pct = Int((scroll.magnification * (window?.backingScaleFactor ?? 2) * 100).rounded())
        sizeChip.set("\(doc.state.image.width)×\(doc.state.image.height)px", caption: L("Image size"))
        zoomChip.set("\(pct)%", caption: L("Zoom"))
        backdropButton?.isOn = doc.state.backdrop.enabled
    }

    private func selectionChanged(_ a: Annotation?) {
        guard let a else { refreshOptions(for: canvas.tool); return }
        refreshOptions(for: a.tool, from: a)
        options.setColor(a.color)
        options.setSlider(Double(a.width))
    }

    // MARK: Tool / option controls

    private func selectTool(_ t: Tool) {
        if t == .overlay, doc.state.overlay == nil, !loadOverlay() {
            highlightTool(canvas.tool)
            return
        }
        canvas.tool = t
        highlightTool(t)
        refreshOptions(for: t)
        if t == .overlay { options.setSlider(Double((doc.state.overlay?.opacity ?? 0.5) * 30)) }
        window?.makeFirstResponder(canvas)
    }

    /// Fills the floating options card with what the tool (or the selected shape) can change.
    private func refreshOptions(for t: Tool, from a: Annotation? = nil) {
        let showColor = ![.select, .crop, .blur, .spotlight, .overlay].contains(t)
        let showSlider = ![.select, .crop, .spotlight].contains(t)
        func symbol(_ name: String) -> NSImage { NSImage(systemSymbolName: name, accessibilityDescription: nil) ?? NSImage() }
        var opts: [OptionsPanel.Option] = []
        var selected = 0
        switch t {
        case .arrow:
            opts = ["Classic arrow", "Open arrow", "Tapered arrow"].enumerated().map {
                OptionsPanel.Option(image: ArrowGlyph.image(style: $0.offset), tip: L($0.element))
            }
            selected = a?.style ?? canvas.arrowStyle
        case .blur:
            let icons = ["square.grid.3x3.fill", "drop.fill", "eraser.fill"]
            opts = BlurMode.allCases.map { OptionsPanel.Option(image: symbol(icons[$0.rawValue]), tip: $0.title) }
            selected = (a?.blur ?? canvas.blurMode).rawValue
        case .rect, .oval:
            opts = [OptionsPanel.Option(image: symbol("square"), tip: L("Outline")), OptionsPanel.Option(image: symbol("square.fill"), tip: L("Filled"))]
            selected = (a?.filled ?? canvas.filled) ? 1 : 0
        case .text:
            opts = [OptionsPanel.Option(image: symbol("textformat"), tip: L("Plain text")),
                    OptionsPanel.Option(image: symbol("t.square.fill"), tip: L("Text with background"))]
            selected = (a?.filled ?? canvas.filled) ? 1 : 0
        default: break
        }
        options.configure(showColor: showColor, showSlider: showSlider, options: opts, selected: selected)
    }

    @objc private func toolPicked(_ s: NSButton) { selectTool(Tool.allCases[s.tag]) }

    private func highlightTool(_ t: Tool) {
        for (tool, b) in toolButtons { b.isOn = tool == t }
    }

    private func sliderChanged(_ v: Double) {
        if canvas.tool == .overlay { // the slider doubles as overlay opacity
            doc.state.overlay?.opacity = CGFloat(v / 30)
            canvas.needsDisplay = true
            return
        }
        canvas.lineWidth = CGFloat(v)
        canvas.fontSize = max(12, CGFloat(v) * 6 + 8)
    }

    private func optionPicked(_ i: Int) {
        switch canvas.selectedAnnotation?.tool ?? canvas.tool {
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
                s.annotations[i].ctrl = s.annotations[i].ctrl.map(f)
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

    // MARK: More actions

    /// Finds the text lines in the selection (or the whole image) and covers each with an "erase" patch.
    @objc func eraseTextAction(_ sender: Any?) {
        Toast.show(L("Recognizing…"), duration: 1)
        OCR.textBoxes(in: doc.state.image, region: canvas.focusRect) { [weak self] boxes in
            guard let self else { return }
            guard !boxes.isEmpty else { Toast.show(L("No text or QR code found")); return }
            let color = self.canvas.color
            self.doc.mutate { s in
                for b in boxes.map({ $0.insetBy(dx: -3, dy: -2) }) {
                    var a = Annotation(tool: .blur, p1: CGPoint(x: b.minX, y: b.minY), p2: CGPoint(x: b.maxX, y: b.maxY), color: color, width: 6)
                    a.blur = .erase
                    s.annotations.append(a)
                }
            }
            Toast.show(LF("%d text regions erased", boxes.count))
        }
    }

    @objc func zoomSelectionAction(_ sender: Any?) {
        let o = Renderer.origin(doc.state)
        let r = canvas.focusRect.offsetBy(dx: o.x, dy: o.y).insetBy(dx: -12, dy: -12)
        scroll.magnify(toFit: r)
        updateStatus()
    }

    @objc func toggleShadows(_ sender: Any?) {
        doc.mutate { $0.shadows.toggle() }
    }

    /// Puts the edited image on the pasteboard as a file, so it pastes into Finder, Mail, chat apps as an attachment.
    @objc func copyAsFile(_ sender: Any?) {
        guard let img = flattened() else { return }
        let prepared = Exporter.prepared(img, scale: doc.scale)
        guard let (data, ext) = Exporter.encode(prepared.image, forceLossless: Exporter.hasTransparency(prepared.image)) else { return }
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("SnapixCopy", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(Exporter.filename(ext: ext))
        guard (try? data.write(to: url)) != nil else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([url as NSURL])
        Toast.show(L("Copied as file"))
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
        if EditorWindowController.open.isEmpty { NSApp.setActivationPolicy(AppDelegate.restingPolicy) }
    }
}
