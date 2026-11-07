import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var busy = false

    /// Set when macOS refuses to show our menu bar icon (crowded or restricted menu bar): the Dock becomes the entry point.
    static var forceDock = false
    static var restingPolicy: NSApplication.ActivationPolicy { (forceDock || Pref.bool("showDockIcon")) ? .regular : .accessory }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Pref.register()
        NSApp.setActivationPolicy(Self.restingPolicy)
        buildMainMenu()
        buildStatusItem()
        checkStatusItemVisibility()
        if !Pref.bool("hideHome") { HomeWindow.show() }
        reloadHotkeys()
        History.pruneNow()
        if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        refreshMenuShortcuts()
        return statusItem?.menu?.copy() as? NSMenu
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { HomeWindow.show() }
        return true
    }

    private func checkStatusItemVisibility() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [self] in
            let w = statusItem.button?.window
            // A placed status item sits in the menu bar strip at the top of a screen; an unplaced one is a zero-height window at the origin.
            let onScreen = w.map { win in
                win.isVisible && win.frame.height > 4 && NSScreen.screens.contains { $0.frame.maxY - win.frame.maxY < 8 && $0.frame.intersects(win.frame) }
            } ?? false
            if ProcessInfo.processInfo.environment["SNAPIX_DIAG"] != nil {
                print("statusItem window=\(String(describing: w?.frame)) visible=\(w?.isVisible ?? false) onScreen=\(onScreen)")
                exit(0)
            }
            guard !onScreen else { return }
            Self.forceDock = true
            NSApp.setActivationPolicy(.regular)
            Toast.show(L("The menu bar icon is hidden by macOS — Snapix is available from the Dock instead"), duration: 6, symbol: "exclamationmark.triangle.fill")
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if url.scheme == "snapix" { handle(url: url) } else if url.isFileURL { EditorWindowController.openFiles([url]) }
        }
    }

    // MARK: URL scheme  —  snapix://area?then=copy,save,edit,pin

    private func handle(url: URL) {
        let name = url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let map: [String: Action] = [
            "area": .area, "fullscreen": .fullscreen, "window": .window, "active-window": .activeWindow, "delayed": .delayed,
            "repeat": .repeatArea, "scrolling": .scrolling, "scrolling-up": .scrollingUp, "scrolling-manual": .scrollingManual, "ocr": .ocr, "cutout": .cutout, "element": .element, "record": .record, "record-gif": .recordGIF,
            "pick-color": .pickColor, "contrast": .contrast, "clipboard": .clipboard, "library": .library, "shortcuts": .shortcuts,
        ]
        guard let action = map[name] else { return }
        var then: [After]?
        if let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "then" })?.value {
            then = q.split(separator: ",").compactMap { After(rawValue: String($0)) }
        }
        perform(action, then: then)
    }

    // MARK: Hotkeys

    func reloadHotkeys() {
        HotKeyCenter.shared.unregisterAll()
        for a in Action.allCases {
            if let combo = a.combo { HotKeyCenter.shared.register(combo) { [weak self] in self?.perform(a) } }
        }
        refreshMenuShortcuts()
    }

    // MARK: Menu bar

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "viewfinder", accessibilityDescription: "Snapix")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        refreshMenuShortcuts()
    }

    func menuNeedsUpdate(_ menu: NSMenu) { refreshMenuShortcuts() }

    private func refreshMenuShortcuts() {
        guard let menu = statusItem?.menu else { return }
        menu.removeAllItems()
        func add(_ a: Action) {
            let item = NSMenuItem(title: a.title, action: #selector(menuAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = a.rawValue
            if let c = a.combo { item.attributedTitle = NSAttributedString(string: "\(a.title)\t\(c.display)") }
            menu.addItem(item)
        }
        [Action.area, .fullscreen, .window, .activeWindow, .element, .delayed, .repeatArea].forEach(add)
        menu.addItem(.separator())
        [Action.scrolling, .scrollingUp, .scrollingManual].forEach(add)
        menu.addItem(.separator())
        [Action.record, .recordGIF].forEach(add)
        menu.addItem(.separator())
        [Action.ocr, .cutout, .pickColor, .contrast].forEach(add)
        menu.addItem(.separator())
        add(.clipboard)
        add(.library)
        addRecentCaptures(to: menu)
        add(.shortcuts)
        let open = NSMenuItem(title: L("Open Image…"), action: #selector(openFile), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())
        let home = NSMenuItem(title: L("Show Snapix Window"), action: #selector(showHome), keyEquivalent: "")
        home.target = self
        menu.addItem(home)
        let prefs = NSMenuItem(title: L("Preferences…"), action: #selector(showPreferences), keyEquivalent: ",")
        prefs.target = self
        menu.addItem(prefs)
        menu.addItem(withTitle: L("Quit Snapix"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    /// The last few captures, each with Open / Copy / Pin / Reveal.
    private func addRecentCaptures(to menu: NSMenu) {
        let recent = Array(History.items().prefix(8))
        guard !recent.isEmpty else { return }
        let parent = NSMenuItem(title: L("Recent Captures"), action: nil, keyEquivalent: "")
        parent.image = NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: nil)
        let sub = NSMenu()
        for url in recent {
            let stamp = url.deletingPathExtension().lastPathComponent.components(separatedBy: "@").first ?? ""
            let item = NSMenuItem(title: Self.prettyStamp(stamp), action: nil, keyEquivalent: "")
            if let cg = History.thumbnail(for: url, maxPixel: 64) {
                item.image = NSImage(cgImage: cg, size: NSSize(width: 32, height: 32 * CGFloat(cg.height) / CGFloat(max(1, cg.width))))
            }
            let actions = NSMenu()
            for (title, sel) in [(L("Open in Editor"), #selector(recentOpen(_:))), (L("Copy"), #selector(recentCopy(_:))),
                                 (L("Pin"), #selector(recentPin(_:))), (L("Reveal in Finder"), #selector(recentReveal(_:)))] {
                let a = NSMenuItem(title: title, action: sel, keyEquivalent: "")
                a.target = self
                a.representedObject = url
                actions.addItem(a)
            }
            item.submenu = actions
            sub.addItem(item)
        }
        parent.submenu = sub
        menu.addItem(parent)
    }

    /// "20261107-231905-123" -> "07/11/2026 23:19" in the user's locale.
    private static func prettyStamp(_ stamp: String) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss-SSS"
        guard let d = f.date(from: stamp) else { return stamp }
        let out = DateFormatter()
        out.dateStyle = .short
        out.timeStyle = .short
        return out.string(from: d)
    }

    private func recentShot(_ sender: NSMenuItem) -> Shot? { (sender.representedObject as? URL).flatMap { History.shot(for: $0) } }
    @objc private func recentOpen(_ sender: NSMenuItem) { if let s = recentShot(sender) { EditorWindowController.open(s) } }
    @objc private func recentCopy(_ sender: NSMenuItem) { if let s = recentShot(sender) { Exporter.copy(s.image, scale: s.scale) } }
    @objc private func recentPin(_ sender: NSMenuItem) { if let s = recentShot(sender) { PinController.pin(s) } }
    @objc private func recentReveal(_ sender: NSMenuItem) { if let u = sender.representedObject as? URL { NSWorkspace.shared.activateFileViewerSelecting([u]) } }

    @objc private func menuAction(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let a = Action(rawValue: raw) else { return }
        // Let the menu finish closing so it isn't part of the screenshot.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.perform(a) }
    }

    @objc private func openFile() { EditorWindowController.openFile() }
    @objc func showPreferences() { PreferencesWindow.show() }
    @objc private func showHome() { HomeWindow.show() }

    private func buildMainMenu() {
        let main = NSMenu()
        func submenu(_ title: String, _ items: [NSMenuItem]) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let m = NSMenu(title: title)
            items.forEach(m.addItem)
            item.submenu = m
            main.addItem(item)
        }
        func mi(_ title: String, _ sel: String, _ key: String, _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: Selector((sel)), keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            return i
        }
        submenu(L("Snapix"), [mi(L("Preferences…"), "showPreferences", ","), .separator(),
                           mi(L("Hide Snapix"), "hide:", "h"), mi(L("Quit Snapix"), "terminate:", "q")])
        main.items[0].submenu?.items[0].target = self
        submenu(L("File"), [mi(L("Save"), "saveDocument:", "s"), mi(L("Save As…"), "saveDocumentAs:", "S", [.command, .shift]),
                         mi(L("Upload"), "uploadImage:", "u"), .separator(),
                         mi(L("Print…"), "printDocument:", "p"), mi(L("Close"), "performClose:", "w")])
        submenu(L("Edit"), [mi(L("Undo"), "undo:", "z"), mi(L("Redo"), "redo:", "Z", [.command, .shift]), .separator(),
                         mi(L("Cut"), "cut:", "x"), mi(L("Copy"), "copy:", "c"), mi(L("Paste"), "paste:", "v"), mi(L("Select All"), "selectAll:", "a")])
        submenu(L("View"), [mi(L("Zoom In"), "zoomInAction:", "+"), mi(L("Zoom Out"), "zoomOutAction:", "-"),
                         mi(L("Actual Size"), "zoomActualAction:", "0"), mi(L("Fit to Window"), "zoomFitAction:", "9")])
        submenu(L("Image"), [mi(L("Resize Image…"), "resizeImage:", "r", [.command, .option]), mi(L("Uncrop"), "uncropAction:", "u", [.command, .option]),
                          mi(L("Merge Annotations Into Image"), "rasterizeAction:", "m", [.command, .option]),
                          mi(L("Rotate Left"), "rotateLeftAction:", "[", .command), mi(L("Rotate Right"), "rotateRightAction:", "]", .command),
                          mi(L("Flip Horizontally"), "flipHorizontalAction:", "h", [.command, .option]),
                          mi(L("Flip Vertically"), "flipVerticalAction:", "v", [.command, .option]), .separator(),
                          mi(L("Overlay Image From Clipboard"), "overlayAction:", "i", [.command, .option]),
                          mi(L("Check Contrast of Selection"), "contrastAction:", "k", [.command, .option])])
        NSApp.mainMenu = main
    }

    // MARK: Orchestration

    func perform(_ action: Action, then override: [After]? = nil) {
        if (action == .record || action == .recordGIF), Recorder.shared.isRecording {
            Task { await Recorder.shared.stop() }
            return
        }
        guard !busy else { return }
        switch action {
        case .pickColor: ColorTools.pickAndCopy(); return
        case .contrast: ColorTools.contrastCheck(); return
        case .clipboard: EditorWindowController.openFromClipboard(); return
        case .library: LibraryWindow.show(); return
        case .shortcuts: ShortcutSheet.show(); return
        default: break
        }
        guard Capture.ensurePermission() else { Capture.showPermissionAlert(); return }

        busy = true
        Task { @MainActor in
            defer { busy = false }
            do {
                switch action {
                case .area: if let s = try await Capture.area() { deliver(s, override) }
                case .fullscreen: deliver(try await Capture.fullscreen(), override)
                case .window: if let s = try await Capture.interactiveWindow() { deliver(s, override) }
                case .activeWindow: deliver(try await Capture.activeWindow(), override)
                case .repeatArea: deliver(try await Capture.repeatArea(), override)
                case .element: if let s = try await Capture.element() { deliver(s, override) }
                case .delayed:
                    for n in stride(from: Pref.delay, through: 1, by: -1) { Toast.show(LF("Capturing in %d…", n), duration: 1); try? await Task.sleep(nanoseconds: 1_000_000_000) }
                    if let s = try await Capture.area() { deliver(s, override) }
                case .scrolling: if let s = try await ScrollCapture.run(auto: true) { deliver(s, override) }
                case .scrollingUp: if let s = try await ScrollCapture.run(auto: true, up: true) { deliver(s, override) }
                case .scrollingManual: if let s = try await ScrollCapture.run(auto: false) { deliver(s, override) }
                case .cutout:
                    if let s = try await Capture.area(remember: false) {
                        Toast.show(L("Removing background…"), duration: 1.5)
                        let cut: CGImage? = await withCheckedContinuation { c in Cutout.subject(of: s.image) { c.resume(returning: $0) } }
                        guard let cut else { Toast.show(L("No subject found"), symbol: "exclamationmark.triangle.fill"); break }
                        var shot = s
                        shot.image = cut
                        deliver(shot, override)
                    }
                case .record: try await Recorder.shared.start(format: .video)
                case .recordGIF: try await Recorder.shared.start(format: .gif)
                case .ocr: if let s = try await Capture.area(remember: false) { OCR.recognizeAndCopy(s.image) }
                default: break
                }
            } catch CaptureError.noPermission {
                Capture.showPermissionAlert()
            } catch CaptureError.notFound {
                Toast.show(L("Nothing to capture"), duration: 2, symbol: "exclamationmark.triangle.fill")
            } catch {
                Toast.show(LF("Capture failed: %@", error.localizedDescription), duration: 3, symbol: "exclamationmark.triangle.fill")
            }
        }
    }

    private func deliver(_ shot: Shot, _ override: [After]?) {
        Feedback.shutter()
        if Pref.bool("keepHistory") { History.add(shot) }
        var actions = override ?? After.fromPreferences()
        if actions.isEmpty { actions = [.edit] }
        if actions.contains(.copy) { Exporter.copy(shot.image, scale: shot.scale, quiet: actions.count > 1) }
        if actions.contains(.save) { Exporter.save(shot.image, scale: shot.scale, quiet: actions.contains(.copy)) }
        if actions.contains(.pin) { PinController.pin(shot) }
        if actions.contains(.preview) { PreviewController.show(shot) }
        if actions.contains(.edit) { EditorWindowController.open(shot) }
    }
}
