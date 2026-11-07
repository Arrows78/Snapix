import AppKit
import SwiftUI

extension Action {
    var symbol: String {
        switch self {
        case .area: return "viewfinder.rectangular"
        case .fullscreen: return "display"
        case .window: return "macwindow"
        case .activeWindow: return "macwindow.badge.plus"
        case .delayed: return "timer"
        case .repeatArea: return "arrow.counterclockwise"
        case .scrolling: return "arrow.down.to.line"
        case .scrollingUp: return "arrow.up.to.line"
        case .scrollingManual: return "hand.draw"
        case .ocr: return "text.viewfinder"
        case .element: return "cursorarrow.rays"
        case .cutout: return "person.crop.circle.badge.minus"
        case .record: return "record.circle"
        case .recordGIF: return "photo.stack"
        case .pickColor: return "eyedropper"
        case .contrast: return "circle.lefthalf.filled"
        case .clipboard: return "doc.on.clipboard"
        case .library: return "photo.on.rectangle"
        case .shortcuts: return "keyboard"
        }
    }

    var tint: Color {
        switch self {
        case .area, .fullscreen, .window, .activeWindow, .element, .delayed, .repeatArea: return Color(nsColor: NSColor(hex: 0x5B8CFF))
        case .scrolling, .scrollingUp, .scrollingManual: return Color(nsColor: NSColor(hex: 0x9B6BFF))
        case .record, .recordGIF: return Color(nsColor: NSColor(hex: 0xFF5A52))
        default: return Color(nsColor: NSColor(hex: 0x2CB1BC))
        }
    }
}

private struct CaptureCard: View {
    let action: Action
    let run: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: run) {
            HStack(spacing: 12) {
                Image(systemName: action.symbol)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(RoundedRectangle(cornerRadius: 9).fill(action.tint.gradient))
                VStack(alignment: .leading, spacing: 3) {
                    Text(action.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white.opacity(0.92))
                        .lineLimit(2).minimumScaleFactor(0.85)
                    Text(action.combo?.display ?? L("No shortcut"))
                        .font(.system(size: 10.5, weight: .medium, design: .monospaced)).foregroundStyle(.white.opacity(0.55))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.07)))
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 66, maxHeight: 66, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(hover ? 0.10 : 0.05)))
            .scaleEffect(hover ? 1.015 : 1)
            .shadow(color: action.tint.opacity(hover ? 0.28 : 0), radius: 10, y: 3)
            .animation(.easeOut(duration: 0.14), value: hover)
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(hover ? 0.18 : 0.08)))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { hover = $0 }
    }
}

private struct HomeView: View {
    let onAction: (Action) -> Void
    let onOpenImage: () -> Void
    let onPreferences: () -> Void
    @AppStorage("hideHome") private var hideHome = false

    private let columns = [GridItem(.adaptive(minimum: 230), spacing: 10)]

    private func section(_ title: LocalizedStringKey, _ actions: [Action]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.45)).textCase(.uppercase)
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(actions, id: \.self) { a in CaptureCard(action: a) { onAction(a) } }
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Snapix").font(.system(size: 22, weight: .bold)).foregroundStyle(.white)
                    Text("Choose a capture type").font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
                }
                Spacer()
                Button(action: onPreferences) { Image(systemName: "gearshape").font(.system(size: 14)) }
                    .buttonStyle(.plain).focusEffectDisabled().foregroundStyle(.white.opacity(0.6)).help(L("Preferences…"))
            }
            section("Capture", [.area, .fullscreen, .window, .activeWindow, .element, .delayed, .repeatArea])
            section("Scrolling", [.scrolling, .scrollingUp, .scrollingManual])
            section("Recording", [.record, .recordGIF])
            section("Tools", [.ocr, .cutout, .pickColor, .contrast])
            Spacer(minLength: 0)
            HStack(spacing: 10) {
                pill("photo.on.rectangle", L("Open Library")) { onAction(.library) }
                pill("doc.on.clipboard", L("Open From Clipboard")) { onAction(.clipboard) }
                pill("folder", L("Open Image…"), onOpenImage)
                pill("keyboard", L("Show Shortcuts")) { onAction(.shortcuts) }
                Spacer()
                Toggle("Show this window at launch", isOn: Binding(get: { !hideHome }, set: { hideHome = !$0 }))
                    .toggleStyle(.checkbox).font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 38)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: Theme.window))
        .preferredColorScheme(.dark)
    }

    private func pill(_ symbol: String, _ title: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Label(title, systemImage: symbol).font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .foregroundStyle(.white.opacity(0.85))
    }
}

/// Start screen listing every capture type with its shortcut; also the way in when the menu bar icon is hidden.
@MainActor
final class HomeWindow: NSObject, NSWindowDelegate {
    static let shared = HomeWindow()
    private var window: NSWindow?

    static func show() { shared.present() }
    static func hide() { shared.window?.orderOut(nil) }

    private func present() {
        if window == nil {
            let view = HomeView(
                onAction: { [weak self] a in self?.run(a) },
                onOpenImage: { [weak self] in self?.dismissThen { EditorWindowController.openFile() } },
                onPreferences: { PreferencesWindow.show() })
            let w = NSWindow(contentViewController: NSHostingController(rootView: view))
            w.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.appearance = NSAppearance(named: .darkAqua)
            w.backgroundColor = Theme.window
            w.isMovableByWindowBackground = true
            w.setContentSize(NSSize(width: 780, height: 700))
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            window = w
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func dismissThen(_ work: @escaping () -> Void) {
        window?.orderOut(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    private func run(_ action: Action) {
        switch action {
        case .library, .clipboard: (NSApp.delegate as? AppDelegate)?.perform(action)
        default: dismissThen { (NSApp.delegate as? AppDelegate)?.perform(action) } // keep the window out of the screenshot
        }
    }

    func windowWillClose(_ notification: Notification) {
        if !EditorWindowController.hasOpenEditors { NSApp.setActivationPolicy(AppDelegate.restingPolicy) }
    }
}
