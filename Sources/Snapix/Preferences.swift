import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Click, then press the desired shortcut. Delete clears it, Esc cancels.
private final class RecorderField: NSButton {
    var action_: Action = .area
    var onChange: (() -> Void)?
    private var recording = false

    override var acceptsFirstResponder: Bool { true }

    func refresh() {
        title = recording ? L("Press shortcut…") : (action_.combo?.display ?? L("Not set"))
    }

    override func mouseDown(with event: NSEvent) {
        recording = true
        refresh()
        window?.makeFirstResponder(self)
    }

    override func resignFirstResponder() -> Bool {
        recording = false
        refresh()
        return super.resignFirstResponder()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard recording else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard recording else { return super.keyDown(with: event) }
        switch event.keyCode {
        case 53: break
        case 51, 117: action_.combo = nil; onChange?()
        default:
            if let combo = KeyCombo(event: event) { action_.combo = combo; onChange?() } else { NSSound.beep(); return }
        }
        recording = false
        refresh()
        window?.makeFirstResponder(nil)
    }
}

private struct HotkeyRecorder: NSViewRepresentable {
    let action: Action

    func makeNSView(context: Context) -> NSButton {
        let b = RecorderField(title: "", target: nil, action: nil)
        b.action_ = action
        b.bezelStyle = .rounded
        b.onChange = { (NSApp.delegate as? AppDelegate)?.reloadHotkeys() }
        b.refresh()
        return b
    }

    func updateNSView(_ nsView: NSButton, context: Context) { (nsView as? RecorderField)?.refresh() }
}

// MARK: - Layout pieces

private enum Pane: String, CaseIterable, Identifiable {
    case general, capture, recording, editor, shortcuts, output, upload, backup, permissions, about
    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .general: return "General"
        case .capture: return "Capture"
        case .recording: return "Recording"
        case .editor: return "Editor"
        case .shortcuts: return "Shortcuts"
        case .output: return "Saving"
        case .upload: return "Upload"
        case .backup: return "Backup"
        case .permissions: return "Permissions"
        case .about: return "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape.fill"
        case .capture: return "viewfinder"
        case .recording: return "record.circle.fill"
        case .editor: return "pencil.tip.crop.circle.fill"
        case .shortcuts: return "keyboard.fill"
        case .output: return "square.and.arrow.down.fill"
        case .upload: return "icloud.and.arrow.up.fill"
        case .backup: return "externaldrive.fill"
        case .permissions: return "lock.shield.fill"
        case .about: return "info.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .general: return Color(nsColor: NSColor(hex: 0x8E8E93))
        case .capture: return Color(nsColor: NSColor(hex: 0x5B8CFF))
        case .recording: return Color(nsColor: NSColor(hex: 0xFF5A52))
        case .editor: return Color(nsColor: NSColor(hex: 0x9B6BFF))
        case .shortcuts: return Color(nsColor: NSColor(hex: 0xFF9F0A))
        case .output: return Color(nsColor: NSColor(hex: 0x30B06A))
        case .upload: return Color(nsColor: NSColor(hex: 0x2CB1BC))
        case .backup: return Color(nsColor: NSColor(hex: 0x64748B))
        case .permissions: return Color(nsColor: NSColor(hex: 0xE5484D))
        case .about: return Color(nsColor: NSColor(hex: 0x5B8CFF))
        }
    }
}

/// A titled, rounded group of rows.
private struct Card<Content: View>: View {
    var title: LocalizedStringKey?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.45)).textCase(.uppercase).padding(.leading, 4)
            }
            VStack(spacing: 0) { content }
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.05)))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.07)))
        }
    }
}

/// One setting: a title, an optional explanation and the control on the right.
private struct Row<Control: View>: View {
    var title: LocalizedStringKey
    var subtitle: LocalizedStringKey?
    var last = false
    @ViewBuilder var control: Control

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13)).foregroundStyle(.white.opacity(0.92))
                    if let subtitle {
                        Text(subtitle).font(.system(size: 11)).foregroundStyle(.white.opacity(0.45)).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 12)
                control
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            if !last { Divider().overlay(Color.white.opacity(0.06)).padding(.leading, 12) }
        }
    }
}

