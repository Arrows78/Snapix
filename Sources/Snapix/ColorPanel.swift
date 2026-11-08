import AppKit
import SwiftUI

/// Remembers the colours picked on screen, newest first.
enum RecentColors {
    static let limit = 8
    private static let key = "recentColors"

    static func all(in store: UserDefaults = .standard) -> [UInt32] {
        (store.array(forKey: key) as? [Int] ?? []).map { UInt32(truncatingIfNeeded: $0) }
    }

    static func add(_ hex: UInt32, in store: UserDefaults = .standard) {
        var list = all(in: store).filter { $0 != hex }
        list.insert(hex, at: 0)
        store.set(list.prefix(limit).map { Int($0) }, forKey: key)
    }

    static func clear(in store: UserDefaults = .standard) { store.removeObject(forKey: key) }
}

private struct ColorPanelView: View {
    @State var hex: UInt32
    @State private var copied: ColorFormat?
    let onClose: () -> Void

    private var color: NSColor { NSColor(hex: hex) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: color)).frame(width: 44, height: 44)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.25)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(ColorFormat.hex.string(for: color)).font(.system(size: 16, weight: .semibold, design: .monospaced)).foregroundStyle(.primary)
                    Text("Click a value to copy it").font(.system(size: 11)).foregroundStyle(Color.primary.opacity(0.5))
                }
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)) }.buttonStyle(.plain).foregroundStyle(Color.primary.opacity(0.6))
            }
            VStack(spacing: 0) {
                ForEach(ColorFormat.allCases, id: \.rawValue) { f in
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(f.string(for: color), forType: .string)
                        copied = f
                    } label: {
                        HStack {
                            Text(f.label).font(.system(size: 11)).foregroundStyle(Color.primary.opacity(0.55)).frame(width: 64, alignment: .leading)
                            Text(f.string(for: color)).font(.system(size: 11, design: .monospaced)).foregroundStyle(Color.primary.opacity(0.92)).lineLimit(1)
                            Spacer()
                            if copied == f { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.green) }
                        }
                        .padding(.vertical, 5).padding(.horizontal, 8).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
            let recent = RecentColors.all()
            if recent.count > 1 {
                HStack(spacing: 6) {
                    Text("Recent").font(.system(size: 11)).foregroundStyle(Color.primary.opacity(0.5))
                    ForEach(recent, id: \.self) { h in
                        Button { hex = h; copied = nil } label: {
                            Circle().fill(Color(nsColor: NSColor(hex: h))).frame(width: 18, height: 18).overlay(Circle().stroke(Color.primary.opacity(h == hex ? 0.9 : 0.25), lineWidth: 1))
                        }.buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 320)
        .background(Color(nsColor: Theme.adaptiveWindow))
    }
}

/// A floating card listing a picked colour in every format.
@MainActor
enum ColorPanel {
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { true }
        override func resignKey() { super.resignKey(); close() }
        override func cancelOperation(_ sender: Any?) { close() }
    }

    private static var panel: NSPanel?

    static func show(_ color: NSColor) {
        panel?.close()
        let host = NSHostingView(rootView: ColorPanelView(hex: color.hexValue, onClose: { panel?.close() }))
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
        host.layer?.borderWidth = 1
        host.layer?.borderColor = NSColor(white: 1, alpha: 0.12).cgColor
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let vf = screen?.visibleFrame ?? .zero
        p.setFrameOrigin(NSPoint(x: max(vf.minX + 8, min(vf.maxX - p.frame.width - 8, mouse.x + 18)), y: max(vf.minY + 8, min(vf.maxY - p.frame.height - 8, mouse.y - p.frame.height - 18))))
        p.makeKeyAndOrderFront(nil)
        panel = p
    }
}
