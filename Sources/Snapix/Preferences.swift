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
        case .general: return "gearshape"
        case .capture: return "viewfinder"
        case .recording: return "record.circle"
        case .editor: return "pencil.tip.crop.circle"
        case .shortcuts: return "keyboard"
        case .output: return "square.and.arrow.down"
        case .upload: return "icloud.and.arrow.up"
        case .backup: return "externaldrive"
        case .permissions: return "lock.shield"
        case .about: return "info.circle"
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
                Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.primary.opacity(0.45)).textCase(.uppercase).padding(.leading, 4)
            }
            VStack(spacing: 0) { content }
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.07)))
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
                    Text(title).font(.system(size: 13)).foregroundStyle(Color.primary.opacity(0.92))
                    if let subtitle {
                        Text(subtitle).font(.system(size: 11)).foregroundStyle(Color.primary.opacity(0.45)).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 12)
                control
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            if !last { Divider().overlay(Color.primary.opacity(0.06)).padding(.leading, 12) }
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
        Row(title: title, subtitle: subtitle, last: last) { Toggle("", isOn: $isOn).labelsHidden().toggleStyle(.switch).controlSize(.small).tint(Color(nsColor: Theme.accent)) }
    }
}

private struct Page<Content: View>: View {
    var pane: Pane
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 10) {
                    Image(systemName: pane.symbol).font(.system(size: 14, weight: .medium)).foregroundStyle(.white)
                        .frame(width: 28, height: 28).background(RoundedRectangle(cornerRadius: 7).fill(pane.tint.gradient))
                    Text(pane.title).font(.system(size: 20, weight: .bold)).foregroundStyle(.primary)
                }
                content
            }
            .padding(.horizontal, 24).padding(.top, 34).padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The app's icon, name and version at the foot of the sidebar.