private struct ToggleRow: View {
    var title: LocalizedStringKey
    var subtitle: LocalizedStringKey?
    @Binding var isOn: Bool
    var last = false

    init(_ title: LocalizedStringKey, _ subtitle: LocalizedStringKey? = nil, isOn: Binding<Bool>, last: Bool = false) {
        self.title = title; self.subtitle = subtitle; self._isOn = isOn; self.last = last
    }

    var body: some View {
        Row(title: title, subtitle: subtitle, last: last) { Toggle("", isOn: $isOn).labelsHidden().toggleStyle(.switch).controlSize(.small) }
    }
}

private struct Page<Content: View>: View {
    var pane: Pane
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 10) {
                    Image(systemName: pane.symbol).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 28, height: 28).background(RoundedRectangle(cornerRadius: 7).fill(pane.tint.gradient))
                    Text(pane.title).font(.system(size: 20, weight: .bold)).foregroundStyle(.white)
                }
                content
            }
            .padding(.horizontal, 24).padding(.top, 34).padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Settings window

struct PreferencesView: View {
    @AppStorage("afterCopy") private var afterCopy = true
    @AppStorage("afterSave") private var afterSave = false
    @AppStorage("afterEdit") private var afterEdit = false
    @AppStorage("afterPreview") private var afterPreview = true
    @AppStorage("previewClosing") private var previewClosing = "8"
    @AppStorage("afterPin") private var afterPin = false
    @AppStorage("previewCorner") private var previewCorner = "bottomRight"
    @AppStorage("previewSize") private var previewSize = "medium"
    @AppStorage("saveFolder") private var saveFolder = ""
    @AppStorage("filenameTemplate") private var template = ""
    @AppStorage("format") private var format = "auto"
    @AppStorage("jpegQuality") private var quality = 0.9
    @AppStorage("downscale") private var downscale = false
    @AppStorage("escCopy") private var escCopy = true
    @AppStorage("escSave") private var escSave = false
    @AppStorage("colorFormat") private var colorFormat = "hex"
    @AppStorage("ocrRemoveBreaks") private var removeBreaks = false
    @AppStorage("ocrLanguage") private var ocrLanguage = "auto"
    @AppStorage("reverseScroll") private var reverseScroll = false
    @AppStorage("pinsOnTop") private var pinsOnTop = true
    @AppStorage("areaAdjust") private var areaAdjust = false
    @AppStorage("snapEdges") private var snapEdges = true
    @AppStorage("showDockIcon") private var showDockIcon = false
    @AppStorage("hideHome") private var hideHome = false
    @AppStorage("wheelZoom") private var wheelZoom = true
    @AppStorage("largerWindow") private var largerWindow = false
    @AppStorage("editorOnTop") private var editorOnTop = false
    @AppStorage("keepHistory") private var keepHistory = true
    @AppStorage("historyRetentionDays") private var retentionDays = 0
    @AppStorage("captureSound") private var captureSound = true
    @AppStorage("captureDelay") private var captureDelay = 3
    @AppStorage("hideDesktopIcons") private var hideDesktopIcons = false
    @AppStorage("recordAudio") private var recordAudio = false
    @AppStorage("recordCursor") private var recordCursor = true
    @AppStorage("recordReveal") private var recordReveal = false
    @AppStorage("recordCountdown") private var recordCountdown = 3
    @AppStorage("recordReview") private var recordReview = true
    @AppStorage("uploadURL") private var uploadURL = ""
    @AppStorage("uploadField") private var uploadField = "file"
    @AppStorage("uploadAuthHeader") private var uploadAuth = ""
    @State private var launchAtLogin = Pref.launchAtLogin
    @State private var pane = Pane.general
    @State private var shortcutsVersion = 0
    @State private var permissionsVersion = 0

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider().overlay(Color.white.opacity(0.08))
            Group {
                switch pane {
                case .general: general
                case .capture: capture
                case .recording: recording
                case .editor: editor
                case .shortcuts: shortcuts
                case .output: output
                case .upload: upload
                case .backup: backup
                case .permissions: permissions
                case .about: about
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 780, height: 580)
        .background(Color(nsColor: Theme.window))
        .preferredColorScheme(.dark)
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Pane.allCases) { p in
                Button { pane = p } label: {
                    HStack(spacing: 9) {
                        Image(systemName: p.symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                            .frame(width: 22, height: 22).background(RoundedRectangle(cornerRadius: 6).fill(p.tint.gradient))
                        Text(p.title).font(.system(size: 13)).foregroundStyle(.white.opacity(pane == p ? 1 : 0.8))
                        Spacer()
                    }
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(pane == p ? 0.12 : 0)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if p == .recording || p == .upload { Spacer().frame(height: 8) }
            }
            Spacer()
        }
        .padding(.horizontal, 10).padding(.top, 38)
        .frame(width: 190)
        .background(Color.black.opacity(0.18))
    }

