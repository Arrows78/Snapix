import AppKit

enum Tool: String, CaseIterable {
    case select, arrow, rect, oval, line, pen, pencil, text, highlighter, blur, spotlight, counter, ruler, magnifier, overlay, crop

    var title: String {
        switch self {
        case .select: return L("Select / Move")
        case .arrow: return L("Arrow")
        case .rect: return L("Rectangle")
        case .oval: return L("Oval")
        case .line: return L("Line")
        case .pen: return L("Freehand")
        case .pencil: return L("Pencil")
        case .text: return L("Text")
        case .highlighter: return L("Highlighter")
        case .blur: return L("Blur / Erase")
        case .spotlight: return L("Spotlight")
        case .counter: return L("Counter")
        case .ruler: return L("Ruler")
        case .magnifier: return L("Magnifier")
        case .overlay: return L("Image Overlay (from clipboard)")
        case .crop: return L("Crop")
        }
    }

    var symbol: String {
        switch self {
        case .select: return "cursorarrow"
        case .arrow: return "arrow.up.right"
        case .rect: return "rectangle"
        case .oval: return "circle"
        case .line: return "line.diagonal"
        case .pen: return "scribble"
        case .pencil: return "pencil"
        case .text: return "textformat"
        case .highlighter: return "highlighter"
        case .blur: return "square.dotted"
        case .spotlight: return "sun.max"
        case .counter: return "1.circle.fill"
        case .ruler: return "ruler"
        case .magnifier: return "plus.magnifyingglass"
        case .overlay: return "square.on.square"
        case .crop: return "crop"
        }
    }

    var key: String {
        switch self {
        case .select: return "v"
        case .arrow: return "a"
        case .rect: return "r"
        case .oval: return "o"
        case .line: return "l"
        case .pen: return "p"
        case .pencil: return "e"
        case .text: return "t"
        case .highlighter: return "h"
        case .blur: return "b"
        case .spotlight: return "s"
        case .counter: return "c"
        case .ruler: return "m"
        case .magnifier: return "g"
        case .overlay: return "i"
        case .crop: return "x"
        }
    }

    /// Tools whose geometry is fully described by two points.
    var isTwoPoint: Bool {
        switch self {
        case .arrow, .rect, .oval, .line, .blur, .spotlight, .ruler, .magnifier, .crop: return true
        default: return false
        }
    }
}

enum BlurMode: Int, CaseIterable {
    case pixelate, gaussian, erase, hexagonal
    var title: String { L(["Pixelate", "Gaussian blur", "Erase", "Hexagonal pixelation"][rawValue]) }
}

struct Annotation: Identifiable {
    var id = UUID()
    var tool: Tool
    var p1: CGPoint
    var p2: CGPoint
    var points: [CGPoint] = []
    var color: NSColor
    var width: CGFloat
    var text = ""
    var fontSize: CGFloat = 28
    var number = 1
    var filled = false
    var dashed = false
    var dotted = false
    var style = 0
    var blur: BlurMode = .pixelate
    /// Quadratic Bézier control point: bends arrows and lines (nil = straight).
    var ctrl: CGPoint?

    var rect: CGRect {
        CGRect(x: min(p1.x, p2.x), y: min(p1.y, p2.y), width: abs(p2.x - p1.x), height: abs(p2.y - p1.y))
    }

    var counterRadius: CGFloat { 10 + width * 1.5 }

