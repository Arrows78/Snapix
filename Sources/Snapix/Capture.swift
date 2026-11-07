import AppKit
import ScreenCaptureKit

struct Frozen {
    let screen: NSScreen
    let image: CGImage
}

struct WindowInfo {
    let id: CGWindowID
    /// AppKit global coordinates (bottom-left origin).
    let rect: CGRect
    let pid: pid_t
}

enum CaptureError: Error { case noPermission, notFound }

/// Screen access through ScreenCaptureKit. All rects are AppKit global coordinates unless noted.
@MainActor
enum Capture {
    static var lastArea: CGRect?

    // MARK: Permission

    static func ensurePermission() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        CGRequestScreenCaptureAccess()
        return false
    }

    static func showPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = L("Screen Recording permission needed")
        alert.informativeText = L("Snapix needs access to record your screen. Enable it in System Settings › Privacy & Security › Screen & System Audio Recording, then relaunch Snapix.")
        alert.addButton(withTitle: L("Open System Settings"))
        alert.addButton(withTitle: L("Cancel"))
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Coordinates

    static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    static func appKitRect(fromCG r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    static func screen(containing rect: CGRect) -> NSScreen? {
        NSScreen.screens.max { a, b in
            a.frame.intersection(rect).width * a.frame.intersection(rect).height
                < b.frame.intersection(rect).width * b.frame.intersection(rect).height
        }
    }

    static func screenUnderMouse() -> NSScreen {
        let p = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    static func displayID(_ s: NSScreen) -> CGDirectDisplayID {
        (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    // MARK: Primitive captures

    private static func content() async throws -> SCShareableContent {
        do { return try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) }
        catch { throw CaptureError.noPermission }
    }

    /// The filter used for every capture: optionally without the desktop icons and without our own windows.
    static func filter(display: SCDisplay, content: SCShareableContent, excludingSelf: Bool) -> SCContentFilter {
        guard Pref.bool("hideDesktopIcons") else {
            let apps = excludingSelf ? content.applications.filter { $0.processID == getpid() } : []
            return SCContentFilter(display: display, excludingApplications: apps, exceptingWindows: [])
        }
        let iconLevel = Int(CGWindowLevelForKey(.desktopIconWindow))
        let hidden = content.windows.filter { w in
            (w.owningApplication?.bundleIdentifier == "com.apple.finder" && w.windowLayer == iconLevel)
                || (excludingSelf && w.owningApplication?.processID == getpid())
        }
        return SCContentFilter(display: display, excludingWindows: hidden)
    }

    static func captureRegion(_ rect: CGRect, on screen: NSScreen, excludingSelf: Bool) async throws -> CGImage {
        let content = try await content()
        guard let display = content.displays.first(where: { $0.displayID == displayID(screen) }) else { throw CaptureError.notFound }
        let filter = filter(display: display, content: content, excludingSelf: excludingSelf)
        let cfg = SCStreamConfiguration()
        let scale = screen.backingScaleFactor
        cfg.sourceRect = CGRect(x: rect.minX - screen.frame.minX, y: screen.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
        cfg.width = Int((rect.width * scale).rounded())
        cfg.height = Int((rect.height * scale).rounded())
        cfg.showsCursor = Pref.bool("screenshotCursor")
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
    }

    static func captureWindow(id: CGWindowID) async throws -> Shot {
        let content = try await content()
        guard let w = content.windows.first(where: { $0.windowID == id }) else { throw CaptureError.notFound }
        let rect = appKitRect(fromCG: w.frame)
        let scale = screen(containing: rect)?.backingScaleFactor ?? 2
        let cfg = SCStreamConfiguration()
        cfg.width = Int((w.frame.width * scale).rounded())
        cfg.height = Int((w.frame.height * scale).rounded())
        cfg.showsCursor = Pref.bool("screenshotCursor")
        cfg.ignoreShadowsSingleWindow = !Pref.bool("windowShadow")
        let img = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: w), configuration: cfg)
        return Shot(image: img, scale: scale, screenRect: rect)
    }

    // MARK: Windows

    /// On-screen normal windows, front to back.
    static func visibleWindows() -> [WindowInfo] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.compactMap { d in
            guard (d[kCGWindowLayer as String] as? Int) == 0,
                  let id = d[kCGWindowNumber as String] as? UInt32,
                  let b = d[kCGWindowBounds as String] as? [String: CGFloat],
                  let w = b["Width"], let h = b["Height"], w > 40, h > 40 else { return nil }
            let cg = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: w, height: h)
            return WindowInfo(id: id, rect: appKitRect(fromCG: cg), pid: pid_t(d[kCGWindowOwnerPID as String] as? Int32 ?? 0))
        }
    }

    static func activeWindowID() -> CGWindowID? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        return list.first { d in
            (d[kCGWindowLayer as String] as? Int) == 0 && (d[kCGWindowOwnerPID as String] as? Int32) == pid
        }?[kCGWindowNumber as String] as? UInt32
    }

    // MARK: High-level flows

    static func freeze() async throws -> [Frozen] {
        var out: [Frozen] = []
        for screen in NSScreen.screens {
            let img = try await captureRegion(screen.frame, on: screen, excludingSelf: false)
            out.append(Frozen(screen: screen, image: img))
        }
        return out
    }

    static func fullscreen() async throws -> Shot {
        let screen = screenUnderMouse()
        let img = try await captureRegion(screen.frame, on: screen, excludingSelf: false)
        return Shot(image: img, scale: screen.backingScaleFactor, screenRect: screen.frame)
    }

    static func activeWindow() async throws -> Shot {
        guard let id = activeWindowID() else { throw CaptureError.notFound }
        return try await captureWindow(id: id)
    }

    static func repeatArea() async throws -> Shot {
        guard let rect = lastArea, let screen = screen(containing: rect) else { throw CaptureError.notFound }
        let img = try await captureRegion(rect, on: screen, excludingSelf: false)
        return Shot(image: img, scale: screen.backingScaleFactor, screenRect: rect, placeAtRegion: true)
    }

    /// Lets the user drag a rectangle on a frozen copy of the screen.
    static func area(remember: Bool = true) async throws -> Shot? {
        let frozen = try await freeze()
        switch await SelectionOverlay.run(frozen: frozen, mode: .area) {
        case let .area(f, pixelRect, screenRect, end):
            guard let crop = f.image.cropping(to: pixelRect) else { return nil }
            if remember { lastArea = screenRect }
            return Shot(image: crop, scale: f.screen.backingScaleFactor, screenRect: screenRect, placeAtRegion: true, anchorPoint: end)
        default:
            return nil
        }
    }

    static func interactiveWindow() async throws -> Shot? {
        let frozen = try await freeze()
        switch await SelectionOverlay.run(frozen: frozen, mode: .window) {
        case let .window(id):
            try? await Task.sleep(nanoseconds: 150_000_000) // let the overlay fade out
            return try await captureWindow(id: id)
        default:
            return nil
        }
    }

    /// Hover any interface element (button, toolbar, panel…) and click to capture exactly its bounds.
    static func element() async throws -> Shot? {
        guard ElementPicker.isTrusted else {
            ElementPicker.requestAccess()
            Toast.show(L("Allow Snapix in Privacy & Security › Accessibility, then try again"), duration: 4, symbol: "exclamationmark.triangle.fill")
            return nil
        }
        let frozen = try await freeze()
        guard case let .area(f, pixelRect, screenRect, end) = await SelectionOverlay.run(frozen: frozen, mode: .element),
              let crop = f.image.cropping(to: pixelRect) else { return nil }
        return Shot(image: crop, scale: f.screen.backingScaleFactor, screenRect: screenRect, placeAtRegion: true, anchorPoint: end)
    }

    /// Area selection that returns the geometry only (scrolling capture needs a live region, not a frozen crop).
    static func selectRegion() async throws -> (rect: CGRect, screen: NSScreen)? {
        let frozen = try await freeze()
        if case let .area(f, _, screenRect, _) = await SelectionOverlay.run(frozen: frozen, mode: .area) { return (screenRect, f.screen) }
        return nil
    }
}
