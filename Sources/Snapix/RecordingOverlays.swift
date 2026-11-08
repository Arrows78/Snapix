import AppKit
import QuartzCore

/// How a key press is shown in the keystroke overlay.
enum KeystrokeFormat {
    private static let special: [UInt16: String] = [
        36: "⏎", 76: "⏎", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋", 117: "⌦", 123: "←", 124: "→", 125: "↓", 126: "↑",
    ]

    static func label(keyCode: UInt16, characters: String?, flags: NSEvent.ModifierFlags) -> String {
        var out = ""
        if flags.contains(.control) { out += "⌃" }
        if flags.contains(.option) { out += "⌥" }
        if flags.contains(.shift) { out += "⇧" }
        if flags.contains(.command) { out += "⌘" }
        let key = special[keyCode] ?? (characters ?? "")
        let isShortcut = !flags.intersection([.control, .option, .command]).isEmpty
        return out + (isShortcut ? key.uppercased() : key)
    }
}

/// Look of the keystroke pill: text size, where it sits in the recorded area and how long it stays.
struct KeyPillStyle: Equatable {
    var fontSize: CGFloat = 20
    var position = "bottom"
    var seconds: Double = 1.6

    static var current: KeyPillStyle {
        let d = UserDefaults.standard
        let size = d.object(forKey: "keyPillSize") as? Double ?? 20
        let secs = d.object(forKey: "keyPillSeconds") as? Double ?? 1.6
        let pos = d.string(forKey: "keyPillPosition") ?? "bottom"
        return KeyPillStyle(fontSize: CGFloat(max(12, min(40, size))), position: ["top", "center", "bottom"].contains(pos) ? pos : "bottom", seconds: max(0.5, min(5, secs)))
    }

    /// Frame for a pill of `size` inside `area` (global coordinates, y up), 24 points from the chosen edge.
    func frame(size: CGSize, in area: CGRect) -> CGRect {
        let y: CGFloat
        switch position {
        case "top": y = area.maxY - size.height - 24
        case "center": y = area.midY - size.height / 2
        default: y = area.minY + 24
        }
        return CGRect(x: area.midX - size.width / 2, y: y, width: size.width, height: size.height)
    }
}

/// Look of the click ring drawn during a recording.
struct ClickStyle: Equatable {
    var hex: UInt32 = 0x5B8CFF
    var size: CGFloat = 54
    var duration: CFTimeInterval = 0.55
    /// How many rings expand one after the other (1...4) and how visible they are (0.2...1).
    var rings = 1
    var opacity: CGFloat = 1

    /// Reads the preferences, keeping every value in a sensible range.
    static var current: ClickStyle {
        let d = UserDefaults.standard
        let hex = d.object(forKey: "clickColor") as? Int ?? 0x5B8CFF
        let size = d.object(forKey: "clickSize") as? Double ?? 54
        let dur = d.object(forKey: "clickDuration") as? Double ?? 0.55
        let rings = d.object(forKey: "clickRings") as? Int ?? 1
        let opacity = d.object(forKey: "clickOpacity") as? Double ?? 1
        return ClickStyle(hex: UInt32(truncatingIfNeeded: hex) & 0xFFFFFF, size: CGFloat(max(24, min(120, size))), duration: max(0.2, min(1.5, dur)),
                          rings: max(1, min(4, rings)), opacity: CGFloat(max(0.2, min(1, opacity))))
    }
}

/// Click ripples and a key-press pill drawn on screen so they end up in the recording.
@MainActor
final class RecordingOverlays {
    private var windows: [NSWindow] = []
    private var monitors: [Any] = []
    private let pill = NSTextField(labelWithString: "")
    private var pillWindow: NSWindow?
    private var typed = ""
    private var lastKey = Date.distantPast
    private var hideWork: DispatchWorkItem?

    private var camera: CameraBubble?

    var windowIDs: Set<CGWindowID> {
        var ids = Set(windows.map { CGWindowID($0.windowNumber) })
        if let camera { ids.insert(CGWindowID(camera.window.windowNumber)) }
        return ids
    }

    func attach(camera: CameraBubble) { self.camera = camera }

    init(rect: CGRect, screen: NSScreen, clicks: Bool, keys: Bool) {
        if clicks { addClickOverlay(screen: screen) }
        if keys { addKeyOverlay(rect: rect) }
    }

    private func makeWindow(_ frame: NSRect) -> NSWindow {
        let w = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.level = .statusBar
        w.isReleasedWhenClosed = false
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        windows.append(w)
        return w
    }