private struct SidebarFooter: View {
    private var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "" }

    var body: some View {
        VStack(spacing: 0) {
            Divider().overlay(Color.primary.opacity(0.08)).padding(.horizontal, 2).padding(.bottom, 10)
            HStack(spacing: 9) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: "Snapix").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.primary.opacity(0.9))
                    Text(verbatim: "\(L("Version")) \(version)").font(.system(size: 11)).foregroundStyle(Color.primary.opacity(0.45))
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6).padding(.bottom, 12)
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
    @AppStorage("showMenuBarIcon") private var showMenuBarIcon = true
    @AppStorage("urlScheme") private var urlScheme = true
    @AppStorage("historyLimit") private var historyLimit = 200
    @AppStorage("appLanguage") private var appLanguage = "system"
    @State private var historyBytes = History.totalBytes()
    @State private var historyCount = History.items().count
    @AppStorage("previewAnimation") private var previewAnimation = "slide"
    @AppStorage("previewSwipe") private var previewSwipe = true
    @AppStorage("previewSwipeLeft") private var swipeLeft = "dismiss"
    @AppStorage("previewSwipeRight") private var swipeRight = "dismiss"
    @AppStorage("quickAccessSounds") private var quickAccessSounds = false
    @AppStorage("libraryFilter") private var libraryFilter = "all"
    @AppStorage("ocrDetectLinks") private var ocrDetectLinks = false
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
    @AppStorage("recordClicks") private var recordClicks = false
    @AppStorage("recordCamera") private var recordCamera = false
    @AppStorage("cameraShape") private var cameraShape = "circle"
    @AppStorage("cameraSize") private var cameraSize = "medium"
    @AppStorage("cameraCorner") private var cameraCorner = "bottomRight"
    @AppStorage("cameraMirror") private var cameraMirror = true
    @AppStorage("clickColor") private var clickColor = 0x5B8CFF
    @AppStorage("clickSize") private var clickSize = 54.0
    @AppStorage("clickDuration") private var clickDuration = 0.55
    @AppStorage("overlayDim") private var overlayDim = 0.4
    @AppStorage("showLoupe") private var showLoupe = true
    @AppStorage("loupeSize") private var loupeSize = "medium"
    @AppStorage("recordKeystrokes") private var recordKeystrokes = false
    @AppStorage("recordingTemplate") private var recordingTemplate = ""
    @AppStorage("recordFPS") private var recordFPS = 30
    @AppStorage("recordQuality") private var recordQuality = "medium"
    @AppStorage("recordMaxSize") private var recordMaxSize = "native"
    @AppStorage("screenshotCursor") private var screenshotCursor = false
    @AppStorage("watermarkEnabled") private var watermarkEnabled = false
    @AppStorage("watermarkText") private var watermarkText = ""
    @AppStorage("watermarkPosition") private var watermarkPosition = "bottomRight"
    @AppStorage("watermarkOpacity") private var watermarkOpacity = 0.6
    @AppStorage("watermarkSize") private var watermarkSize = 4.0
    @AppStorage("confirmClose") private var confirmClose = true
    @AppStorage("windowShadow") private var windowShadow = false
    @AppStorage("defaultTool") private var defaultTool = "arrow"
    @AppStorage("rememberTool") private var rememberTool = false
    @AppStorage("snapHighlight") private var snapHighlight = true
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("configAutoApply") private var configAutoApply = false
    @AppStorage("loupeZoom") private var loupeZoom = "medium"
    @AppStorage("closeAfterDrag") private var closeAfterDrag = false
    @AppStorage("quickAccessHideOpened") private var quickAccessHideOpened = false
    @AppStorage("clipboardImage") private var clipboardImage = "never"
    @AppStorage("confirmationStyle") private var confirmationStyle = "bubble"
    @AppStorage("diagnosticLogs") private var diagnosticLogs = true
    @AppStorage("logDays") private var logDays = 7
    @AppStorage("updateChannel") private var updateChannel = "stable"
    @AppStorage("updateCheckAtLaunch") private var updateCheckAtLaunch = false
    @AppStorage("menuBarTimer") private var menuBarTimer = true
    @AppStorage("micDeviceID") private var micDeviceID = ""
    @AppStorage("cameraDeviceID") private var cameraDeviceID = ""
    @AppStorage("clickRings") private var clickRings = 1
    @AppStorage("clickOpacity") private var clickOpacity = 1.0
    @AppStorage("keyPillSize") private var keyPillSize = 20.0
    @AppStorage("keyPillPosition") private var keyPillPosition = "bottom"
    @AppStorage("keyPillSeconds") private var keyPillSeconds = 1.6
    @AppStorage("defaultZoom") private var defaultZoom = "fit"
    @AppStorage("scrollSpeed") private var scrollSpeed = "normal"
    @AppStorage("libraryIndexFolder") private var libraryIndexFolder = true
    @AppStorage("windowBackground") private var windowBackground = "transparent"
    @AppStorage("windowBackgroundColor") private var windowBackgroundColor = 0x1B1B1E
    @AppStorage("quickActions") private var quickActions = "edit,copy,save,ocr,pin"
    @AppStorage("quickAccessStyle") private var quickAccessStyle = "stack"
    @AppStorage("ocrEngine") private var ocrEngine = "builtin"
    @AppStorage("ocrEndpoint") private var ocrEndpoint = ""
    @AppStorage("ocrModel") private var ocrModel = ""
    @AppStorage("ocrPrompt") private var ocrPrompt = ""
    @AppStorage("ocrAPIKey") private var ocrAPIKey = ""
    @State private var ocrTestResult = ""
    @AppStorage("freezeScreen") private var freezeScreen = true
    @AppStorage("colorPanel") private var colorPanel = true
    @AppStorage("colorCopyOnPick") private var colorCopyOnPick = true
    @AppStorage("scrollMaxHeight") private var scrollMaxHeight = 20000
    @AppStorage("toolStyleMemory") private var toolStyleMemory = true
    @AppStorage("recordMicrophone") private var recordMicrophone = false
    @AppStorage("recordReveal") private var recordReveal = false
    @AppStorage("recordCountdown") private var recordCountdown = 3
    @AppStorage("recordReview") private var recordReview = true
    @AppStorage("uploadURL") private var uploadURL = ""
    @AppStorage("uploadField") private var uploadField = "file"
    @AppStorage("uploadAuthHeader") private var uploadAuth = ""
    @AppStorage("uploadService") private var uploadService = "http"
    @AppStorage("s3Endpoint") private var s3Endpoint = ""
    @AppStorage("s3Region") private var s3Region = ""
    @AppStorage("s3Bucket") private var s3Bucket = ""
    @AppStorage("s3AccessKey") private var s3AccessKey = ""
    @AppStorage("s3Prefix") private var s3Prefix = ""
    @AppStorage("s3PublicBase") private var s3PublicBase = ""
    @AppStorage("s3LinkMode") private var s3LinkMode = "none"
    @AppStorage("s3ExpiryDays") private var s3ExpiryDays = 7
    @State private var s3Secret = Keychain.get("s3SecretKey") ?? ""
    @State private var s3TestResult = ""
    @State private var uploads = UploadLog.all()
    @State private var launchAtLogin = Pref.launchAtLogin
    @State private var pane = Pane.general
    @State private var shortcutsVersion = 0
    @State private var permissionsVersion = 0

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider().overlay(Color.primary.opacity(0.08))
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
        .background(Color(nsColor: Theme.adaptiveWindow))
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Pane.allCases) { p in
                Button { pane = p } label: {
                    HStack(spacing: 9) {
                        Image(systemName: p.symbol).font(.system(size: 11, weight: .medium)).foregroundStyle(.white)
                            .frame(width: 22, height: 22).background(RoundedRectangle(cornerRadius: 6).fill(p.tint.gradient))
                        Text(p.title).font(.system(size: 13)).foregroundStyle(Color.primary.opacity(pane == p ? 1 : 0.8))
                        Spacer()
                    }
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(pane == p ? 0.12 : 0)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if p == .recording || p == .upload { Spacer().frame(height: 8) }
            }
            Spacer()
            SidebarFooter()
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
                        Text("Center top").tag("centerTop"); Text("Center bottom").tag("centerBottom")
                    }.labelsHidden().frame(width: 160)
                }
                Row(title: "Animation") {
                    Picker("", selection: $previewAnimation) { Text("Slide").tag("slide"); Text("Fade").tag("fade") }.labelsHidden().frame(width: 160)
                }
                ToggleRow("Swipe actions", "Swipe horizontally with two fingers on a preview to run an action.", isOn: $previewSwipe, last: !previewSwipe)
                if previewSwipe {
                    Row(title: "Swipe left") { swipePicker($swipeLeft) }
                    Row(title: "Swipe right") { swipePicker($swipeRight) }
                }
                ToggleRow("Sound effects", "A soft sound when a preview appears and when it copies or saves.", isOn: $quickAccessSounds)
                Row(title: "Recall shortcut shows", subtitle: "The stack keeps your last captures on screen; the strip is a scrollable row of recent screenshots and recordings.") {
                    Picker("", selection: $quickAccessStyle) { Text("A stack").tag("stack"); Text("A strip").tag("strip") }.labelsHidden().frame(width: 160)
                }
                ToggleRow("Hide a card while its editor is open", "The card comes back when you close the editor.", isOn: $quickAccessHideOpened)
                Row(title: "Size", last: true) {
                    Picker("", selection: $previewSize) {
                        Text("Small").tag("small"); Text("Medium").tag("medium"); Text("Large").tag("large")
                    }.labelsHidden().frame(width: 160)
                }
            }
            Card(title: "Quick Access buttons") {
                ForEach(Array(QuickAction.allCases.enumerated()), id: \.element) { i, a in
                    ToggleRow(LocalizedStringKey(a.title), isOn: Binding(
                        get: { QuickAction.parse(quickActions).contains(a) && quickActions.contains(a.rawValue) },
                        set: { on in
                            var list = QuickAction.parse(quickActions)
                            if on { if !list.contains(a) { list.append(a) } } else { list.removeAll { $0 == a } }
                            quickActions = list.isEmpty ? QuickAction.serialize([a]) : QuickAction.serialize(list)
                        }), last: i == QuickAction.allCases.count - 1)
                }
            }
            Text("Hover a preview and press ⌘C to copy, ⌘S to save, ⌘E or Return to edit, ⌘P to pin, Delete to remove it, Esc to close.")
                .font(.system(size: 11)).foregroundStyle(Color.primary.opacity(0.45))
            Card(title: "When closing the editor with Esc") {
                ToggleRow("Copy to clipboard", isOn: $escCopy)
                ToggleRow("Save to folder", isOn: $escSave, last: true)
            }
            Card(title: "Startup") {
                ToggleRow("Launch at login", isOn: Binding(get: { launchAtLogin }, set: { launchAtLogin = $0; Pref.setLaunchAtLogin($0) }))
                ToggleRow("Show the home window at launch", isOn: Binding(get: { !hideHome }, set: { hideHome = !$0 }))
                ToggleRow("Show the menu bar icon", "When hidden, Snapix stays reachable from the Dock.", isOn: $showMenuBarIcon)
                    .onChange(of: showMenuBarIcon) { _, _ in (NSApp.delegate as? AppDelegate)?.applyMenuBarVisibility() }
                ToggleRow("Show Snapix in the Dock", isOn: $showDockIcon, last: true)
                    .onChange(of: showDockIcon) { _, _ in NSApp.setActivationPolicy(AppDelegate.restingPolicy) }
            }
            Card(title: "Appearance") {
                Row(title: "Theme", subtitle: "The editor window stays dark, like most image tools.", last: true) {
                    Picker("", selection: $appearance) { Text("System").tag("system"); Text("Light").tag("light"); Text("Dark").tag("dark") }
                        .labelsHidden().frame(width: 140).onChange(of: appearance) { _, _ in Pref.applyAppearance() }
                }
            }
            Card(title: "Confirmations") {
                Row(title: "Confirmation style", subtitle: "How Snapix tells you a copy, a save or a problem.", last: true) {
                    Picker("", selection: $confirmationStyle) { Text("On-screen bubble").tag("bubble"); Text("System notification").tag("system"); Text("Both").tag("both") }
                        .labelsHidden().frame(width: 180)
                }
            }
            Card(title: "Language and integration") {
                Row(title: "Language", subtitle: "Applies after Snapix restarts.") {
                    Picker("", selection: $appLanguage) { Text("System default").tag("system"); Text("English").tag("en"); Text("Français").tag("fr") }
                        .labelsHidden().frame(width: 160)
                        .onChange(of: appLanguage) { _, new in
                            Pref.setLanguage(new)
                            let alert = NSAlert()
                            alert.messageText = L("Relaunch Snapix?")
                            alert.informativeText = L("The language changes after Snapix restarts.")
                            alert.addButton(withTitle: L("Relaunch"))
                            alert.addButton(withTitle: L("Later"))
                            if alert.runModal() == .alertFirstButtonReturn { Pref.relaunch() }
                        }
                }
                ToggleRow("Allow snapix:// links", "Lets other apps and scripts start captures with snapix:// URLs.", isOn: $urlScheme, last: true)
            }
        }
    }

    private func swipePicker(_ binding: Binding<String>) -> some View {
        Picker("", selection: binding) {
            Text("Dismiss").tag("dismiss"); Text("Copy").tag("copy"); Text("Save").tag("save")
            Text("Open in Editor").tag("edit"); Text("Pin to screen").tag("pin"); Text("Do nothing").tag("none")
        }.labelsHidden().frame(width: 160)
    }

    private var capture: some View {
        Page(pane: .capture) {
            Card(title: "Screenshots") {
                ToggleRow("Play a sound when a screenshot is taken", isOn: $captureSound)
                ToggleRow("Include the mouse pointer in screenshots", isOn: $screenshotCursor)
                ToggleRow("Include the window shadow when capturing a window", isOn: $windowShadow)
                Row(title: "Window screenshot background", subtitle: "What sits behind a captured window.", last: false) {
                    Picker("", selection: $windowBackground) { Text("Transparent").tag("transparent"); Text("Desktop picture").tag("wallpaper"); Text("Solid color").tag("solid") }
                        .labelsHidden().frame(width: 160)
                }
                if windowBackground != "transparent" {
                    Row(title: "Background color", subtitle: "Used for the solid color, and behind a transparent desktop picture.") {
                        ColorPicker("", selection: Binding(get: { Color(nsColor: NSColor(hex: UInt32(truncatingIfNeeded: windowBackgroundColor))) },
                                                           set: { windowBackgroundColor = Int(NSColor($0).hexValue) })).labelsHidden()
                    }
                }
                ToggleRow("Hide desktop icons", "Files on the desktop stay out of screenshots and recordings.", isOn: $hideDesktopIcons)
                Row(title: "Delayed screenshot timer", last: true) {
                    Picker("", selection: $captureDelay) { ForEach([3, 5, 10, 15], id: \.self) { Text("\($0) s").tag($0) } }.labelsHidden().frame(width: 100)
                }
            }
            Card(title: "Color picker") {
                ToggleRow("Copy the color when picked", isOn: $colorCopyOnPick)
                ToggleRow("Show the color panel", "A card lists the color in every format and keeps the recent ones.", isOn: $colorPanel, last: true)
            }
            Card(title: "Scrolling capture") {
                Row(title: "Scrolling speed", subtitle: "Slower speeds wait longer after each step; use them for pages that load as you scroll.") {
                    Picker("", selection: $scrollSpeed) { Text("Fast").tag("fast"); Text("Normal").tag("normal"); Text("Slow").tag("slow"); Text("Very slow").tag("verySlow") }
                        .labelsHidden().frame(width: 140)
                }
                Row(title: "Maximum height", subtitle: "Taller pages stop at this height, in pixels.", last: true) {
                    Picker("", selection: $scrollMaxHeight) { Text("10 000").tag(10000); Text("20 000").tag(20000); Text("40 000").tag(40000); Text("60 000").tag(60000) }
                        .labelsHidden().frame(width: 120)
                }
            }
            Card(title: "Selection overlay") {
                Row(title: "Dim outside the selection") { Slider(value: $overlayDim, in: 0...0.8).frame(width: 180) }
                ToggleRow("Show the pixel magnifier", isOn: $showLoupe, last: !showLoupe)
                if showLoupe {
                    Row(title: "Magnifier zoom") {
                        Picker("", selection: $loupeZoom) { Text("Low").tag("low"); Text("Medium").tag("medium"); Text("High").tag("high") }.labelsHidden().frame(width: 140)
                    }
                    Row(title: "Magnifier size", last: true) {
                        Picker("", selection: $loupeSize) { Text("Small").tag("small"); Text("Medium").tag("medium"); Text("Large").tag("large") }.labelsHidden().frame(width: 140)
                    }
                }
            }
            Card(title: "Area selection") {
                ToggleRow("Freeze the screen while selecting", "Turn off to keep videos and animations moving under the overlay; the picture is then taken after you choose the area (no magnifier).", isOn: $freezeScreen)
                ToggleRow("Adjust the selection before capturing",
                          "Drag handles to resize, drag inside (or hold Space while dragging) to move, Return or double-click to capture.", isOn: $areaAdjust)
                ToggleRow("Reverse direction for automatic scrolling capture", "Enable this if a third-party app reverses your scroll direction.", isOn: $reverseScroll, last: true)
            }
            Card(title: "Library") {
                ToggleRow("Keep a history of screenshots in the Library", isOn: $keepHistory, last: !keepHistory)
                if keepHistory {
                    ToggleRow("Also list the files of the screenshots folder", "Pictures and videos you saved appear in the Library too. Deleting one moves it to the Trash.", isOn: $libraryIndexFolder)
                Row(title: "Library opens on") {
                    Picker("", selection: $libraryFilter) { ForEach(LibraryFilter.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) } }.labelsHidden().frame(width: 140)
                }
                Row(title: "Maximum number of screenshots") {
                        Picker("", selection: $historyLimit) {
                            Text("50").tag(50); Text("100").tag(100); Text("200").tag(200); Text("500").tag(500); Text("No limit").tag(-1)
                        }.labelsHidden().frame(width: 120)
                    }
                    Row(title: "Delete library screenshots") {
                        Picker("", selection: $retentionDays) {
                            Text("Never").tag(0); Text("After 7 days").tag(7); Text("After 30 days").tag(30); Text("After 90 days").tag(90)
                        }.labelsHidden().frame(width: 140)
                    }
                }
                Row(title: "Storage", subtitle: LocalizedStringKey(LF("%d screenshots, %@", historyCount, ByteCountFormatter.string(fromByteCount: Int64(historyBytes), countStyle: .file))), last: true) {
                    HStack {
                        Button("Open Folder") { NSWorkspace.shared.open(History.folder) }
                        Button("Clear History…", role: .destructive) {
                            let alert = NSAlert()
                            alert.messageText = L("Clear the whole Library?")
                            alert.informativeText = L("Every screenshot kept in the Library is deleted. Files you saved are not touched.")
                            alert.alertStyle = .warning
                            alert.addButton(withTitle: L("Clear"))
                            alert.addButton(withTitle: L("Cancel"))
                            if alert.runModal() == .alertFirstButtonReturn { History.clear(); historyBytes = 0; historyCount = 0 }
                        }
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
                Row(title: "Frame rate") {
                    Picker("", selection: $recordFPS) { Text("15").tag(15); Text("30").tag(30); Text("60").tag(60) }.labelsHidden().frame(width: 100)
                }
                Row(title: "Quality", subtitle: "Higher quality means a larger file.") {
                    Picker("", selection: $recordQuality) { Text("Low").tag("low"); Text("Medium").tag("medium"); Text("High").tag("high") }.labelsHidden().frame(width: 100)
                }
                Row(title: "Maximum resolution") {
                    Picker("", selection: $recordMaxSize) { Text("Native").tag("native"); Text("1080p").tag("1080"); Text("720p").tag("720") }.labelsHidden().frame(width: 100)
                }
                ToggleRow("Record the mouse cursor", isOn: $recordCursor)
                ToggleRow("Highlight mouse clicks", "A ring appears at each click.", isOn: $recordClicks, last: false)
                if recordClicks {
                    Row(title: "Ring color") {
                        ColorPicker("", selection: Binding(get: { Color(nsColor: NSColor(hex: UInt32(truncatingIfNeeded: clickColor))) },
                                                           set: { clickColor = Int(NSColor($0).hexValue) })).labelsHidden()
                    }
                    Row(title: "Ring size") { Slider(value: $clickSize, in: 24...120).frame(width: 180) }
                    Row(title: "Ring duration") { Slider(value: $clickDuration, in: 0.2...1.5).frame(width: 180) }
                    Row(title: "Number of rings") { Picker("", selection: $clickRings) { ForEach(1...4, id: \.self) { Text("\($0)").tag($0) } }.labelsHidden().frame(width: 80) }
                    Row(title: "Ring opacity") { Slider(value: $clickOpacity, in: 0.2...1).frame(width: 180) }
                }
                ToggleRow("Show keystrokes", "Typed keys and shortcuts appear in a pill. Needs the Accessibility permission.", isOn: $recordKeystrokes, last: !recordKeystrokes)
                if recordKeystrokes {
                    Row(title: "Keystroke text size") { Slider(value: $keyPillSize, in: 12...40).frame(width: 180) }
                    Row(title: "Keystroke position") { Picker("", selection: $keyPillPosition) { Text("Top").tag("top"); Text("Center").tag("center"); Text("Bottom").tag("bottom") }.labelsHidden().frame(width: 120) }
                    Row(title: "Keystroke display time", last: false) { Slider(value: $keyPillSeconds, in: 0.5...5).frame(width: 180) }
                }
                ToggleRow("Record system audio (MP4 only)", isOn: $recordAudio)
                ToggleRow("Record the microphone (macOS 15 or later)", "The voice is a separate audio track; players that show a track picker let you choose it.", isOn: $recordMicrophone, last: !recordMicrophone)
                if recordMicrophone {
                    Row(title: "Microphone") {
                        Picker("", selection: $micDeviceID) {
                            Text("System default").tag("")
                            ForEach(InputDevices.microphones(), id: \.id) { Text($0.name).tag($0.id) }
                        }.labelsHidden().frame(width: 220)
                    }
                }
                ToggleRow("Show the elapsed time in the menu bar", "The timer sits next to the Snapix icon while you record.", isOn: $menuBarTimer)
                ToggleRow("Review and trim before saving", "Opens the recording in a player where you can cut the start and the end.", isOn: $recordReview)
                ToggleRow("Show the file in Finder when done", isOn: $recordReveal, last: true)
            }
            Card(title: "Camera") {
                ToggleRow("Show the camera in the recording", "A floating bubble you can drag while recording.", isOn: $recordCamera, last: !recordCamera)
                if recordCamera {
                    Row(title: "Camera") {
                        Picker("", selection: $cameraDeviceID) {
                            Text("System default").tag("")
                            ForEach(InputDevices.cameras(), id: \.id) { Text($0.name).tag($0.id) }
                        }.labelsHidden().frame(width: 220)
                    }
                    Row(title: "Shape") { Picker("", selection: $cameraShape) { Text("Circle").tag("circle"); Text("Square").tag("square") }.labelsHidden().frame(width: 140) }
                    Row(title: "Size") { Picker("", selection: $cameraSize) { Text("Small").tag("small"); Text("Medium").tag("medium"); Text("Large").tag("large") }.labelsHidden().frame(width: 140) }
                    Row(title: "Position") {
                        Picker("", selection: $cameraCorner) {
                            Text("Bottom right").tag("bottomRight"); Text("Bottom left").tag("bottomLeft"); Text("Top right").tag("topRight"); Text("Top left").tag("topLeft")
                        }.labelsHidden().frame(width: 140)
                    }
                    ToggleRow("Mirror the camera", isOn: $cameraMirror, last: true)
                }
            }
            Text("Press the shortcut again, or click Stop, to end a recording. The file is saved in your screenshots folder and copied to the clipboard.")
                .font(.system(size: 11)).foregroundStyle(Color.primary.opacity(0.45))
        }
    }

    private var editor: some View {
        Page(pane: .editor) {
            Card(title: "Editing") {
                Row(title: "Color format") {
                    Picker("", selection: $colorFormat) { ForEach(ColorFormat.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) } }.labelsHidden().frame(width: 140)
                }
                Row(title: "Default zoom", subtitle: "How large the image is when the editor opens.") {
                    Picker("", selection: $defaultZoom) {
                        Text("Fit to window").tag("fit"); Text("Actual size").tag("actual"); Text("50 %").tag("50"); Text("200 %").tag("200"); Text("300 %").tag("300")
                    }.labelsHidden().frame(width: 160)
                }
                Row(title: "Default tool") {
                    Picker("", selection: $defaultTool) { ForEach(Tool.allCases.filter { $0 != .overlay && $0 != .crop }, id: \.rawValue) { Text($0.title).tag($0.rawValue) } }
                        .labelsHidden().frame(width: 180)
                }
                ToggleRow("Ask before closing an edited image", "Offers to save when you close the editor window with unsaved changes.", isOn: $confirmClose)
                ToggleRow("Remember each tool's style", "Every tool comes back with the colour, thickness and options you last gave it.", isOn: $toolStyleMemory)
                ToggleRow("Snap highlights to text", "A highlighter stroke over text becomes a clean band on that line. Undo restores the stroke.", isOn: $snapHighlight)
                ToggleRow("Remember the last tool", "Open the editor with the tool you used last instead of the default one.", isOn: $rememberTool)
                ToggleRow("Snap shapes to edges in the screenshot (hold ⌥ to disable)", isOn: $snapEdges)
                ToggleRow("Mouse wheel zooms the image (trackpad scrolls, ⌥ or ⌘ swaps)", isOn: $wheelZoom)
                ToggleRow("Open the editor in a larger window", isOn: $largerWindow)
                ToggleRow("Keep the editor above other windows", isOn: $editorOnTop)
                ToggleRow("Close the editor after dragging the image out", "Once another app accepted the dropped image.", isOn: $closeAfterDrag)
                Row(title: "Image in the clipboard", subtitle: "What to do with a picture in the clipboard when the home window opens.", last: true) {
                    Picker("", selection: $clipboardImage) { Text("Ignore").tag("never"); Text("Ask").tag("ask"); Text("Open it").tag("load") }.labelsHidden().frame(width: 120)
                }
            }
            Card(title: "Text recognition") {
                ToggleRow("Remove line breaks from recognized text", isOn: $removeBreaks)
                ToggleRow("Offer to open links found in the text", isOn: $ocrDetectLinks)
                Row(title: "Recognition language", last: true) {
                    Picker("", selection: $ocrLanguage) {
                        Text("Automatic").tag("auto")
                        ForEach(OCR.supportedLanguages, id: \.self) { code in
                            Text(Locale.current.localizedString(forIdentifier: code) ?? code).tag(code)
                        }
                    }.labelsHidden().frame(width: 200)
                }
            }
            Card(title: "Recognition engine") {
                Row(title: "Engine", subtitle: "Built-in recognition runs on this Mac. A custom server receives the captured image.", last: ocrEngine != "custom") {
                    Picker("", selection: $ocrEngine) { Text("Built-in (Apple Vision)").tag("builtin"); Text("Custom server").tag("custom") }.labelsHidden().frame(width: 200)
                }
                if ocrEngine == "custom" {
                    Row(title: "Server address") { TextField("https://api.example.com/v1", text: $ocrEndpoint).textFieldStyle(.roundedBorder).frame(width: 260) }
                    Row(title: "Model") { TextField("model name", text: $ocrModel).textFieldStyle(.roundedBorder).frame(width: 260) }
                    Row(title: "Prompt (optional)") { TextField(RemoteOCR.defaultPrompt, text: $ocrPrompt).textFieldStyle(.roundedBorder).frame(width: 260) }
                    Row(title: "API key (optional)") { SecureField("", text: $ocrAPIKey).textFieldStyle(.roundedBorder).frame(width: 260) }
                    Row(title: "Connection", subtitle: LocalizedStringKey(ocrTestResult), last: true) {
                        Button("Test") {
                            ocrTestResult = L("Testing…")
                            Task {
                                do { ocrTestResult = LF("Connected (%d ms)", try await RemoteOCR.test()) }
                                catch { ocrTestResult = RemoteOCR.describe(error) }
                            }
                        }
                    }
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
                .font(.system(size: 11)).foregroundStyle(Color.primary.opacity(0.45))
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
                Row(title: "File name", subtitle: "Placeholders: {date} {time} {timestamp} {app}") {
                    TextField("", text: $template).textFieldStyle(.roundedBorder).frame(width: 220)
                }
                Row(title: "Recording file name") {
                    TextField("", text: $recordingTemplate).textFieldStyle(.roundedBorder).frame(width: 220)
                }
                Row(title: "Reset file names", last: true) {
                    Button("Reset Names") { template = "Snapix {date} at {time}"; recordingTemplate = "Snapix Recording {date} at {time}" }
                }
            }
            Card(title: "Format") {
                Row(title: "Format") {
                    Picker("", selection: $format) {
                        Text("Automatic (PNG or JPEG by content)").tag("auto"); Text("PNG").tag("png"); Text("JPEG").tag("jpeg"); Text("HEIC").tag("heic")
                    }.labelsHidden().frame(width: 240)
                }
                if format != "png" {
                    Row(title: "JPEG quality") { Slider(value: $quality, in: 0.3...1).frame(width: 180) }
                }
                ToggleRow("Downscale Retina screenshots to 1×", isOn: $downscale, last: true)
            }
            Card(title: "Watermark") {
                ToggleRow("Add a watermark to exported images", "Applied when you copy, save, upload, share or drag an image out of Snapix.", isOn: $watermarkEnabled, last: !watermarkEnabled)
                if watermarkEnabled {
                    Row(title: "Text") { TextField("© your name", text: $watermarkText).textFieldStyle(.roundedBorder).frame(width: 220) }
                    Row(title: "Position") {
                        Picker("", selection: $watermarkPosition) {
                            Text("Bottom right").tag("bottomRight"); Text("Bottom left").tag("bottomLeft"); Text("Top right").tag("topRight")
                            Text("Top left").tag("topLeft"); Text("Center").tag("center")
                        }.labelsHidden().frame(width: 160)
                    }
                    Row(title: "Size") { Slider(value: $watermarkSize, in: 1.5...10).frame(width: 180) }
                    Row(title: "Opacity", last: true) { Slider(value: $watermarkOpacity, in: 0.1...1).frame(width: 180) }
                }
            }
            Card(title: "Pins") {
                ToggleRow("Pins stay on top of other windows", isOn: $pinsOnTop, last: true)
            }
        }
    }

    private var upload: some View {
        Page(pane: .upload) {
            Card(title: "Service") {
                Row(title: "Upload to", last: true) {
                    Picker("", selection: $uploadService) { Text("HTTP endpoint").tag("http"); Text("S3-compatible storage").tag("s3") }.labelsHidden().frame(width: 220)
                }
            }
            if uploadService == "s3" {
                Card(title: "S3-compatible storage") {
                    Row(title: "Endpoint", subtitle: "Leave empty for Amazon S3. Example: https://<account>.r2.cloudflarestorage.com") {
                        TextField("", text: $s3Endpoint).textFieldStyle(.roundedBorder).frame(width: 260)
                    }
                    Row(title: "Region", subtitle: "Required for Amazon S3; use \"auto\" or leave empty for most others.") { TextField("us-east-1", text: $s3Region).textFieldStyle(.roundedBorder).frame(width: 260) }
                    Row(title: "Bucket") { TextField("", text: $s3Bucket).textFieldStyle(.roundedBorder).frame(width: 260) }
                    Row(title: "Access key") { TextField("", text: $s3AccessKey).textFieldStyle(.roundedBorder).frame(width: 260) }
                    Row(title: "Secret key", subtitle: "Stored in the macOS Keychain.") {
                        SecureField("", text: $s3Secret).textFieldStyle(.roundedBorder).frame(width: 260).onChange(of: s3Secret) { _, v in Keychain.set(v, for: "s3SecretKey") }
                    }
                    Row(title: "Key prefix (path)") { TextField("screenshots", text: $s3Prefix).textFieldStyle(.roundedBorder).frame(width: 260) }
                    Row(title: "Connection", subtitle: LocalizedStringKey(s3TestResult), last: true) {
                        Button("Test Connection") { s3TestResult = L("Testing…"); Task { s3TestResult = await S3Uploader.test() } }
                    }
                }
                Card(title: "Link sharing") {
                    Row(title: "Link to copy", last: s3LinkMode == "none") {
                        Picker("", selection: $s3LinkMode) { Text("No link").tag("none"); Text("Presigned URL").tag("presigned"); Text("Public bucket URL").tag("public") }.labelsHidden().frame(width: 200)
                    }
                    if s3LinkMode == "presigned" {
                        Row(title: "Link expiration", subtitle: "Presigned URLs are valid for up to 7 days.", last: true) {
                            Picker("", selection: $s3ExpiryDays) { ForEach(1...7, id: \.self) { Text(LF("%d day(s)", $0)).tag($0) } }.labelsHidden().frame(width: 120)
                        }
                    }
                    if s3LinkMode == "public" {
                        Row(title: "Public bucket URL", subtitle: "Only works if the bucket is public.", last: true) { TextField("https://cdn.example.com", text: $s3PublicBase).textFieldStyle(.roundedBorder).frame(width: 260) }
                    }
                }
                Card(title: "Past uploads") {
                    if uploads.isEmpty {
                        Row(title: "Nothing uploaded yet", last: true) { EmptyView() }
                    } else {
                        ForEach(Array(uploads.prefix(10).enumerated()), id: \.element.key) { i, u in
                            Row(title: LocalizedStringKey(u.name), subtitle: LocalizedStringKey(u.date.formatted(date: .abbreviated, time: .shortened)), last: i == min(10, uploads.count) - 1) {
                                HStack {
                                    if let link = u.link {
                                        Button("Copy link") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(link, forType: .string); Toast.show(L("Link copied"), symbol: "checkmark.circle.fill") }
                                    }
                                }
                            }
                        }
                    }
                }
                HStack {
                    Button("Refresh") { uploads = UploadLog.all() }
                    Button("Clear List", role: .destructive) { UploadLog.clear(); uploads = [] }.disabled(uploads.isEmpty)
                }
            } else {
                Card(title: "Endpoint") {
                    Row(title: "Endpoint URL") { TextField("https://example.com/upload", text: $uploadURL).textFieldStyle(.roundedBorder).frame(width: 260) }
                    Row(title: "Form field name") { TextField("", text: $uploadField).textFieldStyle(.roundedBorder).frame(width: 260) }
                    Row(title: "Authorization header (optional)", last: true) { SecureField("", text: $uploadAuth).textFieldStyle(.roundedBorder).frame(width: 260) }
                }
                Text("Images are sent as multipart/form-data. The response (plain URL or JSON with a \"url\" key) is copied to the clipboard.")
                    .font(.system(size: 11)).foregroundStyle(Color.primary.opacity(0.45))
            }
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
            Card(title: "config.toml") {
                Row(title: "Settings file", subtitle: LocalizedStringKey(TomlConfig.defaultURL.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))) {
                    HStack {
                        Button("Write") { Toast.show(Pref.writeConfigFile() ? L("config.toml written") : L("Could not write config.toml"), symbol: "checkmark.circle.fill") }
                        Button("Open") { Pref.writeConfigFile(); NSWorkspace.shared.open(TomlConfig.defaultURL) }
                    }
                }
                Row(title: "Apply config.toml", subtitle: "Reads the file back. Restart Snapix or reopen Preferences to see every change.") {
                    Button("Apply") {
                        if let n = Pref.applyConfigFile() { (NSApp.delegate as? AppDelegate)?.reloadHotkeys(); Toast.show(LF("%d setting(s) changed", n), symbol: "checkmark.circle.fill"); PreferencesWindow.close() }
                        else { Toast.show(L("No config.toml found, or nothing usable in it"), symbol: "exclamationmark.triangle.fill") }
                    }
                }
                ToggleRow("Apply config.toml at launch", "Handy to keep several Macs in step with a synced dotfiles folder.", isOn: $configAutoApply, last: true)
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
                    Text("Snapix").font(.system(size: 22, weight: .bold)).foregroundStyle(.primary)
                    Text(Self.versionString).font(.system(size: 12)).foregroundStyle(Color.primary.opacity(0.5))
                    Text("Capture, annotate, polish, read text. Everything stays on your Mac.").font(.system(size: 12)).foregroundStyle(Color.primary.opacity(0.6))
                }
            }
            Card {
                Row(title: "Source code and releases") {
                    HStack {
                        Button("GitHub") { NSWorkspace.shared.open(URL(string: "https://github.com/Arrows78/Snapix")!) }
                        Button("Releases") { NSWorkspace.shared.open(URL(string: "https://github.com/Arrows78/Snapix/releases")!) }
                    }
                }
                Row(title: "Update channel", subtitle: "Beta also offers pre-releases.") {
                    Picker("", selection: $updateChannel) { Text("Stable").tag("stable"); Text("Beta").tag("beta") }.labelsHidden().frame(width: 120)
                }
                ToggleRow("Check for updates at launch", "Asks GitHub once a day. Off by default: Snapix never contacts anyone unless you ask.", isOn: $updateCheckAtLaunch)
                Row(title: "Updates", subtitle: "Asks GitHub for the latest release when you click.") {
                    HStack {
                        Button("Check for Updates…") { UpdateCheck.run() }
                        Button("Welcome Tour") { Onboarding.show() }
                    }
                }
                Row(title: "Diagnostics", subtitle: "Copies the version, macOS version and permissions, to paste into a bug report. It contains no personal data.", last: false) {
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(Self.diagnostics, forType: .string)
                        Toast.show(L("Copied to the clipboard"), symbol: "checkmark.circle.fill")
                ToggleRow("Keep diagnostic logs", "One small log file per day, stored only on this Mac.", isOn: $diagnosticLogs)
                Row(title: "Keep logs for") {
                    Picker("", selection: $logDays) { Text("3 days").tag(3); Text("7 days").tag(7); Text("30 days").tag(30) }.labelsHidden().frame(width: 120)
                }
                Row(title: "Logs", last: false) {
                    HStack {
                        Button("Open Folder") { try? FileManager.default.createDirectory(at: DiagnosticLog.folder, withIntermediateDirectories: true); NSWorkspace.shared.open(DiagnosticLog.folder) }
                        Button("Clear", role: .destructive) { DiagnosticLog.clear() }
                    }
                }
                Row(title: "Report a problem", subtitle: "Opens a prefilled GitHub issue with the version, macOS and the last log lines. Review it before sending.", last: true) {
                    Button("Report…") { ProblemReport.open() }
                }
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
            w.backgroundColor = Theme.adaptiveWindow
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
