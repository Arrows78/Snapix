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

struct PreferencesView: View {
    @AppStorage("afterCopy") private var afterCopy = true
    @AppStorage("afterSave") private var afterSave = false
    @AppStorage("afterEdit") private var afterEdit = false
    @AppStorage("afterPreview") private var afterPreview = true
    @AppStorage("previewClosing") private var previewClosing = "8"
    @AppStorage("afterPin") private var afterPin = false
    @AppStorage("saveFolder") private var saveFolder = ""
    @AppStorage("filenameTemplate") private var template = ""
    @AppStorage("format") private var format = "auto"
    @AppStorage("jpegQuality") private var quality = 0.9
    @AppStorage("downscale") private var downscale = false
    @AppStorage("escCopy") private var escCopy = true
    @AppStorage("escSave") private var escSave = false
    @AppStorage("colorFormat") private var colorFormat = "hex"
    @AppStorage("ocrRemoveBreaks") private var removeBreaks = false
    @AppStorage("reverseScroll") private var reverseScroll = false
    @AppStorage("pinsOnTop") private var pinsOnTop = true
    @AppStorage("areaAdjust") private var areaAdjust = false
    @AppStorage("snapEdges") private var snapEdges = true
    @AppStorage("showDockIcon") private var showDockIcon = false
    @AppStorage("wheelZoom") private var wheelZoom = true
    @AppStorage("keepHistory") private var keepHistory = true
    @AppStorage("historyRetentionDays") private var retentionDays = 0
    @AppStorage("recordAudio") private var recordAudio = false
    @AppStorage("recordCursor") private var recordCursor = true
    @AppStorage("recordReveal") private var recordReveal = false
    @AppStorage("captureSound") private var captureSound = true
    @AppStorage("captureDelay") private var captureDelay = 3
    @AppStorage("uploadURL") private var uploadURL = ""
    @AppStorage("uploadField") private var uploadField = "file"
    @AppStorage("uploadAuthHeader") private var uploadAuth = ""
    @State private var launchAtLogin = Pref.launchAtLogin

