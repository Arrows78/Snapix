import AppKit

/// The editing surface. Lives inside an NSScrollView (which provides zoom); coordinates are canvas units = image pixels.
final class CanvasView: NSView, NSTextFieldDelegate {
    let doc: Document

    var tool: Tool = .arrow { didSet { toolDidChange(oldValue) } }
    var color: NSColor = .systemRed { didSet { applyToSelection { $0.color = color } } }
    var lineWidth: CGFloat = 4 { didSet { applyToSelection { $0.width = lineWidth } } }
    var arrowStyle = 0 { didSet { applyToSelection { $0.style = arrowStyle } } }
    var blurMode: BlurMode = .pixelate { didSet { applyToSelection { $0.blur = blurMode } } }
    var filled = false { didSet { applyToSelection { $0.filled = filled } } }
    var fontSize: CGFloat = 28

    var onCursorMove: ((CGPoint?, NSColor?) -> Void)?
    var onEscape: (() -> Void)?
    var onToolShortcut: ((Tool) -> Void)?
    var onToggleBackdrop: (() -> Void)?
    var onSelectionChanged: ((Annotation?) -> Void)?

    private(set) var selectedID: UUID? { didSet { if oldValue != selectedID { onSelectionChanged?(selectedAnnotation) } } }
    private(set) var cropRect: CGRect?

    private enum Drag { case create(UUID), move(UUID, CGPoint), handle(UUID, Int), crop(CGPoint), overlay(CGPoint) }
    private var drag: Drag?
    private var didCheckpointForDrag = false
    private var textField: NSTextField?
    private var editingID: UUID?
    private var editingIsNew = false
    private var pixels: (owner: UnsafeMutableRawPointer, buffer: PixelBuffer)?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(doc: Document) {
        self.doc = doc
        super.init(frame: NSRect(origin: .zero, size: Renderer.canvasSize(doc.state)))
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Geometry

    private var magnification: CGFloat { max(0.05, enclosingScrollView?.magnification ?? 1) }
    private var imageOrigin: CGPoint { Renderer.origin(doc.state) }
    private var imageBounds: CGRect { CGRect(x: 0, y: 0, width: doc.state.image.width, height: doc.state.image.height) }

    private func imagePoint(_ e: NSEvent) -> CGPoint {
        let p = convert(e.locationInWindow, from: nil)
        return CGPoint(x: p.x - imageOrigin.x, y: p.y - imageOrigin.y)
    }

    func documentChanged() {
        setFrameSize(Renderer.canvasSize(doc.state))
        if let sel = selectedID, !doc.state.annotations.contains(where: { $0.id == sel }) { selectedID = nil }
        needsDisplay = true
    }

    private func index(of id: UUID) -> Int? { doc.state.annotations.firstIndex { $0.id == id } }
    var selectedAnnotation: Annotation? { selectedID.flatMap { id in doc.state.annotations.first { $0.id == id } } }

    private func applyToSelection(_ change: (inout Annotation) -> Void) {
        guard let id = selectedID, let i = index(of: id) else { return }
        doc.checkpoint()
        change(&doc.state.annotations[i])
        needsDisplay = true
    }

    private func toolDidChange(_ old: Tool) {
        commitText()
        if tool != .crop { cropRect = nil }
        if tool != .select { selectedID = nil }
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.interpolationQuality = magnification >= 2 ? .none : .high
        Renderer.draw(doc.state, in: ctx, skipID: editingID)

        ctx.translateBy(x: imageOrigin.x, y: imageOrigin.y)
        if let a = selectedAnnotation { drawSelection(a, in: ctx) }
        if let r = cropRect { drawCrop(r, in: ctx) }
        ctx.restoreGState()
    }

    private func handles(for a: Annotation) -> [CGPoint] { a.tool.isTwoPoint ? [a.p1, a.p2] : [] }

    private func drawSelection(_ a: Annotation, in ctx: CGContext) {
        let k = 1 / magnification
        ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
        ctx.setLineWidth(1.5 * k)
        ctx.setLineDash(phase: 0, lengths: [4 * k, 3 * k])
        let box: CGRect
        switch a.tool {
        case .text: box = a.textRect
        case .magnifier:
            let r = hypot(a.p2.x - a.p1.x, a.p2.y - a.p1.y)
            box = CGRect(x: a.p1.x - r, y: a.p1.y - r, width: r * 2, height: r * 2)
        case .counter: box = CGRect(x: a.p1.x - a.counterRadius, y: a.p1.y - a.counterRadius, width: a.counterRadius * 2, height: a.counterRadius * 2)
        case .pen, .highlighter:
            let xs = a.points.map(\.x), ys = a.points.map(\.y)
            box = CGRect(x: xs.min() ?? 0, y: ys.min() ?? 0, width: (xs.max() ?? 0) - (xs.min() ?? 0), height: (ys.max() ?? 0) - (ys.min() ?? 0))
        default: box = a.rect
        }
        ctx.stroke(box.insetBy(dx: -4 * k, dy: -4 * k))
        ctx.setLineDash(phase: 0, lengths: [])
        for h in handles(for: a) {
            let r = CGRect(x: h.x - 4 * k, y: h.y - 4 * k, width: 8 * k, height: 8 * k)
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fillEllipse(in: r)
            ctx.strokeEllipse(in: r)
        }
    }

    private func drawCrop(_ r: CGRect, in ctx: CGContext) {
        let k = 1 / magnification
        let path = CGMutablePath()
        path.addRect(imageBounds)
        path.addRect(r)
        ctx.addPath(path)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.55).cgColor)
        ctx.fillPath(using: .evenOdd)
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(1.5 * k)
        ctx.stroke(r)

