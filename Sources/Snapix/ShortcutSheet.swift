import AppKit
import SwiftUI

private struct ShortcutSheetView: View {
    private let capture = Action.allCases.filter { $0 != .shortcuts }

    private func row(_ title: String, _ keys: String) -> some View {
        HStack {
            Text(title).font(.system(size: 12)).foregroundStyle(Color.primary.opacity(0.85))
            Spacer(minLength: 12)
            Text(keys).font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(Color.primary.opacity(0.9))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.12)))
        }
    }

    private func column(_ title: String, _ rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.primary.opacity(0.45)).textCase(.uppercase)
            ForEach(rows.indices, id: \.self) { row(rows[$0].0, rows[$0].1) }
        }
        .frame(width: 270, alignment: .topLeading)
    }

    var body: some View {
        VStack(spacing: 14) {
            HStack(alignment: .top, spacing: 28) {
                column(L("Capture"), capture.map { ($0.title, $0.combo?.display ?? "—") })
                column(L("Editor tools"), Tool.allCases.map { ($0.title, $0.key.uppercased()) } + [(L("Backdrop"), "K")])
            }
            Text(L("Press Esc or click to close")).font(.system(size: 11)).foregroundStyle(Color.primary.opacity(0.4))
        }
        .padding(24)
        .background(Color(nsColor: Theme.adaptiveWindow))
    }
}

/// A floating cheat sheet of every shortcut, closed by Esc, a click or switching away.
@MainActor
enum ShortcutSheet {
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { true }
        override func keyDown(with event: NSEvent) { close() }
        override func mouseDown(with event: NSEvent) { close() }
        override func resignKey() { super.resignKey(); close() }
    }

    private static var panel: NSPanel?

    static func show() {
        panel?.close()
        let host = NSHostingView(rootView: ShortcutSheetView())
        let p = Panel(contentRect: NSRect(origin: .zero, size: host.fittingSize), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.contentView = host
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .floating
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        host.wantsLayer = true
        host.layer?.cornerRadius = 14
        host.layer?.masksToBounds = true
        if let screen = NSScreen.main {
            p.setFrameOrigin(NSPoint(x: screen.frame.midX - p.frame.width / 2, y: screen.frame.midY - p.frame.height / 2))
        }
        p.makeKeyAndOrderFront(nil)
        panel = p
    }
}
