import AppKit

/// Small HUD shown at the bottom of the main screen ("Copied to the clipboard").
@MainActor
enum Toast {
    private static var panel: NSPanel?
    private static var hideWork: DispatchWorkItem?

    static func show(_ text: String, duration: TimeInterval = 1.6, symbol: String? = nil) {
        // Problems are worth a line in the diagnostic log, whatever the confirmation style.
        if symbol?.contains("exclamation") == true { DiagnosticLog.write(text, category: "warning") }
        // Short-lived progress messages ("Recognizing…") stay on screen only.
        if duration >= 1.5 || symbol != nil { Notifier.post(text) }
        guard Notifier.showsBubble else { return }
        hideWork?.cancel()
        panel?.orderOut(nil)

        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = .white
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 2
        label.preferredMaxLayoutWidth = 520
        let size = label.fittingSize

        let iconWidth: CGFloat = symbol == nil ? 0 : 26
        let box = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: size.width + 40 + iconWidth, height: size.height + 24))
        box.material = .hudWindow
        box.blendingMode = .behindWindow
        box.state = .active
        box.wantsLayer = true
        box.layer?.cornerRadius = min(14, box.frame.height / 2)
        box.layer?.borderWidth = 0.5
        box.layer?.borderColor = NSColor(white: 1, alpha: 0.18).cgColor
        if let symbol, let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)) {
            let icon = NSImageView(image: img)
            icon.contentTintColor = symbol.contains("exclamation") ? NSColor.systemOrange : NSColor.systemGreen
            icon.frame = NSRect(x: 16, y: (box.frame.height - 18) / 2, width: 18, height: 18)
            box.addSubview(icon)
        }
        label.frame.origin = NSPoint(x: 20 + iconWidth, y: 12)
        box.addSubview(label)

        let p = NSPanel(contentRect: box.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .statusBar
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .transient, .fullScreenAuxiliary]
        p.contentView = box
        let restY = (NSScreen.main?.frame.minY ?? 0) + 90
        let x = (NSScreen.main?.frame.midX ?? 0) - box.frame.width / 2
        // Slides up a few points while fading in.
        p.setFrameOrigin(NSPoint(x: x, y: restY - 12))
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup {
            $0.duration = 0.2
            $0.timingFunction = CAMediaTimingFunction(name: .easeOut)
            p.animator().alphaValue = 1
            p.animator().setFrameOrigin(NSPoint(x: x, y: restY))
        }
        panel = p

        let work = DispatchWorkItem {
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; p.animator().alphaValue = 0 }, completionHandler: {
                p.orderOut(nil)
            })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }
}