        let label = NSAttributedString(string: "\(Int(r.width)) × \(Int(r.height))  ↩ to crop", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12 * k, weight: .medium), .foregroundColor: NSColor.white,
        ])
        let ls = label.size()
        let box = CGRect(x: r.minX, y: max(0, r.minY - ls.height - 8 * k), width: ls.width + 12 * k, height: ls.height + 4 * k)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.8).cgColor)
        ctx.fill(box)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        label.draw(at: CGPoint(x: box.minX + 6 * k, y: box.minY + 2 * k))
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: Mouse

    override func resetCursorRects() {
        addCursorRect(visibleRect, cursor: tool == .select ? .arrow : (tool == .text ? .iBeam : .crosshair))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) { reportCursor(imagePoint(event)) }
    override func mouseExited(with event: NSEvent) { onCursorMove?(nil, nil) }

    private func pixelBuffer() -> PixelBuffer? {
        let owner = Unmanaged.passUnretained(doc.state.image).toOpaque()
        if let p = pixels, p.owner == owner { return p.buffer }
        guard let b = PixelBuffer(doc.state.image) else { return nil }
        pixels = (owner, b)
        return b
    }

    private static let snapTools: Set<Tool> = [.rect, .oval, .blur, .spotlight, .ruler, .crop]

    /// Edge snapping for box-like tools; hold ⌥ to bypass.
    private func snapped(_ p: CGPoint, for t: Tool) -> CGPoint {
        guard Pref.bool("snapEdges"), Self.snapTools.contains(t), !NSEvent.modifierFlags.contains(.option),
              let buf = pixelBuffer() else { return p }
        return buf.snap(p, radius: max(2, min(10, Int(6 / magnification))))
    }

    func color(at p: CGPoint) -> NSColor? { pixelBuffer()?.color(x: Int(p.x), y: Int(p.y)) }

    private func reportCursor(_ p: CGPoint) {
        onCursorMove?(p, color(at: p))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        commitText()
        let p = imagePoint(event)
        didCheckpointForDrag = false

        switch tool {
        case .select: beginSelectDrag(at: p, event: event)
        case .crop: beginCrop(at: p)
        case .overlay: if doc.state.overlay != nil { drag = .overlay(p) }
        case .text: beginTextEdit(id: nil, at: p)
        case .counter:
            var a = newAnnotation(tool: .counter, at: p)
            a.number = doc.nextCounter
            doc.checkpoint()
            doc.state.annotations.append(a)
            needsDisplay = true
        default:
            let a = newAnnotation(tool: tool, at: snapped(p, for: tool))
            doc.checkpoint()
            doc.state.annotations.append(a)
            drag = .create(a.id)
            needsDisplay = true
        }
    }

    private func newAnnotation(tool: Tool, at p: CGPoint) -> Annotation {
        var a = Annotation(tool: tool, p1: p, p2: p, color: color, width: lineWidth)
        a.points = [p]
        a.filled = filled
        a.style = arrowStyle
        a.blur = blurMode
        a.fontSize = fontSize
        switch tool {
        case .highlighter:
            if color == .systemRed { a.color = NSColor(hex: 0xFFC200) }
            a.width = max(lineWidth * 4, 18)
        case .blur:
            a.width = max(6, lineWidth * 2.5)
        default: break
        }
        return a
    }

    override func mouseDragged(with event: NSEvent) {
        let raw = imagePoint(event)
        reportCursor(raw)
        guard let drag else { return }
        let shift = event.modifierFlags.contains(.shift)

        switch drag {
        case let .create(id):
            guard let i = index(of: id) else { return }
            var p = raw
            let a = doc.state.annotations[i]
            if shift {
                switch a.tool {
                case .arrow, .line, .ruler: p = Geometry.snapAngle(raw, around: a.p1)
                case .rect, .oval, .blur, .spotlight:
                    let side = max(abs(raw.x - a.p1.x), abs(raw.y - a.p1.y))
                    p = CGPoint(x: a.p1.x + (raw.x < a.p1.x ? -side : side), y: a.p1.y + (raw.y < a.p1.y ? -side : side))
                case .highlighter: p.y = a.p1.y
                default: break
                }
            } else {
                p = snapped(p, for: a.tool)
            }
            doc.state.annotations[i].p2 = p
            if a.tool == .pen || a.tool == .highlighter {
                if a.tool == .highlighter && shift { doc.state.annotations[i].points = [a.p1, p] }
                else { doc.state.annotations[i].points.append(p) }
            }

        case let .move(id, last):
            guard let i = index(of: id) else { return }
            if !didCheckpointForDrag { doc.checkpoint(); didCheckpointForDrag = true }
            doc.state.annotations[i].translate(by: CGSize(width: raw.x - last.x, height: raw.y - last.y))
            self.drag = .move(id, raw)

        case let .handle(id, which):
            guard let i = index(of: id) else { return }
            if !didCheckpointForDrag { doc.checkpoint(); didCheckpointForDrag = true }
            var p = raw
            let other = which == 1 ? doc.state.annotations[i].p2 : doc.state.annotations[i].p1
            if shift && [.arrow, .line, .ruler].contains(doc.state.annotations[i].tool) { p = Geometry.snapAngle(raw, around: other) }
            else if !shift { p = snapped(p, for: doc.state.annotations[i].tool) }
            if which == 1 { doc.state.annotations[i].p1 = p } else { doc.state.annotations[i].p2 = p }

        case let .overlay(last):
            if !didCheckpointForDrag { doc.checkpoint(); didCheckpointForDrag = true }
            doc.state.overlay?.origin.x += raw.x - last.x
            doc.state.overlay?.origin.y += raw.y - last.y
            self.drag = .overlay(raw)

        case let .crop(start):
            let end = snapped(raw, for: .crop)
            let r = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
            cropRect = r.intersection(imageBounds)
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { drag = nil; needsDisplay = true }
        guard case let .create(id)? = drag, let i = index(of: id) else { return }
        let a = doc.state.annotations[i]
        let degenerate: Bool
        switch a.tool {
        case .pen, .highlighter: degenerate = a.points.count < 2
        default: degenerate = hypot(a.p2.x - a.p1.x, a.p2.y - a.p1.y) < 3
        }
        if degenerate {
            doc.state.annotations.remove(at: i)
            doc.discardCheckpoint()
        }
    }

    // MARK: Select tool

    private func beginSelectDrag(at p: CGPoint, event: NSEvent) {
        let tol = 6 / magnification
        if let a = selectedAnnotation {
            for (n, h) in handles(for: a).enumerated() where hypot(h.x - p.x, h.y - p.y) <= tol * 1.6 {
                drag = .handle(a.id, n + 1)
                return
            }
        }
        if let hit = doc.state.annotations.last(where: { $0.hitTest(p, tolerance: tol) }) {
            selectedID = hit.id
            if hit.tool == .text && event.clickCount == 2 { beginTextEdit(id: hit.id, at: hit.p1); return }
            drag = .move(hit.id, p)
        } else {
            selectedID = nil
        }
        needsDisplay = true
    }

    // MARK: Crop

    private func beginCrop(at p: CGPoint) {
        cropRect = nil
        drag = .crop(snapped(p, for: .crop))
    }

    func applyCrop() {
        guard let r = cropRect?.integral.intersection(imageBounds), r.width >= 1, r.height >= 1,
              let cropped = doc.state.image.cropping(to: r) else { return }
        cropRect = nil
        doc.mutate { s in
            // Keep the very first image so the crop can be undone later ("Uncrop"), even across several crops.
            if let u = s.uncrop {
                s.uncrop = UncropInfo(image: u.image, rect: CGRect(x: u.rect.minX + r.minX, y: u.rect.minY + r.minY, width: r.width, height: r.height))
            } else {
                s.uncrop = UncropInfo(image: s.image, rect: r)
            }
            s.image = cropped
            for i in s.annotations.indices { s.annotations[i].translate(by: CGSize(width: -r.minX, height: -r.minY)) }
            s.overlay?.origin.x -= r.minX
            s.overlay?.origin.y -= r.minY
        }
    }

    func cancelCrop() { cropRect = nil; needsDisplay = true }

    /// Restores the image as it was before cropping; annotations keep their position relative to the content.
    func uncrop() {
        guard let u = doc.state.uncrop else { NSSound.beep(); return }
        doc.mutate { s in
            s.image = u.image
            for i in s.annotations.indices { s.annotations[i].translate(by: CGSize(width: u.rect.minX, height: u.rect.minY)) }
            s.overlay?.origin.x += u.rect.minX
            s.overlay?.origin.y += u.rect.minY
            s.uncrop = nil
        }
    }

    /// Region currently targeted by OCR/contrast: the crop box, the selected shape, or the whole image.
    var focusRect: CGRect {
        if let r = cropRect, r.width > 1 { return r }
        if let a = selectedAnnotation, a.tool.isTwoPoint { return a.rect.intersection(imageBounds) }
        return imageBounds
    }

    // MARK: Text editing

    private func beginTextEdit(id: UUID?, at p: CGPoint) {
        var a: Annotation
        if let id, let i = index(of: id) {
            a = doc.state.annotations[i]
            editingIsNew = false
        } else {
            a = newAnnotation(tool: .text, at: p)
            editingIsNew = true
        }
        editingID = a.id
        needsDisplay = true

        let tf = NSTextField(frame: .zero)
        tf.isBordered = false
        tf.drawsBackground = false
        tf.focusRingType = .none
        tf.font = .systemFont(ofSize: a.fontSize, weight: .semibold)
        tf.textColor = a.color
        tf.stringValue = a.text
        tf.delegate = self
        tf.usesSingleLineMode = false
        tf.maximumNumberOfLines = 0
        tf.lineBreakMode = .byClipping
        tf.cell?.isScrollable = false
        tf.cell?.wraps = false
        textField = tf
        pendingTextAnnotation = a
        layoutTextField()
        addSubview(tf)
        window?.makeFirstResponder(tf)
        tf.currentEditor()?.selectedRange = NSRange(location: tf.stringValue.count, length: 0)
    }

    private var pendingTextAnnotation: Annotation?

    private func layoutTextField() {
        guard let tf = textField, var a = pendingTextAnnotation else { return }
        a.text = tf.stringValue
        let size = a.textSize
        tf.frame = CGRect(x: imageOrigin.x + a.p1.x - 2, y: imageOrigin.y + a.p1.y, width: max(80, size.width + 16), height: max(size.height, a.fontSize * 1.25))
    }

    func controlTextDidChange(_ obj: Notification) { layoutTextField() }

    func controlTextDidEndEditing(_ obj: Notification) { commitText() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.insertNewline(_:)) { commitText(); return true }
        if sel == #selector(NSResponder.cancelOperation(_:)) { cancelText(); return true }
        return false
    }

    private func cancelText() {
        textField?.removeFromSuperview()
        textField = nil; editingID = nil; pendingTextAnnotation = nil
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    func commitText() {
        guard let tf = textField, var a = pendingTextAnnotation, let id = editingID else { return }
        let text = tf.stringValue
        textField = nil; editingID = nil; pendingTextAnnotation = nil
        tf.removeFromSuperview()
        window?.makeFirstResponder(self)

        a.text = text
        if editingIsNew {
            guard !text.isEmpty else { needsDisplay = true; return }
            doc.checkpoint()
            doc.state.annotations.append(a)
        } else if let i = index(of: id) {
            doc.checkpoint()
            if text.isEmpty { doc.state.annotations.remove(at: i) } else { doc.state.annotations[i].text = text }
        }
        needsDisplay = true
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .control, .option])
        let chars = event.charactersIgnoringModifiers ?? ""

        switch event.keyCode {
        case 53: // esc
            if cropRect != nil { cancelCrop() } else if selectedID != nil { selectedID = nil; needsDisplay = true } else { onEscape?() }
            return
        case 36, 76: // return
            if cropRect != nil { applyCrop() }
            return
        case 51, 117: // delete
            if tool == .overlay, doc.state.overlay != nil {
                doc.mutate { $0.overlay = nil }
                return
            }
            if let id = selectedID, let i = index(of: id) {
                doc.checkpoint()
                doc.state.annotations.remove(at: i)
                selectedID = nil
                needsDisplay = true
            }
            return
        case 123, 124, 125, 126:
            if nudge(keyCode: event.keyCode, big: event.modifierFlags.contains(.shift)) { return }
        default: break
        }

        if mods.isEmpty {
            if chars.lowercased() == "k" { onToggleBackdrop?(); return }
            if let t = Tool.allCases.first(where: { $0.key == chars.lowercased() }) { onToolShortcut?(t); return }
        }
        super.keyDown(with: event)
    }

    private func nudge(keyCode: UInt16, big: Bool) -> Bool {
        let d: CGFloat = big ? 10 : 1
        let delta: CGSize
        switch keyCode {
        case 123: delta = CGSize(width: -d, height: 0)
        case 124: delta = CGSize(width: d, height: 0)
        case 125: delta = CGSize(width: 0, height: d)
        default: delta = CGSize(width: 0, height: -d)
        }
        if tool == .overlay, doc.state.overlay != nil {
            doc.checkpoint()
            doc.state.overlay?.origin.x += delta.width
            doc.state.overlay?.origin.y += delta.height
            needsDisplay = true
            return true
        }
        guard let id = selectedID, let i = index(of: id) else { return false }
        doc.checkpoint()
        doc.state.annotations[i].translate(by: delta)
        needsDisplay = true
        return true
    }

    // MARK: Context menu

    private var contextPoint: CGPoint = .zero

    override func menu(for event: NSEvent) -> NSMenu? {
        contextPoint = imagePoint(event)
        let m = NSMenu()
        if let c = color(at: contextPoint) {
            let item = NSMenuItem(title: LF("Copy Color %@", ColorFormat.current.string(for: c)), action: #selector(copyColorUnderCursor), keyEquivalent: "")
            item.target = self
            m.addItem(item)
        }
        if let hit = doc.state.annotations.last(where: { $0.hitTest(contextPoint, tolerance: 6 / magnification) }) {
            let item = NSMenuItem(title: LF("Delete %@", hit.tool.title), action: #selector(deleteContextAnnotation(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = hit.id
            m.addItem(item)
            if [.rect, .oval, .blur, .spotlight].contains(hit.tool) {
                let snap = NSMenuItem(title: L("Snap to Similar Region"), action: #selector(snapToSimilar(_:)), keyEquivalent: "")
                snap.target = self
                snap.representedObject = hit.id
                m.addItem(snap)
            }
        }
        return m.items.isEmpty ? nil : m
    }

    /// Resizes the shape to the area of similar colour under the click (a button, a card, a text field...).
    @objc private func snapToSimilar(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID, let i = index(of: id), let buf = pixelBuffer(),
              let r = buf.similarRegion(from: Int(contextPoint.x), Int(contextPoint.y)) else { NSSound.beep(); return }
        doc.checkpoint()
        doc.state.annotations[i].p1 = CGPoint(x: r.minX, y: r.minY)
        doc.state.annotations[i].p2 = CGPoint(x: r.maxX, y: r.maxY)
        needsDisplay = true
    }

    @objc private func copyColorUnderCursor() {
        guard let c = color(at: contextPoint) else { return }
        let text = ColorFormat.current.string(for: c)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        Toast.show(LF("Copied %@", text))
    }

    @objc private func deleteContextAnnotation(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID, let i = index(of: id) else { return }
        doc.checkpoint()
        doc.state.annotations.remove(at: i)
        needsDisplay = true
    }
}
