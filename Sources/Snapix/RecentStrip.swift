import AppKit
import SwiftUI

private struct StripCard: View {
    let item: LibraryItem
    let onClose: () -> Void
    @State private var hover = false

    private func open() {
        if item.kind == .screenshot, let s = History.shot(for: item.url) { EditorWindowController.open(s) } else { NSWorkspace.shared.open(item.url) }
        onClose()
    }

    private func copy() {
        if item.kind == .screenshot, let s = History.shot(for: item.url) { Exporter.copy(s.image, scale: s.scale) }
        else { NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([item.url as NSURL]); Toast.show(L("Copied as file"), symbol: "checkmark.circle.fill") }
    }

    private func button(_ symbol: String, _ tip: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Image(systemName: symbol).font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
                .frame(width: 26, height: 24).background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.55)))
        }
        .buttonStyle(.plain).help(tip)
    }

    var body: some View {
        LibraryThumb(item: item, height: 130)
            .frame(width: 190)
            .overlay(alignment: .bottom) {
                if hover {
                    HStack(spacing: 6) {
                        button(item.kind == .screenshot ? "pencil" : "play.fill", L("Open"), open)
                        button("doc.on.doc", L("Copy"), copy)
                        if item.kind == .screenshot, let s = History.shot(for: item.url) { button("pin", L("Pin to screen")) { PinController.pin(s); onClose() } }
                        button("folder", L("Reveal in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([item.url]); onClose() }
                    }
                    .padding(6)
                    .transition(.opacity)
                }
            }
            .onHover { inside in withAnimation(.easeOut(duration: 0.12)) { hover = inside } }
            .onTapGesture(perform: open)
            .onDrag { NSItemProvider(contentsOf: item.url) ?? NSItemProvider() }
    }
}

private struct StripView: View {
    let items: [LibraryItem]
    let onClose: () -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) { ForEach(items) { StripCard(item: $0, onClose: onClose) } }.padding(14)
        }
        .frame(height: 162)
        .background(Color(nsColor: Theme.window).opacity(0.94))
        .preferredColorScheme(.dark)
    }
}

/// Quick Access as a horizontal strip of recent screenshots and recordings along the bottom of the screen.
@MainActor
enum RecentStrip {
    static let count = 16

    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { true }
        override func resignKey() { super.resignKey(); close() }
        override func cancelOperation(_ sender: Any?) { close() }
    }

    private static var panel: NSPanel?

    /// Width of the strip for `n` cards on a screen `screenWidth` points wide.
    static func width(cards n: Int, screenWidth: CGFloat) -> CGFloat {
        min(max(240, CGFloat(n) * 202 + 26), screenWidth - 80)
    }

    static func toggle() {
        if let p = panel, p.isVisible { p.close(); panel = nil; return }
        let items = Array(LibraryItems.load().prefix(count))
        guard !items.isEmpty else { Toast.show(L("Screenshots you take will appear here."), symbol: "exclamationmark.triangle.fill"); return }
        let screen = Capture.screenUnderMouse()
        let vf = screen.visibleFrame
        let host = NSHostingView(rootView: StripView(items: items, onClose: { panel?.close(); panel = nil }))
        let size = NSSize(width: width(cards: items.count, screenWidth: vf.width), height: 162)
        let p = Panel(contentRect: NSRect(x: vf.midX - size.width / 2, y: vf.minY + 16, width: size.width, height: size.height),
                      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.contentView = host
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .floating
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        host.wantsLayer = true
        host.layer?.cornerRadius = 18
        host.layer?.masksToBounds = true
        host.layer?.borderWidth = 1
        host.layer?.borderColor = NSColor(white: 1, alpha: 0.12).cgColor
        p.alphaValue = 0
        p.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { $0.duration = 0.18; p.animator().alphaValue = 1 }
        panel = p
    }
}
