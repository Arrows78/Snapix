import AppKit
import ApplicationServices

/// Finds the interface element (button, toolbar, sidebar…) under a point through the Accessibility API.
enum ElementPicker {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestAccess() {
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }

    /// Rects (global coordinates, top-left origin) of the element at `point` and of its ancestors, smallest first.
    /// The query goes to the owning app directly, so the overlay covering the screen is never returned.
    static func chain(at point: CGPoint, pid: pid_t) -> [CGRect] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        var found: AXUIElement?
        guard AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &found) == .success, var element = found else { return [] }
        var rects: [CGRect] = []
        for _ in 0..<12 {
            if let r = frame(of: element), r.width >= 4, r.height >= 4, rects.last != r { rects.append(r) }
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parent) == .success,
                  let p = parent, CFGetTypeID(p) == AXUIElementGetTypeID() else { break }
            element = p as! AXUIElement
        }
        return rects
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        var pos: CFTypeRef?, size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &pos) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
              let pv = pos, let sv = size else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        guard AXValueGetValue(pv as! AXValue, .cgPoint, &p), AXValueGetValue(sv as! AXValue, .cgSize, &s) else { return nil }
        return CGRect(origin: p, size: s)
    }
}