    // MARK: Panes

    private var general: some View {
        Page(pane: .general) {
            Card(title: "After taking a screenshot") {
                ToggleRow("Copy to clipboard", isOn: $afterCopy)
                ToggleRow("Save to folder", isOn: $afterSave)
                ToggleRow("Show floating preview", isOn: $afterPreview, last: !afterPreview)
                if afterPreview {
                    Row(title: "Close the preview", last: false) {
                        Picker("", selection: $previewClosing) {
                            Text("After 4 seconds").tag("4"); Text("After 8 seconds").tag("8"); Text("After 15 seconds").tag("15"); Text("Never").tag("never")
                        }.labelsHidden().frame(width: 160)
                    }
                }
                ToggleRow("Show in editor", isOn: $afterEdit)
                ToggleRow("Pin to screen", isOn: $afterPin, last: true)
            }
            Card(title: "Quick Access") {
                Row(title: "Position") {
                    Picker("", selection: $previewCorner) {
                        Text("Bottom right").tag("bottomRight"); Text("Bottom left").tag("bottomLeft")
                        Text("Top right").tag("topRight"); Text("Top left").tag("topLeft")
                    }.labelsHidden().frame(width: 160)
                }
                Row(title: "Size", subtitle: "Hover a preview and press ⌘C to copy, ⌘S to save, ⌘E or Return to edit, ⌘P to pin, Delete to remove it, Esc to close.", last: true) {
                    Picker("", selection: $previewSize) {
                        Text("Small").tag("small"); Text("Medium").tag("medium"); Text("Large").tag("large")
                    }.labelsHidden().frame(width: 160)
                }
            }
            Card(title: "When closing the editor with Esc") {
                ToggleRow("Copy to clipboard", isOn: $escCopy)
                ToggleRow("Save to folder", isOn: $escSave, last: true)
            }
            Card(title: "Startup") {
                ToggleRow("Launch at login", isOn: Binding(get: { launchAtLogin }, set: { launchAtLogin = $0; Pref.setLaunchAtLogin($0) }))
                ToggleRow("Show the home window at launch", isOn: Binding(get: { !hideHome }, set: { hideHome = !$0 }))
                ToggleRow("Show Snapix in the Dock", isOn: $showDockIcon, last: true)
                    .onChange(of: showDockIcon) { _, _ in NSApp.setActivationPolicy(AppDelegate.restingPolicy) }
            }
        }
    }

