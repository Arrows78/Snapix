import AppKit

enum Tool: String, CaseIterable {
    case select, arrow, rect, oval, line, pen, text, highlighter, blur, spotlight, counter, ruler, magnifier, overlay, crop

    var title: String {
        switch self {
        case .select: return L("Select / Move")
        case .arrow: return L("Arrow")
        case .rect: return L("Rectangle")
        case .oval: return L("Oval")
        case .line: return L("Line")
        case .pen: return L("Freehand")
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
    case pixelate, gaussian, erase
    var title: String { L(["Pixelate", "Gaussian blur", "Erase"][rawValue]) }
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
    var style = 0
    var blur: BlurMode = .pixelate

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

    mutating func translate(by d: CGSize) {
        p1.x += d.width; p1.y += d.height
        p2.x += d.width; p2.y += d.height
        points = points.map { CGPoint(x: $0.x + d.width, y: $0.y + d.height) }
    }

    func hitTest(_ p: CGPoint, tolerance t: CGFloat) -> Bool {
        switch tool {
        case .rect, .oval, .blur, .spotlight, .crop:
            return rect.insetBy(dx: -t, dy: -t).contains(p)
        case .line, .arrow, .ruler:
            return Geometry.distance(from: p, toSegment: p1, p2) <= max(t, width / 2 + t)
        case .pen, .highlighter:
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

    var from: NSColor { NSColor(hex: fromHex) }
    var to: NSColor { NSColor(hex: toHex) }

    static let presets: [(UInt32, UInt32)] = [
        (0x7F5AF0, 0x2CB1BC), (0xFF8A00, 0xE52E71), (0x00C6FF, 0x0072FF),
        (0x11998E, 0x38EF7D), (0xF857A6, 0xFF5858), (0x232526, 0x414345),
        (0xFDC830, 0xF37335), (0x667EEA, 0x764BA2),
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