    // MARK: Clicks

    private func addClickOverlay(screen: NSScreen) {
        let w = makeWindow(screen.frame)
        let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        w.contentView = view
        w.orderFrontRegardless()
        let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak view] _ in
            let p = NSEvent.mouseLocation
            Task { @MainActor in
                guard let view, let layer = view.layer else { return }
                Self.ripple(at: CGPoint(x: p.x - screen.frame.minX, y: p.y - screen.frame.minY), on: layer, style: ClickStyle.current)
            }
        }
        if let m { monitors.append(m) }
    }

    private static func ripple(at p: CGPoint, on layer: CALayer, style: ClickStyle) {
        let d = style.size
        for n in 0..<style.rings {
            let ring = CAShapeLayer()
            ring.frame = CGRect(x: p.x - d / 2, y: p.y - d / 2, width: d, height: d)
            ring.path = CGPath(ellipseIn: ring.bounds.insetBy(dx: 3, dy: 3), transform: nil)
            ring.fillColor = NSColor(hex: style.hex, alpha: 0.22 * style.opacity).cgColor
            ring.strokeColor = NSColor(hex: style.hex, alpha: 0.9 * style.opacity).cgColor
            ring.lineWidth = 3
            ring.opacity = 0
            layer.addSublayer(ring)
            let scale = CABasicAnimation(keyPath: "transform.scale"); scale.fromValue = 0.45; scale.toValue = 1.25
            let fade = CABasicAnimation(keyPath: "opacity"); fade.fromValue = 1; fade.toValue = 0
            let group = CAAnimationGroup()
            group.animations = [scale, fade]
            group.duration = style.duration
            group.beginTime = CACurrentMediaTime() + Double(n) * style.duration * 0.28
            group.timingFunction = CAMediaTimingFunction(name: .easeOut)
            group.isRemovedOnCompletion = false
            group.fillMode = .both
            ring.add(group, forKey: "ripple")
            DispatchQueue.main.asyncAfter(deadline: .now() + style.duration * (1 + Double(n) * 0.28) + 0.1) { ring.removeFromSuperlayer() }
        }
    }

    // MARK: Keys

    private func addKeyOverlay(rect: CGRect) {
        if !ElementPicker.isTrusted { ElementPicker.requestAccess() }
        pill.font = .systemFont(ofSize: 20, weight: .semibold)
        pill.textColor = .white
        pill.alignment = .center
        let box = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 80, height: 40))
        box.material = .hudWindow
        box.blendingMode = .behindWindow
        box.state = .active
        box.wantsLayer = true
        box.layer?.cornerRadius = 12
        box.addSubview(pill)
        let w = makeWindow(box.frame)
        w.contentView = box
        w.alphaValue = 0
        w.orderFrontRegardless()
        pillWindow = w
        let m = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] e in
            let label = KeystrokeFormat.label(keyCode: e.keyCode, characters: e.charactersIgnoringModifiers ?? e.characters, flags: e.modifierFlags)
            let isShortcut = !e.modifierFlags.intersection([.control, .option, .command]).isEmpty || e.charactersIgnoringModifiers?.count != 1
            Task { @MainActor in self?.show(label, replacing: isShortcut, near: rect) }
        }
        if let m { monitors.append(m) }
    }

    private func show(_ label: String, replacing: Bool, near rect: CGRect) {
        let now = Date()
        if replacing || now.timeIntervalSince(lastKey) > max(1.5, KeyPillStyle.current.seconds) { typed = "" }
        typed = replacing ? label : String((typed + label).suffix(24))
        lastKey = now
        pill.stringValue = typed
        pill.sizeToFit()
        let style = KeyPillStyle.current
        pill.font = .systemFont(ofSize: style.fontSize, weight: .semibold)
        pill.sizeToFit()
        let size = NSSize(width: max(60, pill.frame.width + 32), height: style.fontSize * 2.2)
        guard let w = pillWindow else { return }
        pill.frame.origin = NSPoint(x: (size.width - pill.frame.width) / 2, y: (size.height - pill.frame.height) / 2)
        w.setFrame(style.frame(size: size, in: rect), display: true)
        w.contentView?.frame = NSRect(origin: .zero, size: size)
        w.alphaValue = 1
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak w] in NSAnimationContext.runAnimationGroup { $0.duration = 0.3; w?.animator().alphaValue = 0 } }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + style.seconds, execute: work)
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        camera?.stop(); camera = nil
        hideWork?.cancel()
        windows.forEach { $0.orderOut(nil) }
        windows = []
    }
}