    private var capture: some View {
        Page(pane: .capture) {
            Card(title: "Screenshots") {
                ToggleRow("Play a sound when a screenshot is taken", isOn: $captureSound)
                ToggleRow("Hide desktop icons", "Files on the desktop stay out of screenshots and recordings.", isOn: $hideDesktopIcons)
                Row(title: "Delayed screenshot timer", last: true) {
                    Picker("", selection: $captureDelay) { ForEach([3, 5, 10, 15], id: \.self) { Text("\($0) s").tag($0) } }.labelsHidden().frame(width: 100)
                }
            }
            Card(title: "Area selection") {
                ToggleRow("Adjust the selection before capturing",
                          "Drag handles to resize, drag inside (or hold Space while dragging) to move, Return or double-click to capture.", isOn: $areaAdjust)
                ToggleRow("Reverse direction for automatic scrolling capture", "Enable this if a third-party app reverses your scroll direction.", isOn: $reverseScroll, last: true)
            }
            Card(title: "Library") {
                ToggleRow("Keep a history of screenshots in the Library", isOn: $keepHistory, last: !keepHistory)
                if keepHistory {
                    Row(title: "Delete library screenshots", last: true) {
                        Picker("", selection: $retentionDays) {
                            Text("Never").tag(0); Text("After 7 days").tag(7); Text("After 30 days").tag(30); Text("After 90 days").tag(90)
                        }.labelsHidden().frame(width: 140)
                    }
                }
            }
        }
    }

    private var recording: some View {
        Page(pane: .recording) {
            Card(title: "Screen recording") {
                Row(title: "Countdown before recording") {
                    Picker("", selection: $recordCountdown) {
                        Text("None").tag(0); Text("3 s").tag(3); Text("5 s").tag(5)
                    }.labelsHidden().frame(width: 100)
                }
                ToggleRow("Record the mouse cursor", isOn: $recordCursor)
                ToggleRow("Record system audio (MP4 only)", isOn: $recordAudio)
                ToggleRow("Review and trim before saving", "Opens the recording in a player where you can cut the start and the end.", isOn: $recordReview)
                ToggleRow("Show the file in Finder when done", isOn: $recordReveal, last: true)
            }
            Text("Press the shortcut again, or click Stop, to end a recording. The file is saved in your screenshots folder and copied to the clipboard.")
                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
        }
    }

