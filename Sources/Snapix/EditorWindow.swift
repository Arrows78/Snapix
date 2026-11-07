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
    /// True when the image changed since it was last copied, saved, pinned or uploaded.
    private var dirty = false
    private var backdropPopover: NSPopover?
    private var backdropModel: BackdropModel?
    private let sidebarModel = SidebarModel()
    private var sidebarView: NSView?
    private var scrollLeading: NSLayoutConstraint!
    private var sidebarOpen = false

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
            Toast.show(L("No image in the clipboard"), symbol: "exclamationmark.triangle.fill")
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

        if let preset = BackdropPreset.defaultPreset { doc.state.backdrop = preset.config; doc.state.backdrop.enabled = true }
        wireSidebar()
        doc.onChange = { [weak self] in self?.documentChanged() }
        canvas.onCursorMove = { [weak self] p, c in self?.updateCursor(p, c) }
        canvas.onEscape = { [weak self] in self?.finishWithEscape() }
        canvas.onToolShortcut = { [weak self] t in self?.selectTool(t) }
        canvas.onToggleBackdrop = { [weak self] in self?.toggleBackdrop() }
        canvas.onSelectionChanged = { [weak self] a in self?.selectionChanged(a) }
        canvas.onCopyColor = { [weak self] in self?.copyCursorColor() }
        canvas.onHighlightFinished = { [weak self] a in self?.snapHighlight(a) }
        canvas.color = NSColor(hex: 0xFF3B30)
        buildUI(in: w, size: shot)
        selectTool(Pref.bool("rememberTool") ? Tool(rawValue: Pref.string("lastTool")) ?? .arrow : Tool(rawValue: Pref.string("defaultTool")) ?? .arrow)
        refreshTitle()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func iconButton(_ symbol: String, _ tip: String, _ action: Selector) -> IconButton {
        let b = IconButton(symbol: symbol, tip: L(tip), target: self, action: action)
        if let g = ToolGlyph.action(symbol) { b.image = g }
        return b
    }

    private func dragButton() -> IconButton {
        let b = ImageDragButton(symbol: "hand.draw", tip: L("Drag the edited image into another app"), target: nil, action: nil)
        if let g = ToolGlyph.action("hand.draw") { b.image = g }
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
            b.image = ToolGlyph.image(for: t)
            b.tag = Tool.allCases.firstIndex(of: t) ?? 0
            toolButtons[t] = b
            toolStack.addArrangedSubview(b)
        }
        let backdrop = IconButton(symbol: "rectangle.dashed.badge.record", tip: L("Backdrop (K)"), target: self, action: #selector(showBackdrop(_:)),
                                  size: toolSize, pointSize: 13)
        backdrop.image = ToolGlyph.backdrop
        backdropButton = backdrop
        toolStack.addArrangedSubview(backdrop)
        let moreButton = IconButton(symbol: "ellipsis", tip: L("More tools and actions"), target: self, action: #selector(showMore(_:)),
                                    size: toolSize, pointSize: 13)
        moreButton.image = ToolGlyph.more
        toolStack.addArrangedSubview(moreButton)

        options.setColor(canvas.color)
        options.onColor = { [weak self] c in self?.canvas.color = c; self?.rememberStyle() }
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
        scrollLeading = scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor)
        let side = SidebarHost.makeView(model: sidebarModel)
        side.translatesAutoresizingMaskIntoConstraints = false
        side.isHidden = true
        content.addSubview(side)
        sidebarView = side
        NSLayoutConstraint.activate([
            side.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            side.topAnchor.constraint(equalTo: topLine.bottomAnchor),
            side.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            side.widthAnchor.constraint(equalToConstant: 220),
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
            scrollLeading,
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
        let click = NSClickGestureRecognizer(target: self, action: #selector(toggleSizeUnit))
        sizeChip.addGestureRecognizer(click)
        sizeChip.toolTip = L("Switch between pixels and points")
    }

    @objc private func toggleSizeUnit() {
        UserDefaults.standard.set(!Pref.bool("sizeInPoints"), forKey: "sizeInPoints")
        updateStatus()
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
        add(L("Color Statistics of Selection"), #selector(colorStatsAction(_:)), symbol: "paintpalette")
        add(L("Resize Image…"), #selector(resizeImage(_:)), symbol: "arrow.up.left.and.arrow.down.right")
        add(L("Uncrop"), #selector(uncropAction(_:)), symbol: "arrow.uturn.left")
        add(L("Rotate Left"), #selector(rotateLeftAction(_:)), symbol: "rotate.left")
        add(L("Rotate Right"), #selector(rotateRightAction(_:)), symbol: "rotate.right")
        add(L("Flip Horizontally"), #selector(flipHorizontalAction(_:)), symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right")
        add(L("Flip Vertically"), #selector(flipVerticalAction(_:)), symbol: "arrow.up.and.down.righttriangle.up.righttriangle.down")
        add(L("Merge Annotations Into Image"), #selector(rasterizeAction(_:)), symbol: "square.stack.3d.down.right")
        add(L("Erase Text in Selection"), #selector(eraseTextAction(_:)), symbol: "text.badge.minus")
        add(L("Trim Borders"), #selector(trimAction(_:)), symbol: "crop")
        add(L("Add Empty Space…"), #selector(expandAction(_:)), symbol: "rectangle.expand.vertical")
        add(L("Hide Sensitive Data"), #selector(redactAction(_:)), symbol: "eye.slash")
        add(L("Remove Background"), #selector(cutoutAction(_:)), symbol: "person.crop.circle.badge.minus")
        let presets = NSMenuItem(title: L("Style Presets"), action: nil, keyEquivalent: "")
        presets.image = NSImage(systemSymbolName: "paintpalette", accessibilityDescription: nil)
        presets.submenu = presetsMenu()
        menu.addItem(presets)
        menu.addItem(.separator())
        add(L("Zoom to Selection"), #selector(zoomSelectionAction(_:)), symbol: "plus.magnifyingglass")
        add(L("Toggle Sidebar"), #selector(toggleSidebar(_:)), symbol: "sidebar.left")
        menu.items.last?.state = sidebarOpen ? .on : .off
        add(L("Keep Window on Top"), #selector(toggleOnTop(_:)), symbol: "pin.circle")
        menu.items.last?.state = window?.level == .floating ? .on : .off
        add(L("Annotation Shadows"), #selector(toggleShadows(_:)), symbol: "shadow")
        menu.items.last?.state = doc.state.shadows ? .on : .off
        add(L("Copy as File"), #selector(copyAsFile(_:)), symbol: "doc.badge.arrow.up")
        menu.addItem(.separator())
        add(L("Add Capture Below…"), #selector(addCaptureBelow(_:)), symbol: "rectangle.bottomhalf.inset.filled")
        add(L("Add Capture to the Right…"), #selector(addCaptureRight(_:)), symbol: "rectangle.righthalf.inset.filled")
        add(L("Open in Default App"), #selector(openInDefaultApp(_:)), symbol: "arrow.up.forward.app")
        add(L("Save Two-Frame GIF"), #selector(saveTwoFrameGIF(_:)), symbol: "photo.stack")
        add(L("Share…"), #selector(shareAction(_:)), symbol: "square.and.arrow.up")
        add(L("Upload"), #selector(uploadImage(_:)), symbol: "icloud.and.arrow.up")
        add(L("Print…"), #selector(printDocument(_:)), symbol: "printer")
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    // MARK: Style presets

    private func presetsMenu() -> NSMenu {
        let m = NSMenu()
        func item(_ p: StylePreset, builtIn: Bool) {
            let i = NSMenuItem(title: builtIn ? L(p.name) : p.name, action: #selector(applyPreset(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = p.name
            let dot = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { r in p.color.setFill(); NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1)).fill(); return true }
            i.image = dot
            m.addItem(i)
        }
        StylePreset.builtIn.forEach { item($0, builtIn: true) }
        let saved = StylePreset.saved()
        if !saved.isEmpty { m.addItem(.separator()); saved.forEach { item($0, builtIn: false) } }
        m.addItem(.separator())
        let save = NSMenuItem(title: L("Save Current Style…"), action: #selector(savePreset(_:)), keyEquivalent: "")
        save.target = self
        m.addItem(save)
        if !saved.isEmpty {
            let del = NSMenuItem(title: L("Delete Preset"), action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for p in saved {
                let d = NSMenuItem(title: p.name, action: #selector(deletePreset(_:)), keyEquivalent: "")
                d.target = self
                sub.addItem(d)
            }
            del.submenu = sub
            m.addItem(del)
        }
        return m
    }

    /// Makes the preset the current style; a selected shape follows because the canvas applies changes to it.
    @objc private func applyPreset(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String,
              let p = (StylePreset.builtIn + StylePreset.saved()).first(where: { $0.name == name }) else { return }
        canvas.arrowStyle = p.arrowStyle
        canvas.filled = p.filled
        canvas.blurMode = BlurMode(rawValue: p.blur) ?? .pixelate
        canvas.color = p.color
        canvas.lineWidth = p.width
        canvas.fontSize = max(12, p.width * 6 + 8)
        options.setColor(p.color)
        options.setSlider(Double(p.width))
        refreshOptions(for: canvas.selectedAnnotation?.tool ?? canvas.tool, from: canvas.selectedAnnotation)
        Toast.show(LF("Style “%@” applied", sender.title), symbol: "checkmark.circle.fill")
    }

    @objc private func savePreset(_ sender: Any?) {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.placeholderString = L("Preset name")
        let alert = NSAlert()
        alert.messageText = L("Save current style")
        alert.informativeText = L("Colour, stroke width and options of the current tool are stored as a preset.")
        alert.accessoryView = field
        alert.addButton(withTitle: L("Save"))
        alert.addButton(withTitle: L("Cancel"))
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        StylePreset.save(StylePreset(name: name, colorHex: canvas.color.hexValue, width: canvas.lineWidth, arrowStyle: canvas.arrowStyle,
                                     filled: canvas.filled, blur: canvas.blurMode.rawValue))
        Toast.show(LF("Style “%@” saved", name), symbol: "checkmark.circle.fill")
    }

    @objc private func deletePreset(_ sender: NSMenuItem) { StylePreset.delete(named: sender.title) }

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
        dirty = true
        refreshSidebar()
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
        Toast.show(LF("Copied %@", text), symbol: "checkmark.circle.fill")
    }

    private func updateStatus() {
        let pct = Int((scroll.magnification * (window?.backingScaleFactor ?? 2) * 100).rounded())
        if Pref.bool("sizeInPoints") {
            let k = max(1, doc.scale)
            sizeChip.set("\(Int((CGFloat(doc.state.image.width) / k).rounded()))×\(Int((CGFloat(doc.state.image.height) / k).rounded()))pt", caption: L("Size · click for px"))
        } else {
            sizeChip.set("\(doc.state.image.width)×\(doc.state.image.height)px", caption: L("Size · click for pt"))
        }
        zoomChip.set("\(pct)%", caption: L("Zoom"))
        backdropButton?.isOn = doc.state.backdrop.enabled
    }

    private func refreshSidebar() { sidebarModel.reload(from: doc.state.annotations, selected: canvas.selectedAnnotation?.id) }

    @objc func toggleSidebar(_ sender: Any?) {
        sidebarOpen.toggle()
        sidebarView?.isHidden = !sidebarOpen
        scrollLeading.constant = sidebarOpen ? 220 : 0
        refreshSidebar()
        fitToWindow()
    }

    private func wireSidebar() {
        sidebarModel.onSelect = { [weak self] id in
            guard let self else { return }
            self.selectTool(.select)
            self.canvas.select(id)
        }
        sidebarModel.onDelete = { [weak self] id in
            guard let self else { return }
            self.doc.mutate { $0.annotations.removeAll { $0.id == id } }
        }
        sidebarModel.onMove = { [weak self] id, dir in
            guard let self, let i = self.doc.state.annotations.firstIndex(where: { $0.id == id }) else { return }
            let j = i + dir
            guard self.doc.state.annotations.indices.contains(j) else { return }
            self.doc.mutate { $0.annotations.swapAt(i, j) }
        }
    }

    private func selectionChanged(_ a: Annotation?) {
        sidebarModel.selected = a?.id
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
        if t != .overlay { UserDefaults.standard.set(t.rawValue, forKey: "lastTool") }
        if t != .select { applyStoredStyle(for: t) }
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
            let icons = ["square.grid.3x3.fill", "drop.fill", "eraser.fill", "hexagon.fill"]
            opts = BlurMode.allCases.map { OptionsPanel.Option(image: symbol(icons[$0.rawValue]), tip: $0.title) }
            selected = (a?.blur ?? canvas.blurMode).rawValue
        case .rect, .oval:
            opts = [OptionsPanel.Option(image: symbol("square"), tip: L("Outline")), OptionsPanel.Option(image: symbol("square.fill"), tip: L("Filled")),
                    OptionsPanel.Option(image: symbol("square.dashed"), tip: L("Dashed")),
                    OptionsPanel.Option(image: symbol("circle.dotted"), tip: L("Dotted"))]
            selected = (a?.dotted ?? canvas.dotted) ? 3 : ((a?.dashed ?? canvas.dashed) ? 2 : ((a?.filled ?? canvas.filled) ? 1 : 0))
        case .line:
            opts = [OptionsPanel.Option(image: symbol("minus"), tip: L("Solid")), OptionsPanel.Option(image: symbol("minus.forwardslash.plus"), tip: L("Dashed")),
                    OptionsPanel.Option(image: symbol("ellipsis"), tip: L("Dotted"))]
            selected = (a?.dotted ?? canvas.dotted) ? 2 : ((a?.dashed ?? canvas.dashed) ? 1 : 0)
        case .crop:
            opts = CropGeometry.ratios.map { OptionsPanel.Option(image: CropGeometry.glyph(ratio: $0.value), tip: $0.label == "Free" ? L("Free") : $0.label) }
            selected = CropGeometry.ratios.firstIndex { $0.value == canvas.cropRatio } ?? 0
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

    /// Keeps the current look as the tool's own, so it comes back the next time the tool is picked.
    private func rememberStyle() {
        guard Pref.bool("toolStyleMemory") else { return }
        let tool = canvas.selectedAnnotation?.tool ?? canvas.tool
        guard ToolStyle.remembers(tool) else { return }
        ToolStyle.save(ToolStyle(hex: canvas.color.hexValue, width: canvas.lineWidth, arrowStyle: canvas.arrowStyle, filled: canvas.filled,
                                 dashed: canvas.dashed, dotted: canvas.dotted, blur: canvas.blurMode.rawValue), for: tool)
    }

    private func applyStoredStyle(for tool: Tool) {
        guard Pref.bool("toolStyleMemory"), ToolStyle.remembers(tool), let s = ToolStyle.load(tool) else { return }
        canvas.arrowStyle = s.arrowStyle
        canvas.filled = s.filled
        canvas.dashed = s.dashed
        canvas.dotted = s.dotted
        canvas.blurMode = BlurMode(rawValue: s.blur) ?? .pixelate
        canvas.color = NSColor(hex: s.hex)
        canvas.lineWidth = s.width
        canvas.fontSize = max(12, s.width * 6 + 8)
        options.setColor(canvas.color)
        options.setSlider(Double(s.width))
    }

    private func sliderChanged(_ v: Double) {
        if canvas.tool == .overlay { // the slider doubles as overlay opacity
            doc.state.overlay?.opacity = CGFloat(v / 30)
            canvas.needsDisplay = true
            return
        }
        canvas.lineWidth = CGFloat(v)
        canvas.fontSize = max(12, CGFloat(v) * 6 + 8)
        rememberStyle()
    }

    private func optionPicked(_ i: Int) {
        switch canvas.selectedAnnotation?.tool ?? canvas.tool {
        case .arrow: canvas.arrowStyle = i
        case .blur: canvas.blurMode = BlurMode(rawValue: i) ?? .pixelate
        case .rect, .oval: canvas.dashed = i == 2; canvas.dotted = i == 3; canvas.filled = i == 1
        case .line: canvas.dashed = i == 1; canvas.dotted = i == 2
        case .crop: canvas.cropRatio = CropGeometry.ratios[i].value
        case .text: canvas.filled = i == 1
        default: break
        }
        rememberStyle()
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
        if let img = flattened() { dirty = false; Exporter.copy(img, scale: doc.scale) }
    }

    @objc func saveDocument(_ sender: Any?) {
        if let img = flattened() { dirty = false; Exporter.save(img, scale: doc.scale) }
    }

    @objc func saveDocumentAs(_ sender: Any?) {
        if let img = flattened() { dirty = false; Exporter.saveAs(img, scale: doc.scale, window: window) }
    }

    @objc func uploadImage(_ sender: Any?) {
        if let img = flattened() { dirty = false; Exporter.upload(img, scale: doc.scale) }
    }

    @objc private func pinImage(_ sender: Any?) {
        guard let img = flattened() else { return }
        PinController.pin(Shot(image: img, scale: doc.scale, screenRect: nil))
        Toast.show(L("Pinned"), symbol: "checkmark.circle.fill")
    }

    @objc private func runOCR(_ sender: Any?) {
        if let img = croppedFocus() { OCR.recognizeAndCopy(img) }
    }

    @objc func contrastAction(_ sender: Any?) {
        guard let img = croppedFocus(), let pair = ColorMath.dominantPair(in: img) else {
            Toast.show(L("Select an area with text and a background (crop tool or a shape)"), duration: 3, symbol: "exclamationmark.triangle.fill")
            return
        }
        ColorTools.report(text: pair.text, background: pair.background)
    }

    @objc func colorStatsAction(_ sender: Any?) {
        if let img = croppedFocus() { ColorStatsPanel.show(for: img) }
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
            Toast.show(L("Copy an image first, then choose Image Overlay"), duration: 3, symbol: "exclamationmark.triangle.fill")
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

    // MARK: Rotate, flip, share

    /// Annotations cannot follow a turn, so they are merged into the pixels first.
    private func transform(_ change: (CGImage) -> CGImage?) {
        var s = doc.state
        s.backdrop.enabled = false
        guard let flat = Renderer.render(s), let out = change(flat) else { return }
        doc.mutate { $0.image = out; $0.annotations = []; $0.overlay = nil; $0.uncrop = nil }
        fitToWindow()
    }

    @objc func rotateLeftAction(_ sender: Any?) { transform { ImageTransform.rotated($0, clockwise: false) } }
    @objc func rotateRightAction(_ sender: Any?) { transform { ImageTransform.rotated($0, clockwise: true) } }
    @objc func flipHorizontalAction(_ sender: Any?) { transform { ImageTransform.flipped($0, horizontal: true) } }
    @objc func flipVerticalAction(_ sender: Any?) { transform { ImageTransform.flipped($0, horizontal: false) } }

    /// The system share sheet (Messages, Mail, AirDrop, Notes…).
    @objc func shareAction(_ sender: Any?) {
        guard let img = flattened(), let view = window?.contentView else { return }
        let size = NSSize(width: CGFloat(img.width) / doc.scale, height: CGFloat(img.height) / doc.scale)
        let picker = NSSharingServicePicker(items: [NSImage(cgImage: img, size: size)])
        picker.show(relativeTo: NSRect(x: view.bounds.maxX - 60, y: view.bounds.maxY - 46, width: 1, height: 1), of: view, preferredEdge: .minY)
    }

    /// Bakes annotations (and overlay) into the pixels so they can no longer be moved.
    @objc func rasterizeAction(_ sender: Any?) {
        var s = doc.state
        s.backdrop.enabled = false
        guard let img = Renderer.render(s) else { return }
        doc.mutate { $0.image = img; $0.annotations = []; $0.overlay = nil; $0.uncrop = nil }
        Toast.show(L("Annotations merged into the image"), symbol: "checkmark.circle.fill")
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
            guard !boxes.isEmpty else { Toast.show(L("No text or QR code found"), symbol: "exclamationmark.triangle.fill"); return }
            let color = self.canvas.color
            self.doc.mutate { s in
                for b in boxes.map({ $0.insetBy(dx: -3, dy: -2) }) {
                    var a = Annotation(tool: .blur, p1: CGPoint(x: b.minX, y: b.minY), p2: CGPoint(x: b.maxX, y: b.maxY), color: color, width: 6)
                    a.blur = .erase
                    s.annotations.append(a)
                }
            }
            Toast.show(LF("%d text regions erased", boxes.count), symbol: "checkmark.circle.fill")
        }
    }

    /// Pixelates every email, card or bank number, phone number, secret and IP address found in the image.
    @objc func redactAction(_ sender: Any?) {
        Toast.show(L("Recognizing…"), duration: 1)
        Redaction.findBoxes(in: doc.state.image) { [weak self] boxes in
            guard let self else { return }
            guard !boxes.isEmpty else { Toast.show(L("No sensitive data found"), symbol: "exclamationmark.triangle.fill"); return }
            self.doc.mutate { s in
                for b in boxes.map({ $0.insetBy(dx: -4, dy: -3) }) {
                    s.annotations.append(Annotation(tool: .blur, p1: CGPoint(x: b.minX, y: b.minY), p2: CGPoint(x: b.maxX, y: b.maxY), color: .black, width: 8))
                }
            }
            Toast.show(LF("%d sensitive regions hidden", boxes.count), symbol: "checkmark.circle.fill")
        }
    }

    /// Keeps only the main subject of the image; the backdrop then shows through the transparent area.
    @objc func cutoutAction(_ sender: Any?) {
        Toast.show(L("Removing background…"), duration: 1.5)
        Cutout.subject(of: doc.state.image) { [weak self] cut in
            guard let self else { return }
            guard let cut else { Toast.show(L("No subject found"), symbol: "exclamationmark.triangle.fill"); return }
            self.doc.mutate { $0.image = cut; $0.uncrop = nil }
            Toast.show(L("Background removed"), symbol: "checkmark.circle.fill")
        }
    }

    /// Asks for a margin per side and a fill, then grows the image; annotations keep their place on the content.
    @objc func expandAction(_ sender: Any?) {
        let fields = (0..<4).map { _ -> NSTextField in let f = NSTextField(string: "0"); f.frame.size = NSSize(width: 54, height: 22); return f }
        let names = [L("Top"), L("Right"), L("Bottom"), L("Left")]
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 56))
        for (i, f) in fields.enumerated() {
            let label = NSTextField(labelWithString: names[i])
            label.font = .systemFont(ofSize: 10); label.textColor = .secondaryLabelColor
            label.frame = NSRect(x: CGFloat(i) * 62, y: 38, width: 58, height: 14)
            f.frame.origin = NSPoint(x: CGFloat(i) * 62, y: 14)
            box.addSubview(label); box.addSubview(f)
        }
        let fill = NSPopUpButton(frame: NSRect(x: 0, y: -10, width: 200, height: 24), pullsDown: false)
        fill.addItems(withTitles: [L("Transparent"), L("White"), L("Black"), L("Current color")])
        box.addSubview(fill)
        let alert = NSAlert()
        alert.messageText = L("Add empty space")
        alert.informativeText = L("Margins in pixels around the image.")
        alert.accessoryView = box
        alert.addButton(withTitle: L("Add"))
        alert.addButton(withTitle: L("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let v = fields.map { max(0, Int($0.stringValue) ?? 0) }
        guard v.contains(where: { $0 > 0 }) else { return }
        let color: CGColor? = [nil, CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1), CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1), canvas.color.cgColor][fill.indexOfSelectedItem]
        guard let out = ImageTransform.expanded(doc.state.image, top: v[0], right: v[1], bottom: v[2], left: v[3], fill: color) else {
            Toast.show(L("The image would be too large"), symbol: "exclamationmark.triangle.fill"); return
        }
        doc.mutate { s in
            s.image = out
            s.uncrop = nil
            for i in s.annotations.indices { s.annotations[i].translate(by: CGSize(width: CGFloat(v[3]), height: CGFloat(v[0]))) }
            s.overlay?.origin.x += CGFloat(v[3])
            s.overlay?.origin.y += CGFloat(v[0])
        }
        fitToWindow()
    }

    /// Replaces a freehand highlight with a clean band over the text line it covers (undoable).
    private func snapHighlight(_ a: Annotation) {
        guard Pref.bool("snapHighlight"), a.points.count > 1 else { return }
        let xs = a.points.map(\.x), ys = a.points.map(\.y)
        let stroke = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        OCR.textBoxes(in: doc.state.image, region: stroke.insetBy(dx: -16, dy: -16)) { [weak self] boxes in
            guard let self, let snap = HighlightSnap.snapped(stroke: stroke, boxes: boxes),
                  let i = self.doc.state.annotations.firstIndex(where: { $0.id == a.id }) else { return }
            self.doc.mutate { s in
                s.annotations[i].points = snap.points
                s.annotations[i].p1 = snap.points[0]
                s.annotations[i].p2 = snap.points[1]
                s.annotations[i].width = snap.width
            }
        }
    }

    @objc func toggleOnTop(_ sender: Any?) {
        guard let w = window else { return }
        w.level = w.level == .floating ? .normal : .floating
    }

    // MARK: Add a capture, two-frame GIF

    @objc func addCaptureBelow(_ sender: Any?) { addCapture(horizontal: false) }
    @objc func addCaptureRight(_ sender: Any?) { addCapture(horizontal: true) }

    /// Takes another area capture and joins it to the current picture (annotations are merged first).
    private func addCapture(horizontal: Bool) {
        guard Capture.ensurePermission() else { Capture.showPermissionAlert(); return }
        var base = doc.state
        base.backdrop.enabled = false
        guard let current = Renderer.render(base), let w = window else { return }
        w.orderOut(nil)
        Task { @MainActor in
            defer { w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
            guard let shot = try? await Capture.area(remember: false) else { return }
            guard let joined = Combine.images([current, shot.image], horizontal: horizontal, spacing: Pref.integer("combineGap")) else {
                Toast.show(L("The image would be too large"), symbol: "exclamationmark.triangle.fill"); return
            }
            doc.mutate { $0.image = joined; $0.annotations = []; $0.overlay = nil; $0.uncrop = nil }
            fitToWindow()
            Toast.show(L("Capture added"), symbol: "checkmark.circle.fill")
        }
    }

    /// The screenshot, then the screenshot with the overlay image fully opaque: a quick before / after.
    @objc func saveTwoFrameGIF(_ sender: Any?) {
        guard var second = Optional(doc.state), second.overlay != nil else {
            Toast.show(L("Add an image overlay first (clipboard image), then save the GIF"), duration: 3.5, symbol: "exclamationmark.triangle.fill"); return
        }
        var first = second
        first.overlay = nil
        second.overlay?.opacity = 1
        guard let a = Renderer.render(first), let b = Renderer.render(second), let data = GIFMaker.data(frames: [a, b], delay: 1.2) else { return }
        let folder = URL(fileURLWithPath: Pref.string("saveFolder"), isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = Exporter.uniqueURL(in: folder, name: Exporter.filename(ext: "gif"))
        do {
            try data.write(to: url)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([url as NSURL])
            Toast.show(LF("Saved %@", url.lastPathComponent), symbol: "checkmark.circle.fill")
            RecordingLog.add(url)
        } catch { Toast.show(LF("Could not save: %@", error.localizedDescription), symbol: "exclamationmark.triangle.fill") }
    }

    /// Writes the picture to a temporary file and opens it with whatever app macOS associates with it (Preview, for instance).
    @objc func openInDefaultApp(_ sender: Any?) {
        guard let img = flattened() else { return }
        let prepared = Exporter.prepared(img, scale: doc.scale)
        guard let (data, ext) = Exporter.encode(prepared.image, forceLossless: Exporter.hasTransparency(prepared.image)) else { return }
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("SnapixOpen", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(Exporter.filename(ext: ext))
        guard (try? data.write(to: url)) != nil else { return }
        NSWorkspace.shared.open(url)
    }

    @objc func trimAction(_ sender: Any?) {
        if canvas.trimBorders() { fitToWindow(); Toast.show(L("Borders trimmed"), symbol: "checkmark.circle.fill") }
        else { Toast.show(L("Nothing to trim"), symbol: "exclamationmark.triangle.fill") }
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
        Toast.show(L("Copied as file"), symbol: "checkmark.circle.fill")
    }

    // MARK: Closing

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard dirty, Pref.bool("confirmClose"), doc.canUndo else { return true }
        let alert = NSAlert()
        alert.messageText = L("Save changes before closing?")
        alert.informativeText = L("Your edits will be lost if you don't save them.")
        alert.addButton(withTitle: L("Save"))
        alert.addButton(withTitle: L("Don't Save"))
        alert.addButton(withTitle: L("Cancel"))
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            if let img = flattened() { Exporter.save(img, scale: doc.scale) }
            return true
        case .alertSecondButtonReturn: return true
        default: return false
        }
    }

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
