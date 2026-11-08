import AppKit
import Carbon.HIToolbox
import ServiceManagement

/// UserDefaults-backed preferences. The same keys are used by `@AppStorage` in the preferences window.
enum Pref {
    static let defaults: [String: Any] = [
        "afterCopy": true,
        "afterSave": false,
        "afterEdit": false,
        "afterPreview": true,
        "previewClosing": "8",
        "previewCorner": "bottomRight",
        "previewSize": "medium",
        "snapHighlight": true,
        "configAutoApply": false,
        "loupeZoom": "medium",
        "closeAfterDrag": false,
        "quickAccessHideOpened": false,
        "clipboardImage": "never",
        "confirmationStyle": "bubble",
        "diagnosticLogs": true,
        "logDays": 7,
        "updateChannel": "stable",
        "updateCheckAtLaunch": false,
        "menuBarTimer": true,
        "micDeviceID": "",
        "cameraDeviceID": "",
        "clickRings": 1,
        "clickOpacity": 1.0,
        "keyPillSize": 20.0,
        "keyPillPosition": "bottom",
        "keyPillSeconds": 1.6,
        "defaultZoom": "fit",
        "scrollSpeed": "normal",
        "libraryIndexFolder": true,
        "uploadService": "http",
        "s3Endpoint": "", "s3Region": "", "s3Bucket": "", "s3AccessKey": "", "s3Prefix": "", "s3PublicBase": "",
        "s3LinkMode": "none", "s3ExpiryDays": 7,
        "windowBackground": "transparent",
        "windowBackgroundColor": 0x1B1B1E,
        "sizeInPoints": false,
        "quickActions": "edit,copy,save,ocr,pin",
        "quickAccessStyle": "stack",
        "ocrEngine": "builtin",
        "ocrEndpoint": "",
        "ocrModel": "",
        "ocrPrompt": "",
        "ocrAPIKey": "",
        "freezeScreen": true,
        "colorPanel": true,
        "colorCopyOnPick": true,
        "scrollMaxHeight": 20000,
        "toolStyleMemory": true,
        "previewSwipeLeft": "dismiss",
        "previewSwipeRight": "dismiss",
        "quickAccessSounds": false,
        "libraryFilter": "all",
        "showMenuBarIcon": true,
        "urlScheme": true,
        "historyLimit": 200,
        "combineGap": 0,
        "appLanguage": "system",
        "previewAnimation": "slide",
        "previewSwipe": true,
        "ocrDetectLinks": false,
        "afterPin": false,
        "saveFolder": (NSHomeDirectory() as NSString).appendingPathComponent("Pictures/Snapix"),
        "filenameTemplate": "Snapix {date} at {time}",
        "format": "auto",
        "jpegQuality": 0.9,
        "downscale": false,
        "escCopy": true,
        "escSave": false,
        "colorFormat": "hex",
        "ocrRemoveBreaks": false,
        "reverseScroll": false,
        "pinsOnTop": true,
        "areaAdjust": false,
        "snapEdges": true,
        "showDockIcon": false,
        "hideHome": false,
        "wheelZoom": true,
        "keepHistory": true,
        "captureSound": true,
        "hideDesktopIcons": false,
        "recordCountdown": 3,
        "recordReview": true,
        "onboarded": false,
        "largerWindow": false,
        "editorOnTop": false,
        "redact.email": true, "redact.card": true, "redact.iban": true,
        "redact.secret": true, "redact.phone": true, "redact.ipAddress": true,
        "recordAudio": false,
        "recordCursor": true,
        "recordClicks": false,
        "recordCamera": false,
        "cameraShape": "circle",
        "cameraSize": "medium",
        "cameraCorner": "bottomRight",
        "cameraMirror": true,
        "clickColor": 0x5B8CFF,
        "clickSize": 54.0,
        "clickDuration": 0.55,
        "overlayDim": 0.4,
        "showLoupe": true,
        "loupeSize": "medium",
        "recordKeystrokes": false,
        "recordingTemplate": "Snapix Recording {date} at {time}",
        "recordFPS": 30,
        "recordQuality": "medium",
        "recordMaxSize": "native",
        "screenshotCursor": false,
        "watermarkEnabled": false,
        "watermarkText": "",
        "watermarkPosition": "bottomRight",
        "watermarkOpacity": 0.6,
        "watermarkSize": 4.0,
        "confirmClose": true,
        "windowShadow": false,
        "defaultTool": "arrow",
        "rememberTool": false,
        "lastTool": "arrow",
        "recordMicrophone": false,
        "recordReveal": false,
        "captureDelay": 3,
        "uploadURL": "",
        "uploadField": "file",
        "uploadAuthHeader": "",
    ]

    static func register() { UserDefaults.standard.register(defaults: defaults) }
    static func bool(_ k: String) -> Bool { UserDefaults.standard.bool(forKey: k) }
    static func string(_ k: String) -> String { UserDefaults.standard.string(forKey: k) ?? "" }
    static func integer(_ k: String) -> Int { UserDefaults.standard.integer(forKey: k) }
    static func double(_ k: String) -> Double { UserDefaults.standard.double(forKey: k) }

    /// Seconds of the countdown before a delayed capture.
    static var delay: Int { max(1, UserDefaults.standard.integer(forKey: "captureDelay")) }

    // MARK: Backup

    /// Keys that belong in a settings backup. The upload credential is left out so a shared backup never leaks it.
    static func isBackedUp(_ key: String) -> Bool {
        guard key != "uploadAuthHeader", key != "ocrAPIKey", key != "s3AccessKey" else { return false }
        return defaults[key] != nil || key.hasPrefix("hotkey.") || ["backdropConfig", "ocrLanguage"].contains(key)
    }