    private var editor: some View {
        Page(pane: .editor) {
            Card(title: "Editing") {
                Row(title: "Color format") {
                    Picker("", selection: $colorFormat) { ForEach(ColorFormat.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) } }.labelsHidden().frame(width: 140)
                }
                ToggleRow("Snap shapes to edges in the screenshot (hold ⌥ to disable)", isOn: $snapEdges)
                ToggleRow("Mouse wheel zooms the image (trackpad scrolls, ⌥ or ⌘ swaps)", isOn: $wheelZoom)
                ToggleRow("Open the editor in a larger window", isOn: $largerWindow)
                ToggleRow("Keep the editor above other windows", isOn: $editorOnTop, last: true)
            }
            Card(title: "Text recognition") {
                ToggleRow("Remove line breaks from recognized text", isOn: $removeBreaks)
                Row(title: "Recognition language", last: true) {
                    Picker("", selection: $ocrLanguage) {
                        Text("Automatic").tag("auto")
                        ForEach(OCR.supportedLanguages, id: \.self) { code in
                            Text(Locale.current.localizedString(forIdentifier: code) ?? code).tag(code)
                        }
                    }.labelsHidden().frame(width: 200)
                }
            }
            RedactionCard()
        }
    }

    private var shortcuts: some View {
        Page(pane: .shortcuts) {
            Card {
                ForEach(Array(Action.allCases.enumerated()), id: \.element) { i, a in
                    Row(title: LocalizedStringKey(a.title), last: i == Action.allCases.count - 1) { HotkeyRecorder(action: a).frame(width: 150) }
                }
            }
            .id(shortcutsVersion)
            Button("Restore Default Shortcuts") {
                Pref.resetShortcuts()
                (NSApp.delegate as? AppDelegate)?.reloadHotkeys()
                shortcutsVersion += 1
            }
            Text("Turn off the macOS screenshot shortcuts in System Settings › Keyboard › Keyboard Shortcuts › Screenshots if they clash.")
                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
        }
    }

    private var output: some View {
        Page(pane: .output) {
            Card(title: "Destination") {
                Row(title: "Folder") {
                    HStack {
                        TextField("", text: $saveFolder).textFieldStyle(.roundedBorder).frame(width: 220)
                        Button("Choose…") {
                            let p = NSOpenPanel()
                            p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
                            if p.runModal() == .OK, let url = p.url { saveFolder = url.path }
                        }
                    }
                }
                Row(title: "File name", subtitle: "Placeholders: {date} {time} {timestamp} {app}", last: true) {
                    TextField("", text: $template).textFieldStyle(.roundedBorder).frame(width: 220)
                }
            }
            Card(title: "Format") {
                Row(title: "Format") {
                    Picker("", selection: $format) {
                        Text("Automatic (PNG or JPEG by content)").tag("auto"); Text("PNG").tag("png"); Text("JPEG").tag("jpeg")
                    }.labelsHidden().frame(width: 240)
                }
                if format != "png" {
                    Row(title: "JPEG quality") { Slider(value: $quality, in: 0.3...1).frame(width: 180) }
                }
                ToggleRow("Downscale Retina screenshots to 1×", isOn: $downscale, last: true)
            }
            Card(title: "Pins") {
                ToggleRow("Pins stay on top of other windows", isOn: $pinsOnTop, last: true)
            }
        }
    }

    private var upload: some View {
        Page(pane: .upload) {
            Card(title: "Endpoint") {
                Row(title: "Endpoint URL") { TextField("https://example.com/upload", text: $uploadURL).textFieldStyle(.roundedBorder).frame(width: 260) }
                Row(title: "Form field name") { TextField("", text: $uploadField).textFieldStyle(.roundedBorder).frame(width: 260) }
                Row(title: "Authorization header (optional)", last: true) { SecureField("", text: $uploadAuth).textFieldStyle(.roundedBorder).frame(width: 260) }
            }
            Text("Images are sent as multipart/form-data. The response (plain URL or JSON with a \"url\" key) is copied to the clipboard.")
                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.45))
        }
    }

    private var backup: some View {
        Page(pane: .backup) {
            Card(title: "Settings backup") {
                Row(title: "Export Settings…", subtitle: "A backup holds your preferences, shortcuts and backdrop style. The upload authorization header is never exported.") {
                    Button("Export…", action: exportSettings)
                }
                Row(title: "Import Settings…", last: true) { Button("Import…", action: importSettings) }
            }
            Card(title: "Reset") {
                Row(title: "Restore default settings", subtitle: "Preferences, shortcuts and the backdrop style go back to their defaults. Your screenshots are kept.", last: true) {
                    Button("Restore…", role: .destructive, action: resetSettings)
                }
            }
        }
    }

    private var permissions: some View {
        Page(pane: .permissions) {
            Card(title: "Required") {
                PermissionRow(title: "Screen Recording", detail: "Needed to capture and record your screen.", granted: CGPreflightScreenCaptureAccess(),
                              url: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture", last: false)
                PermissionRow(title: "Accessibility", detail: "Needed to capture interface elements by hovering them.", granted: ElementPicker.isTrusted,
                              url: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility", last: true)
            }
            .id(permissionsVersion)
            Button("Refresh") { permissionsVersion += 1 }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in permissionsVersion += 1 }
    }

    private var about: some View {
        Page(pane: .about) {
            HStack(spacing: 16) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Snapix").font(.system(size: 22, weight: .bold)).foregroundStyle(.white)
                    Text(Self.versionString).font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
                    Text("Capture, annotate, polish, read text. Everything stays on your Mac.").font(.system(size: 12)).foregroundStyle(.white.opacity(0.6))
                }
            }
            Card {
                Row(title: "Source code and releases") {
                    HStack {
                        Button("GitHub") { NSWorkspace.shared.open(URL(string: "https://github.com/Arrows78/Snapix")!) }
                        Button("Releases") { NSWorkspace.shared.open(URL(string: "https://github.com/Arrows78/Snapix/releases")!) }
                    }
                }
                Row(title: "Updates", subtitle: "Asks GitHub for the latest release when you click. Snapix never checks on its own.") {
                    HStack {
                        Button("Check for Updates…") { UpdateCheck.run() }
                        Button("Welcome Tour") { Onboarding.show() }
                    }
                }
                Row(title: "Diagnostics", subtitle: "Copies the version, macOS version and permissions, to paste into a bug report. It contains no personal data.", last: true) {
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(Self.diagnostics, forType: .string)
                        Toast.show(L("Copied to the clipboard"), symbol: "checkmark.circle.fill")
                    }
                }
            }
        }
    }

    static var versionString: String {
        let info = Bundle.main.infoDictionary
        return "\(L("Version")) \(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
    }

    static var diagnostics: String {
        """
        Snapix \(versionString)
        macOS \(ProcessInfo.processInfo.operatingSystemVersionString)
        Screen Recording: \(CGPreflightScreenCaptureAccess() ? "granted" : "missing")
        Accessibility: \(ElementPicker.isTrusted ? "granted" : "missing")
        """
    }

    // MARK: Actions

    private func exportSettings() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.propertyList]
        panel.nameFieldStringValue = "Snapix Settings.plist"
        guard panel.runModal() == .OK, let url = panel.url, let data = Pref.backupData() else { return }
        do {
            try data.write(to: url)
            Toast.show(L("Settings exported"), symbol: "checkmark.circle.fill")
        } catch {
            Toast.show(LF("Capture failed: %@", error.localizedDescription), duration: 3, symbol: "exclamationmark.triangle.fill")
        }
    }

    private func importSettings() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.propertyList]
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        guard Pref.restore(data) != nil else { Toast.show(L("This file is not a Snapix backup"), duration: 3, symbol: "exclamationmark.triangle.fill"); return }
        (NSApp.delegate as? AppDelegate)?.reloadHotkeys()
        Toast.show(L("Settings imported — reopen Preferences to see them"), duration: 3, symbol: "checkmark.circle.fill")
        PreferencesWindow.close()
    }

    private func resetSettings() {
        let alert = NSAlert()
        alert.messageText = L("Restore default settings?")
        alert.informativeText = L("Preferences, shortcuts and the backdrop style go back to their defaults. Your screenshots are kept.")
        alert.addButton(withTitle: L("Restore"))
        alert.addButton(withTitle: L("Cancel"))
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Pref.resetAll()
        (NSApp.delegate as? AppDelegate)?.reloadHotkeys()
        PreferencesWindow.close()
        Toast.show(L("Settings restored"), symbol: "checkmark.circle.fill")
    }
}

