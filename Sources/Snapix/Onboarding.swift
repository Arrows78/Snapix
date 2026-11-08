import AppKit
import SwiftUI

private struct OnboardingView: View {
    var onDone: () -> Void
    @State private var page = 0
    @State private var screenGranted = CGPreflightScreenCaptureAccess()
    @State private var axGranted = ElementPicker.isTrusted
    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private let highlights: [(String, String, String)] = [
        ("viewfinder", "Capture anything", "Area, window, fullscreen, scrolling pages, interface elements."),
        ("pencil.tip.crop.circle", "Annotate and polish", "Arrows, blur, spotlight, counters and a backdrop."),
        ("text.viewfinder", "Read and protect", "Copy text and QR codes, hide sensitive data automatically."),
        ("record.circle", "Record", "Area recordings as MP4 or GIF, with trimming."),
    ]

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch page {
                case 0: welcome
                case 1: permissions
                default: shortcuts
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.opacity)

            HStack {
                HStack(spacing: 6) {
                    ForEach(0..<3, id: \.self) { Circle().fill(Color.primary.opacity($0 == page ? 0.9 : 0.25)).frame(width: 6, height: 6) }
                }
                Spacer()
                if page > 0 { Button("Back") { withAnimation { page -= 1 } } }
                Button(page == 2 ? "Get Started" : "Continue") { if page == 2 { onDone() } else { withAnimation { page += 1 } } }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 28).padding(.vertical, 18)
        }
        .frame(width: 560, height: 460)
        .background(Color(nsColor: Theme.adaptiveWindow))
        .onReceive(poll) { _ in screenGranted = CGPreflightScreenCaptureAccess(); axGranted = ElementPicker.isTrusted }
    }

    private var welcome: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 84, height: 84)
            Text("Welcome to Snapix").font(.system(size: 26, weight: .bold)).foregroundStyle(.primary)
            VStack(alignment: .leading, spacing: 12) {
                ForEach(highlights, id: \.0) { h in
                    HStack(spacing: 12) {
                        Image(systemName: h.0).font(.system(size: 16, weight: .medium)).foregroundStyle(Color(nsColor: Theme.accent)).frame(width: 28)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(LocalizedStringKey(h.1)).font(.system(size: 13, weight: .semibold)).foregroundStyle(.primary)
                            Text(LocalizedStringKey(h.2)).font(.system(size: 12)).foregroundStyle(Color.primary.opacity(0.55))
                        }
                    }
                }
            }
        }
        .padding(.top, 36)
    }

    private func permissionRow(_ title: LocalizedStringKey, _ detail: LocalizedStringKey, _ granted: Bool, optional: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : (optional ? "circle.dashed" : "exclamationmark.circle.fill"))
                .font(.system(size: 20)).foregroundStyle(granted ? Color.green : (optional ? Color.gray : Color.orange))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.primary)
                Text(detail).font(.system(size: 11)).foregroundStyle(Color.primary.opacity(0.55))
            }
            Spacer()
            if !granted { Button("Allow", action: action) }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Permissions").font(.system(size: 22, weight: .bold)).foregroundStyle(.primary)
            Text("Snapix needs macOS to let it see your screen. Nothing ever leaves your Mac.").font(.system(size: 12)).foregroundStyle(Color.primary.opacity(0.55))
            permissionRow("Screen Recording", "Required to capture and record.", screenGranted, optional: false) {
                CGRequestScreenCaptureAccess()
                if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") { NSWorkspace.shared.open(u) }
            }
            permissionRow("Accessibility", "Optional: capture interface elements by hovering them.", axGranted, optional: true) { ElementPicker.requestAccess() }
            Text("You may need to relaunch Snapix after allowing Screen Recording.").font(.system(size: 11)).foregroundStyle(Color.primary.opacity(0.4))
            Spacer()
        }
        .padding(.horizontal, 32).padding(.top, 36)
    }

    private var shortcuts: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Your shortcuts").font(.system(size: 22, weight: .bold)).foregroundStyle(.primary)
            Text("Snapix lives in the menu bar. These work from anywhere; change them in Preferences.").font(.system(size: 12)).foregroundStyle(Color.primary.opacity(0.55))
            VStack(spacing: 0) {
                ForEach(Action.allCases.filter { $0.combo != nil }, id: \.self) { a in
                    HStack {
                        Text(a.title).font(.system(size: 13)).foregroundStyle(Color.primary.opacity(0.9))
                        Spacer()
                        HStack(spacing: 4) {
                            ForEach(Array((a.combo?.keys ?? []).enumerated()), id: \.offset) { _, k in
                                Text(k).font(.system(size: 13, weight: .semibold, design: .rounded)).foregroundStyle(Color.primary.opacity(0.85))
                                    .frame(minWidth: 22, minHeight: 22).background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.1)))
                            }
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 7)
                }
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
            Spacer()
        }
        .padding(.horizontal, 32).padding(.top, 36)
    }
}

@MainActor
enum Onboarding {
    private static var window: NSWindow?

    static var needed: Bool { !Pref.bool("onboarded") }

    static func show() {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: OnboardingView(onDone: finish)))
            w.styleMask = [.titled, .closable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.backgroundColor = Theme.adaptiveWindow
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    static func finish() {
        UserDefaults.standard.set(true, forKey: "onboarded")
        window?.close()
        window = nil
        NSApp.setActivationPolicy(AppDelegate.restingPolicy)
        if !Pref.bool("hideHome") { HomeWindow.show() }
    }
}
