import AppKit

/// Draws the small arrow-style glyphs shown in the options panel (template images, tinted by the button).
enum ArrowGlyph {
    static func image(style: Int) -> NSImage {
        let img = NSImage(size: NSSize(width: 22, height: 14), flipped: false) { _ in
            NSColor.black.set()
            let line = NSBezierPath()
            line.lineWidth = 2
            line.lineCapStyle = .round
            switch style {
            case 1: // open chevron
                line.move(to: NSPoint(x: 2, y: 7)); line.line(to: NSPoint(x: 19, y: 7))
                line.move(to: NSPoint(x: 14, y: 2)); line.line(to: NSPoint(x: 19.5, y: 7)); line.line(to: NSPoint(x: 14, y: 12))
                line.stroke()
            case 2: // tapered wedge
                let p = NSBezierPath()
                p.move(to: NSPoint(x: 2, y: 7)); p.line(to: NSPoint(x: 13, y: 4.6)); p.line(to: NSPoint(x: 13, y: 2))
                p.line(to: NSPoint(x: 20, y: 7)); p.line(to: NSPoint(x: 13, y: 12)); p.line(to: NSPoint(x: 13, y: 9.4))
                p.close(); p.fill()
            default: // classic filled head
                line.move(to: NSPoint(x: 2, y: 7)); line.line(to: NSPoint(x: 14, y: 7)); line.stroke()
                let head = NSBezierPath()
                head.move(to: NSPoint(x: 13, y: 2.5)); head.line(to: NSPoint(x: 20.5, y: 7)); head.line(to: NSPoint(x: 13, y: 11.5))
                head.close(); head.fill()
            }
            return true
        }
        img.isTemplate = true
        return img
    }
}

/// Floating tool-options card over the canvas (colour, thickness, style), collapsible with its chevron.
final class OptionsPanel: NSVisualEffectView {
    struct Option {
        var image: NSImage
        var tip: String
    }

    var onColor: ((NSColor) -> Void)?
    var onSlider: ((Double) -> Void)?
    var onOption: ((Int) -> Void)?

    private let colorWell = NSColorWell(style: .minimal)
    private let slider = NSSlider(value: 4, minValue: 1, maxValue: 30, target: nil, action: nil)
    private let optionStack = NSStackView()
    private var collapseButton: IconButton!
    private let content = NSStackView()
    private var collapsed = false
    private var wantsVisible = false

    init() {
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(white: 1, alpha: 0.10).cgColor

        collapseButton = IconButton(symbol: "chevron.right", tip: L("Options"), target: self, action: #selector(toggleCollapse),
                                    size: NSSize(width: 22, height: 26), pointSize: 11)

        colorWell.target = self
        colorWell.action = #selector(colorChanged)
        colorWell.translatesAutoresizingMaskIntoConstraints = false
        colorWell.widthAnchor.constraint(equalToConstant: 32).isActive = true

        slider.target = self
        slider.action = #selector(sliderChanged)
        slider.controlSize = .small
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.widthAnchor.constraint(equalToConstant: 96).isActive = true
        slider.toolTip = L("Size / thickness")

        optionStack.orientation = .horizontal
        optionStack.spacing = 4

        content.orientation = .horizontal
        content.alignment = .centerY
        content.spacing = 10
        content.setViews([colorWell, slider, optionStack], in: .leading)

        let row = NSStackView(views: [collapseButton, content])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 10)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor), row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor), row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Shows only the controls the active tool uses; hides the whole card when there are none.
    func configure(showColor: Bool, showSlider: Bool, options: [Option], selected: Int) {
        colorWell.isHidden = !showColor
        slider.isHidden = !showSlider
        optionStack.arrangedSubviews.forEach { optionStack.removeArrangedSubview($0); $0.removeFromSuperview() }
        for (i, o) in options.enumerated() {
            let b = IconButton(symbol: "circle", tip: o.tip, target: self, action: #selector(optionTapped(_:)), size: NSSize(width: 30, height: 24), pointSize: 13)
            b.image = o.image
            b.tag = i
            b.isOn = i == selected
            optionStack.addArrangedSubview(b)
        }
        optionStack.isHidden = options.isEmpty
        wantsVisible = showColor || showSlider || !options.isEmpty
        isHidden = !wantsVisible
    }

    func setColor(_ c: NSColor) { colorWell.color = c }
    func setSlider(_ v: Double) { slider.doubleValue = v }

    func select(_ index: Int) {
        for case let b as IconButton in optionStack.arrangedSubviews { b.isOn = b.tag == index }
    }

    @objc private func toggleCollapse() {
        collapsed.toggle()
        content.isHidden = collapsed
        collapseButton.image = NSImage(systemSymbolName: collapsed ? "chevron.left" : "chevron.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .regular))
    }

    @objc private func colorChanged() { onColor?(colorWell.color) }
    @objc private func sliderChanged() { onSlider?(slider.doubleValue) }
    @objc private func optionTapped(_ s: NSButton) { select(s.tag); onOption?(s.tag) }
}

/// Dark checkerboard behind the image, like transparent areas in most editors. Fills the whole workspace.
final class CheckerView: NSView {
    init() {
        super.init(frame: .zero)
        wantsLayer = true
        let cell: CGFloat = 12
        let tile = NSImage(size: NSSize(width: cell * 2, height: cell * 2), flipped: false) { rect in
            NSColor(hex: 0x252528).setFill()
            rect.fill()
            NSColor(hex: 0x2D2D31).setFill()
            NSRect(x: 0, y: cell, width: cell, height: cell).fill()
            NSRect(x: cell, y: 0, width: cell, height: cell).fill()
            return true
        }
        layer?.backgroundColor = NSColor(patternImage: tile).cgColor
    }

    required init?(coder: NSCoder) { fatalError() }
}