/// Which kinds of text "Hide Sensitive Data" looks for.
private struct RedactionCard: View {
    @AppStorage("redact.email") private var email = true
    @AppStorage("redact.card") private var card = true
    @AppStorage("redact.iban") private var iban = true
    @AppStorage("redact.secret") private var secret = true
    @AppStorage("redact.phone") private var phone = true
    @AppStorage("redact.ipAddress") private var ip = true

    var body: some View {
        Card(title: "Hide Sensitive Data") {
            ToggleRow("Email addresses", isOn: $email)
            ToggleRow("Card numbers", isOn: $card)
            ToggleRow("Bank account numbers (IBAN)", isOn: $iban)
            ToggleRow("API keys and tokens", isOn: $secret)
            ToggleRow("Phone numbers", isOn: $phone)
            ToggleRow("IP addresses", isOn: $ip, last: true)
        }
    }
}

private struct PermissionRow: View {
    var title: LocalizedStringKey
    var detail: LocalizedStringKey
    var granted: Bool
    var url: String
    var last: Bool

    var body: some View {
        Row(title: title, subtitle: detail, last: last) {
            HStack(spacing: 8) {
                Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill").foregroundStyle(granted ? Color.green : Color.orange)
                if !granted { Button("Open System Settings") { NSWorkspace.shared.open(URL(string: url)!) } }
            }
        }
    }
}

@MainActor
enum PreferencesWindow {
    private static var window: NSWindow?

    static func close() {
        window?.close()
        window = nil
    }

    static func show() {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: PreferencesView()))
            w.title = L("Snapix Preferences")
            w.styleMask = [.titled, .closable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.appearance = NSAppearance(named: .darkAqua)
            w.backgroundColor = Theme.window
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