    static func textAttributes(size: CGFloat, color: NSColor) -> [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: size, weight: .semibold), .foregroundColor: color]
    }

    var textSize: CGSize {
        let s = NSAttributedString(string: text.isEmpty ? " " : text, attributes: Annotation.textAttributes(size: fontSize, color: color))
        let r = s.boundingRect(with: CGSize(width: 10_000, height: 10_000), options: [.usesLineFragmentOrigin])
        return CGSize(width: ceil(r.width) + 1, height: ceil(r.height))
    }

    var textRect: CGRect { CGRect(origin: p1, size: textSize) }

    var isCurvable: Bool { tool == .line || (tool == .arrow && style != 2) }

    /// Point of the curve halfway along it, where the bend handle sits.
    var curveMid: CGPoint {
        guard let c = ctrl else { return CGPoint(x: (p1.x + p2.x) / 2, y: (p1.y + p2.y) / 2) }
        return CGPoint(x: (p1.x + 2 * c.x + p2.x) / 4, y: (p1.y + 2 * c.y + p2.y) / 4)
    }

    /// Bends the stroke so that it passes through `m` at its middle; close to the chord means straight again.
    mutating func bend(through m: CGPoint) {
        let mid = CGPoint(x: (p1.x + p2.x) / 2, y: (p1.y + p2.y) / 2)
        ctrl = hypot(m.x - mid.x, m.y - mid.y) < 3 ? nil : CGPoint(x: 2 * m.x - mid.x, y: 2 * m.y - mid.y)
    }

    func distanceToStroke(_ p: CGPoint) -> CGFloat {
        guard let c = ctrl, isCurvable else { return Geometry.distance(from: p, toSegment: p1, p2) }
        var best = CGFloat.greatestFiniteMagnitude
        var prev = p1
        for i in 1...16 {
            let t = CGFloat(i) / 16, u = 1 - t
            let q = CGPoint(x: u * u * p1.x + 2 * u * t * c.x + t * t * p2.x, y: u * u * p1.y + 2 * u * t * c.y + t * t * p2.y)
            best = min(best, Geometry.distance(from: p, toSegment: prev, q))
            prev = q
        }
        return best
    }

    mutating func translate(by d: CGSize) {
        p1.x += d.width; p1.y += d.height
        p2.x += d.width; p2.y += d.height
        if let c = ctrl { ctrl = CGPoint(x: c.x + d.width, y: c.y + d.height) }
        points = points.map { CGPoint(x: $0.x + d.width, y: $0.y + d.height) }
    }

    func hitTest(_ p: CGPoint, tolerance t: CGFloat) -> Bool {
        switch tool {
        case .rect, .oval, .blur, .spotlight, .crop:
            return rect.insetBy(dx: -t, dy: -t).contains(p)
        case .line, .arrow, .ruler:
            return distanceToStroke(p) <= max(t, width / 2 + t)
        case .pen, .pencil, .highlighter:
            guard points.count > 1 else { return false }
            for i in 1..<points.count where Geometry.distance(from: p, toSegment: points[i - 1], points[i]) <= max(t, width / 2 + t) {
                return true
            }
            return false
        case .text:
            return textRect.insetBy(dx: -t, dy: -t).contains(p)
        case .counter:
            return hypot(p.x - p1.x, p.y - p1.y) <= counterRadius + t
        case .magnifier:
            return hypot(p.x - p1.x, p.y - p1.y) <= hypot(p2.x - p1.x, p2.y - p1.y) + t
        case .select, .overlay:
            return false
        }
    }
}

enum Geometry {
    static func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        if len2 == 0 { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    /// Snaps `p` to the nearest 45° direction around `origin`.
    static func snapAngle(_ p: CGPoint, around origin: CGPoint) -> CGPoint {
        let dx = p.x - origin.x, dy = p.y - origin.y
        let len = hypot(dx, dy)
        let step = CGFloat.pi / 4
        let ang = (atan2(dy, dx) / step).rounded() * step
        return CGPoint(x: origin.x + cos(ang) * len, y: origin.y + sin(ang) * len)
    }
}

struct BackdropConfig: Codable, Equatable {
    var enabled = false
    var padding: CGFloat = 64
    var innerRadius: CGFloat = 12
    var outerRadius: CGFloat = 0
    var shadow = true
    var gradient = true
    var fromHex: UInt32 = 0x7F5AF0
    var toHex: UInt32 = 0x2CB1BC
    var angle: CGFloat = 45
    var radial = false
    /// Width / height of the final picture (nil = as big as the padding makes it); the screenshot stays centred.
    var ratio: CGFloat?
    /// Draws a window title bar (three dots) above the screenshot. Optional so settings saved by older versions still decode.
    var windowFrame: Bool?
    /// Texture over the background: 1 dots, 2 grid, 3 diagonal lines. Optional for the same reason as `windowFrame`.
    var pattern: Int?

