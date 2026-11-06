import AppKit
import SwiftUI

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
    @AppStorage("afterEdit") private var afterEdit = true
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
    @AppStorage("keepHistory") private var keepHistory = true
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
        }
        .frame(width: 520, height: 430)
        .padding(12)
    }

    private var general: some View {
        Form {
            Section("After taking a screenshot") {
                Toggle("Copy to clipboard", isOn: $afterCopy)
                Toggle("Save to folder", isOn: $afterSave)
                Toggle("Show in editor", isOn: $afterEdit)
                Toggle("Pin to screen", isOn: $afterPin)
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
            Toggle("Remove line breaks from recognized text", isOn: $removeBreaks)
            Toggle("Reverse direction for automatic scrolling capture", isOn: $reverseScroll)
            Text("Enable this if a third-party app reverses your scroll direction.").font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
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