    /// Settings as a property list: preferences, shortcuts and backdrop style.
    static func backupData(from store: UserDefaults = .standard) -> Data? {
        let all = store.dictionaryRepresentation().filter { isBackedUp($0.key) }
        return try? PropertyListSerialization.data(fromPropertyList: all, format: .xml, options: 0)
    }

    /// Applies a backup made by `backupData`; returns the number of settings restored, or nil if the file is not a backup.
    @discardableResult
    static func restore(_ data: Data, into store: UserDefaults = .standard) -> Int? {
        guard let dict = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else { return nil }
        let accepted = dict.filter { isBackedUp($0.key) }
        guard !accepted.isEmpty else { return nil }
        for (k, v) in accepted { store.set(v, forKey: k) }
        return accepted.count
    }

    /// Back to factory settings: every key a backup would hold is removed (the registered defaults then apply again).
    static func resetAll(in store: UserDefaults = .standard) {
        if store === UserDefaults.standard { Keychain.set("", for: "s3SecretKey") }
        for key in store.dictionaryRepresentation().keys where isBackedUp(key) || key == "uploadAuthHeader" || key == "ocrAPIKey" || key == "s3AccessKey" || key == "stylePresets" || key.hasPrefix("toolStyle.") { store.removeObject(forKey: key) }
    }

    static func resetShortcuts(in store: UserDefaults = .standard) {
        for key in store.dictionaryRepresentation().keys where key.hasPrefix("hotkey.") { store.removeObject(forKey: key) }
    }

    /// Chooses the app language ("system", "en" or "fr"); it applies after a relaunch.
    static func setLanguage(_ code: String) {
        if code == "system" { UserDefaults.standard.removeObject(forKey: "AppleLanguages") }
        else { UserDefaults.standard.set([code], forKey: "AppleLanguages") }
    }

    /// Starts a fresh copy of the app and quits this one.
    @MainActor
    static func relaunch() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 0.6; open -n \"\(Bundle.main.bundlePath)\""]
        try? p.run()
        NSApp.terminate(nil)
    }

    static func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Launch at login failed: \(error)")
        }
    }

    static var launchAtLogin: Bool { SMAppService.mainApp.status == .enabled }
}

/// Everything the user can trigger from the menu bar, a hotkey or a `snapix://` URL.
enum Action: String, CaseIterable {
    case area, fullscreen, window, activeWindow, delayed, repeatArea
    case scrolling, scrollingUp, scrollingManual, quickAccess, application, element, ocr, cutout, record, recordGIF, recordFullscreen, recordWindow, pickColor, contrast, clipboard, library, shortcuts

    var title: String {
        switch self {
        case .area: return L("Area Capture")
        case .fullscreen: return L("Fullscreen Screenshot")
        case .window: return L("Capture Any Window")
        case .activeWindow: return L("Capture Active Window")
        case .delayed: return LF("Delayed Screenshot (%ds)", Pref.delay)
        case .repeatArea: return L("Repeat Last Area")
        case .scrolling: return L("Scrolling Capture")
        case .scrollingUp: return L("Scrolling Capture Upwards")
        case .scrollingManual: return L("Manual Scrolling Capture")
        case .ocr: return L("Recognize Text / QR Code")
        case .quickAccess: return L("Show Quick Access")
        case .application: return L("Capture Application")
        case .element: return L("Capture Interface Element")
        case .cutout: return L("Capture Subject Without Background")
        case .record: return L("Record Screen Area")
        case .recordGIF: return L("Record Screen Area as GIF")
        case .recordFullscreen: return L("Record Fullscreen")
        case .recordWindow: return L("Record a Window")
        case .pickColor: return L("Pick Color")
        case .contrast: return L("Check Contrast")
        case .clipboard: return L("Open From Clipboard")
        case .library: return L("Open Library")
        case .shortcuts: return L("Show Shortcuts")
        }
    }

    var defaultCombo: KeyCombo? {
        let flags = UInt32(cmdKey | shiftKey)
        switch self {
        case .fullscreen: return KeyCombo(keyCode: UInt32(kVK_ANSI_1), modifiers: flags, label: "1")
        case .area: return KeyCombo(keyCode: UInt32(kVK_ANSI_2), modifiers: flags, label: "2")
        case .window: return KeyCombo(keyCode: UInt32(kVK_ANSI_7), modifiers: flags, label: "7")
        case .quickAccess: return KeyCombo(keyCode: UInt32(kVK_ANSI_6), modifiers: flags, label: "6")
        case .ocr: return KeyCombo(keyCode: UInt32(kVK_ANSI_8), modifiers: flags, label: "8")
        case .scrolling: return KeyCombo(keyCode: UInt32(kVK_ANSI_9), modifiers: flags, label: "9")
        case .delayed: return KeyCombo(keyCode: UInt32(kVK_ANSI_0), modifiers: flags, label: "0")
        default: return nil
        }
    }

    var combo: KeyCombo? {
        get {
            let k = "hotkey.\(rawValue)"
            guard let data = UserDefaults.standard.data(forKey: k) else { return defaultCombo }
            return try? JSONDecoder().decode(KeyCombo?.self, from: data)
        }
        nonmutating set {
            let data = try? JSONEncoder().encode(newValue)
            UserDefaults.standard.set(data, forKey: "hotkey.\(rawValue)")
        }
    }
}

/// What to do with a fresh capture.
enum After: String {
    case copy, save, edit, pin, preview

    static func fromPreferences() -> [After] {
        var out: [After] = []
        if Pref.bool("afterCopy") { out.append(.copy) }
        if Pref.bool("afterSave") { out.append(.save) }
        if Pref.bool("afterEdit") { out.append(.edit) }
        if Pref.bool("afterPin") { out.append(.pin) }
        if Pref.bool("afterPreview") { out.append(.preview) }
        return out
    }
}