    static let ratios: [(name: String, value: CGFloat?)] = [
        ("Auto", nil), ("1:1", 1), ("4:3", 4.0 / 3), ("3:2", 1.5), ("16:9", 16.0 / 9), ("2:1", 2), ("9:16", 9.0 / 16),
    ]

    var from: NSColor { NSColor(hex: fromHex) }
    var to: NSColor { NSColor(hex: toHex) }

    static let presets: [(UInt32, UInt32)] = [
        (0x7F5AF0, 0x2CB1BC), (0xFF8A00, 0xE52E71), (0x00C6FF, 0x0072FF),
        (0x11998E, 0x38EF7D), (0xF857A6, 0xFF5858), (0x232526, 0x414345),
        (0xFDC830, 0xF37335), (0x667EEA, 0x764BA2),
        (0x0F2027, 0x2C5364), (0xEE9CA7, 0xFFDDE1), (0x4568DC, 0xB06AB3), (0x1D976C, 0x93F9B9),
        (0xFC466B, 0x3F5EFB), (0xF7971E, 0xFFD200), (0xDA22FF, 0x9733EE), (0xE0EAFC, 0xCFDEF3),
    ]

    private static let key = "backdropConfig"

    static func load() -> BackdropConfig {
        guard let data = UserDefaults.standard.data(forKey: key),
              let cfg = try? JSONDecoder().decode(BackdropConfig.self, from: data) else { return BackdropConfig() }
        return cfg
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}

/// A second image (from the clipboard) laid over the screenshot at partial opacity, e.g. to compare a design with the real UI.
struct OverlayImage {
    var image: CGImage
    var origin: CGPoint
    var opacity: CGFloat
    /// Image pixels per overlay pixel, so a Retina clipboard image lines up with a Retina screenshot.
    var scale: CGFloat

    var size: CGSize { CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale) }
}

/// What a crop removed, so it can be undone later even after other edits.
struct UncropInfo {
    var image: CGImage
    /// Where the current image sits inside `image`.
    var rect: CGRect
}

struct DocState {
    var image: CGImage
    var annotations: [Annotation] = []
    var backdrop = BackdropConfig.load()
    var overlay: OverlayImage?
    var uncrop: UncropInfo?
    /// Soft drop shadow under every annotation.
    var shadows = false
    /// Picture used instead of the gradient behind the screenshot (session only).
    var backdropImage: CGImage?
}

final class Document {
    var state: DocState
    let scale: CGFloat
    private(set) var undoStack: [DocState] = []
    private(set) var redoStack: [DocState] = []
    var onChange: (() -> Void)?

    init(image: CGImage, scale: CGFloat) {
        state = DocState(image: image)
        self.scale = scale
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    var nextCounter: Int {
        (state.annotations.filter { $0.tool == .counter }.map(\.number).max() ?? 0) + 1
    }

    /// Records the current state so the next mutation can be undone.
    func checkpoint() {
        undoStack.append(state)
        redoStack.removeAll()
        if undoStack.count > 100 { undoStack.removeFirst() }
    }

    func discardCheckpoint() {
        _ = undoStack.popLast()
    }

    func mutate(_ change: (inout DocState) -> Void) {
        checkpoint()
        change(&state)
        onChange?()
    }

    func undo() {
        guard let prev = undoStack.popLast() else { return }
        redoStack.append(state)
        state = prev
        onChange?()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(state)
        state = next
        onChange?()
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    var hexValue: UInt32 {
        let c = usingColorSpace(.sRGB) ?? self
        let r = UInt32((c.redComponent * 255).rounded()), g = UInt32((c.greenComponent * 255).rounded()), b = UInt32((c.blueComponent * 255).rounded())
        return (r << 16) | (g << 8) | b
    }
}
