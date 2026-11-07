import AVFoundation
import AppKit

/// A floating webcam preview placed over the recorded area, so it ends up in the video.
@MainActor
final class CameraBubble {
    let window: NSPanel
    private let session = AVCaptureSession()

    enum Shape: String { case circle, square }

    /// Side length in points for "small", "medium" and "large".
    static func side(for size: String) -> CGFloat {
        switch size { case "small": return 120; case "large": return 260; default: return 180 }
    }

    /// The bubble's frame inside `rect` (global coordinates) for a corner name, kept `margin` points from the edges.
    static func frame(side: CGFloat, corner: String, in rect: CGRect, margin: CGFloat = 16) -> CGRect {
        let m = min(margin, max(0, (min(rect.width, rect.height) - side) / 2))
        let x = corner.hasSuffix("Left") ? rect.minX + m : rect.maxX - side - m
        let y = corner.hasPrefix("top") ? rect.maxY - side - m : rect.minY + m
        return CGRect(x: x, y: y, width: side, height: side)
    }

    static func authorized() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    /// nil when there is no camera or access was refused.
    static func make(in rect: CGRect) async -> CameraBubble? {
        guard await authorized(), let device = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: device) else { return nil }
        return CameraBubble(input: input, in: rect)
    }

    private init?(input: AVCaptureDeviceInput, in rect: CGRect) {
        guard session.canAddInput(input) else { return nil }
        session.addInput(input)
        session.sessionPreset = .medium

        let side = Self.side(for: Pref.string("cameraSize"))
        let shape = Shape(rawValue: Pref.string("cameraShape")) ?? .circle
        let frame = Self.frame(side: side, corner: Pref.string("cameraCorner"), in: rect)

        let view = NSView(frame: NSRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        view.layer?.masksToBounds = true
        view.layer?.cornerRadius = shape == .circle ? side / 2 : 18
        view.layer?.borderWidth = 3
        view.layer?.borderColor = NSColor.white.withAlphaComponent(0.9).cgColor
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.frame = view.bounds
        preview.videoGravity = .resizeAspectFill
        if Pref.bool("cameraMirror") { preview.setAffineTransform(CGAffineTransform(scaleX: -1, y: 1)) }
        view.layer?.addSublayer(preview)

        window = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .statusBar
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentView = view
        window.orderFrontRegardless()
        let s = session
        DispatchQueue.global(qos: .userInitiated).async { s.startRunning() }
    }

    func stop() {
        let s = session
        DispatchQueue.global(qos: .userInitiated).async { s.stopRunning() }
        window.orderOut(nil)
    }
}