    var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "gearshape") }
            saving.tabItem { Label("Saving", systemImage: "square.and.arrow.down") }
            hotkeys.tabItem { Label("Shortcuts", systemImage: "keyboard") }
            tools.tabItem { Label("Tools", systemImage: "wand.and.stars") }
            upload.tabItem { Label("Upload", systemImage: "icloud.and.arrow.up") }
            backup.tabItem { Label("Backup", systemImage: "externaldrive") }
        }
        .frame(width: 520, height: 430)
        .padding(12)
    }

    private var general: some View {
        Form {
            Section("After taking a screenshot") {
                Toggle("Copy to clipboard", isOn: $afterCopy)
                Toggle("Save to folder", isOn: $afterSave)
                Toggle("Show floating preview", isOn: $afterPreview)
                if afterPreview {
                    Picker("Close the preview", selection: $previewClosing) {
                        Text("After 4 seconds").tag("4")
                        Text("After 8 seconds").tag("8")
                        Text("After 15 seconds").tag("15")
                        Text("Never").tag("never")
                    }
                }
                Toggle("Show in editor", isOn: $afterEdit)
                Toggle("Pin to screen", isOn: $afterPin)
            }
            Section("Capture") {
                Toggle("Play a sound when a screenshot is taken", isOn: $captureSound)
                Picker("Delayed screenshot timer", selection: $captureDelay) {
                    ForEach([3, 5, 10, 15], id: \.self) { Text("\($0) s").tag($0) }
                }
            }
            Section("Screen recording") {
                Toggle("Record the mouse cursor", isOn: $recordCursor)
                Toggle("Record system audio (MP4 only)", isOn: $recordAudio)
                Toggle("Show the file in Finder when done", isOn: $recordReveal)
                Text("Press the shortcut again, or click Stop, to end a recording. The file is saved in your screenshots folder and copied to the clipboard.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Area selection") {
                Toggle("Adjust the selection before capturing", isOn: $areaAdjust)
                Text("Drag handles to resize, drag inside (or hold Space while dragging) to move, Return or double-click to capture.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("When closing the editor with Esc") {
                Toggle("Copy to clipboard", isOn: $escCopy)
                Toggle("Save to folder", isOn: $escSave)
            }
            Section {
                Toggle("Launch at login", isOn: Binding(get: { launchAtLogin }, set: { launchAtLogin = $0; Pref.setLaunchAtLogin($0) }))
                Toggle("Pins stay on top of other windows", isOn: $pinsOnTop)
                Toggle("Keep a history of screenshots in the Library", isOn: $keepHistory)
                if keepHistory {
                    Picker("Delete library screenshots", selection: $retentionDays) {
                        Text("Never").tag(0)
                        Text("After 7 days").tag(7)
                        Text("After 30 days").tag(30)
                        Text("After 90 days").tag(90)
                    }
                }
                Toggle("Show Snapix in the Dock", isOn: $showDockIcon)
                    .onChange(of: showDockIcon) { _, _ in NSApp.setActivationPolicy(AppDelegate.restingPolicy) }
            }
        }
        .formStyle(.grouped)
    }

    private var saving: some View {
        Form {
            HStack {
                TextField("Folder", text: $saveFolder)
                Button("Choose…") {
                    let p = NSOpenPanel()
                    p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
                    if p.runModal() == .OK, let url = p.url { saveFolder = url.path }
                }
            }
            TextField("File name", text: $template)
            Text("Placeholders: {date} {time} {timestamp}").font(.caption).foregroundStyle(.secondary)
            Picker("Format", selection: $format) {
                Text("Automatic (PNG or JPEG by content)").tag("auto")
                Text("PNG").tag("png")
                Text("JPEG").tag("jpeg")
            }
            if format != "png" {
                HStack { Text("JPEG quality"); Slider(value: $quality, in: 0.3...1) }
            }
            Toggle("Downscale Retina screenshots to 1×", isOn: $downscale)
        }
        .formStyle(.grouped)
    }

    private var hotkeys: some View {
        Form {
            ForEach(Action.allCases, id: \.self) { a in
                HStack { Text(a.title); Spacer(); HotkeyRecorder(action: a).frame(width: 150) }
            }
        }
        .formStyle(.grouped)
    }

    private var tools: some View {
        Form {
            Picker("Color format", selection: $colorFormat) {
                ForEach(ColorFormat.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
            }
            Toggle("Snap shapes to edges in the screenshot (hold ⌥ to disable)", isOn: $snapEdges)
            Toggle("Mouse wheel zooms the image (trackpad scrolls, ⌥ or ⌘ swaps)", isOn: $wheelZoom)
            Toggle("Remove line breaks from recognized text", isOn: $removeBreaks)
            Toggle("Reverse direction for automatic scrolling capture", isOn: $reverseScroll)
            Text("Enable this if a third-party app reverses your scroll direction.").font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }

    private var backup: some View {
        Form {
            Section("Settings backup") {
                Button("Export Settings…", action: exportSettings)
                Button("Import Settings…", action: importSettings)
                Text("A backup holds your preferences, shortcuts and backdrop style. The upload authorization header is never exported.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func exportSettings() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.propertyList]
        panel.nameFieldStringValue = "Snapix Settings.plist"
        guard panel.runModal() == .OK, let url = panel.url, let data = Pref.backupData() else { return }
        do {
            try data.write(to: url)
            Toast.show(L("Settings exported"))
        } catch {
            Toast.show(LF("Capture failed: %@", error.localizedDescription), duration: 3)
        }
    }

    private func importSettings() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.propertyList]
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        guard Pref.restore(data) != nil else { Toast.show(L("This file is not a Snapix backup"), duration: 3); return }
        (NSApp.delegate as? AppDelegate)?.reloadHotkeys()
        Toast.show(L("Settings imported — reopen Preferences to see them"), duration: 3)
        PreferencesWindow.close()
    }

    private var upload: some View {
        Form {
            TextField("Endpoint URL", text: $uploadURL, prompt: Text("https://example.com/upload"))
            TextField("Form field name", text: $uploadField)
            SecureField("Authorization header (optional)", text: $uploadAuth)
            Text("Images are sent as multipart/form-data. The response (plain URL or JSON with a \"url\" key) is copied to the clipboard.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
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
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
