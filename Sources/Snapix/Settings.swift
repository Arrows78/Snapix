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
        "captureDelay": 3,
        "uploadURL": "",
        "uploadField": "file",
        "uploadAuthHeader": "",
    ]

    static func register() { UserDefaults.standard.register(defaults: defaults) }
    static func bool(_ k: String) -> Bool { UserDefaults.standard.bool(forKey: k) }
    static func string(_ k: String) -> String { UserDefaults.standard.string(forKey: k) ?? "" }
    static func double(_ k: String) -> Double { UserDefaults.standard.double(forKey: k) }

    /// Seconds of the countdown before a delayed capture.
    static var delay: Int { max(1, UserDefaults.standard.integer(forKey: "captureDelay")) }

    // MARK: Backup

    /// Keys that belong in a settings backup. The upload credential is left out so a shared backup never leaks it.
    private static func isBackedUp(_ key: String) -> Bool {
        guard key != "uploadAuthHeader" else { return false }
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
    case scrolling, scrollingUp, scrollingManual, ocr, pickColor, contrast, clipboard, library, shortcuts

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
