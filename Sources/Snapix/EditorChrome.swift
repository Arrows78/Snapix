import AppKit

/// Colours shared by the editor chrome (always dark, like most image tools).
enum Theme {
    static let window = NSColor(hex: 0x1B1B1E)
    static let bar = NSColor(hex: 0x252528)
    static let canvas = NSColor(hex: 0x141416)
    static let pill = NSColor(hex: 0x323236)
    static let accent = NSColor(hex: 0x5B8CFF)
    static let hover = NSColor(white: 1, alpha: 0.09)
    static let text = NSColor(white: 1, alpha: 0.88)
    static let dim = NSColor(white: 1, alpha: 0.5)
    static let line = NSColor(white: 1, alpha: 0.10)
}

/// Borderless symbol button with hover feedback; `isOn` draws it as the selected tool.
class IconButton: NSButton {
    var isOn = false { didSet { refresh() } }
    private var hovering = false { didSet { refresh() } }

    init(symbol: String, tip: String, target: AnyObject?, action: Selector?, size: NSSize = NSSize(width: 28, height: 26), pointSize: CGFloat = 14) {
        super.init(frame: .zero)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular))
        imagePosition = .imageOnly
        imageScaling = .scaleNone
        isBordered = false
        setButtonType(.momentaryChange)
        self.target = target
        self.action = action
        toolTip = tip
        wantsLayer = true
        layer?.cornerRadius = 6
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: size.width).isActive = true
        heightAnchor.constraint(equalToConstant: size.height).isActive = true
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
        refresh()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    private func refresh() {
        layer?.backgroundColor = (isOn ? Theme.accent : (hovering ? Theme.hover : NSColor.clear)).cgColor
        contentTintColor = isOn ? .white : Theme.text
    }
}

/// Two-line read-out for the toolbar: value (with optional colour swatch) over a dim caption.
final class Chip: NSView {
    private let swatch = NSView()
    private let value = NSTextField(labelWithString: "")
    private let caption = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        swatch.wantsLayer = true
        swatch.layer?.cornerRadius = 4
        swatch.layer?.borderWidth = 1
        swatch.layer?.borderColor = NSColor(white: 1, alpha: 0.35).cgColor
        swatch.translatesAutoresizingMaskIntoConstraints = false
        swatch.widthAnchor.constraint(equalToConstant: 12).isActive = true
        swatch.heightAnchor.constraint(equalToConstant: 12).isActive = true
        value.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        value.textColor = Theme.text
        caption.font = .systemFont(ofSize: 9.5)
        caption.textColor = Theme.dim
        let row = NSStackView(views: [swatch, value])
        row.spacing = 6
        row.alignment = .centerY
        let stack = NSStackView(views: [row, caption])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        swatch.isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    func set(_ text: String?, caption cap: String = "", swatch color: NSColor? = nil) {
        isHidden = text == nil
        value.stringValue = text ?? ""
        caption.stringValue = cap
        swatch.isHidden = color == nil
        swatch.layer?.backgroundColor = color?.cgColor
    }
}

func verticalSeparator() -> NSView {
    let v = NSView()
    v.wantsLayer = true
    v.layer?.backgroundColor = Theme.line.cgColor
    v.translatesAutoresizingMaskIntoConstraints = false
    v.widthAnchor.constraint(equalToConstant: 1).isActive = true
    v.heightAnchor.constraint(equalToConstant: 18).isActive = true
    return v
}

/// Scroll view where a classic mouse wheel zooms around the cursor (like the pins do); a trackpad still pans and
/// pinches. ⌥ or ⌘ swaps the behaviour, and the "wheelZoom" preference turns wheel zoom off.
final class ZoomScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        let swapped = !event.modifierFlags.intersection([.option, .command]).isEmpty
        let wheelZooms = Pref.bool("wheelZoom") && !event.hasPreciseScrollingDeltas
        guard allowsMagnification, let doc = documentView, wheelZooms != swapped else { return super.scrollWheel(with: event) }
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY * 0.004 : event.scrollingDeltaY * 0.06
        let target = max(minMagnification, min(maxMagnification, magnification * (1 + delta)))
        setMagnification(target, centeredAt: doc.convert(event.locationInWindow, from: nil))
        NotificationCenter.default.post(name: NSScrollView.didEndLiveMagnifyNotification, object: self)
    }
}
