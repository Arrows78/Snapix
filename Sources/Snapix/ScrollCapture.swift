import AppKit
import ApplicationServices

/// Stacks successive frames of a scrolling region into one tall image by finding the vertical offset between frames.
final class Stitcher {
    enum Outcome { case appended(offset: Int), noChange, noMatch }

    private struct Frame {
        let w: Int, h: Int
        let px: [UInt8]
        let hash: [UInt64]
        let flat: [Bool]
    }

    private let width: Int
    private var accumulated: [UInt8]
    private(set) var height: Int
    private var prev: Frame
    /// Tallest stitched image in pixels: the "scrollMaxHeight" preference, 20 000 by default.
    static var maxHeight: Int {
        let v = UserDefaults.standard.integer(forKey: "scrollMaxHeight")
        return v > 0 ? min(v, 60_000) : 20_000
    }

    init?(first: CGImage) {
        guard let f = Stitcher.decode(first) else { return nil }
        width = f.w
        height = f.h
        accumulated = f.px
        prev = f
    }

    private static func decode(_ image: CGImage) -> Frame? {
        let w = image.width, h = image.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: Renderer.sRGB,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var hashes = [UInt64](repeating: 0, count: h)
        var flat = [Bool](repeating: true, count: h)
        for y in 0..<h {
            var hash: UInt64 = 0xcbf29ce484222325
            let base = y * w * 4
            let first = (px[base] & 0xFC, px[base + 1] & 0xFC, px[base + 2] & 0xFC)
            var isFlat = true
            for x in 0..<w {
                let i = base + x * 4
                let r = px[i] & 0xFC, g = px[i + 1] & 0xFC, b = px[i + 2] & 0xFC
                hash = (hash ^ UInt64(r)) &* 0x100000001b3
                hash = (hash ^ UInt64(g)) &* 0x100000001b3
                hash = (hash ^ UInt64(b)) &* 0x100000001b3
                if isFlat && (r != first.0 || g != first.1 || b != first.2) { isFlat = false }
            }
            hashes[y] = hash
            flat[y] = isFlat
        }
        return Frame(w: w, h: h, px: px, hash: hashes, flat: flat)
    }

    /// Down: frame N+1 is the previous frame shifted up by `d` rows (new content at the bottom).
    /// Up: it is shifted down by `d` rows (new content at the top). Sticky headers/footers are excluded from the comparison.
    func add(_ image: CGImage, up: Bool = false) -> Outcome {
        guard image.width == width, let f = Stitcher.decode(image), f.h == prev.h, height < Stitcher.maxHeight else { return .noMatch }
        let h = f.h
        let margin = Int(Double(h) * 0.12)

        func matches(_ d: Int) -> Bool {
            let lo = d == 0 ? 0 : margin
            let hi = d == 0 ? h : h - d - margin
            guard hi - lo >= 12 else { return false }
            var informative = 0, bad = 0
            for i in lo..<hi {
                let pi = up ? i : i + d, ni = up ? i + d : i
                if prev.flat[pi] && f.flat[ni] { continue }
                informative += 1
                if prev.hash[pi] != f.hash[ni] {
                    bad += 1
                    if bad > max(2, (hi - lo) / 20) { return false }
                }
            }
            return informative >= 8 || d == 0
        }

        if matches(0) { return .noChange }
        // Very short regions leave no room to search (and an empty reversed range would trap).
        guard h - 2 * margin - 12 > 1 else { return .noMatch }
        for d in 1..<(h - 2 * margin - 12) where matches(d) {
            if up {
                accumulated.insert(contentsOf: f.px[0..<(d * width * 4)], at: 0)
            } else {
                accumulated.append(contentsOf: f.px[((h - d) * width * 4)..<(h * width * 4)])
            }
            height += d
            prev = f
            return .appended(offset: d)
        }
        return .noMatch
    }

    /// A small picture of the stitched result so far: the latest rows (the first rows when scrolling up, where new content is added).
    func preview(rows: Int, fromTop: Bool) -> CGImage? {
        let n = min(rows, height)
        guard n > 0 else { return nil }
        let bytes = fromTop ? Array(accumulated.prefix(width * 4 * n)) : Array(accumulated.suffix(width * 4 * n))
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: n, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: Renderer.sRGB, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    func result() -> CGImage? {
        guard let provider = CGDataProvider(data: Data(accumulated) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: Renderer.sRGB, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

/// Floating "Stop" button shown while a scrolling capture runs.
@MainActor
private final class ScrollHUD: NSObject {
    private(set) var stopped = false
    private let panel: NSPanel
    private let previewView = NSImageView()
    private let summary = NSTextField(labelWithString: "")

    init(text: String, avoiding region: CGRect, on screen: NSScreen) {
        let label = NSTextField(labelWithString: L(text))
        label.textColor = .white
        label.font = .systemFont(ofSize: 13, weight: .medium)
        let button = NSButton(title: L("Done"), target: nil, action: nil)
        button.bezelStyle = .rounded
        let stack = NSStackView(views: [label, button])
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 16, bottom: 10, right: 12)
        let box = NSVisualEffectView()
        box.material = .hudWindow
        box.state = .active
        box.wantsLayer = true
        box.layer?.cornerRadius = 12
        previewView.imageScaling = .scaleProportionallyUpOrDown
        previewView.wantsLayer = true
        previewView.layer?.cornerRadius = 6
        previewView.layer?.masksToBounds = true
        previewView.layer?.backgroundColor = NSColor(white: 1, alpha: 0.08).cgColor
        previewView.translatesAutoresizingMaskIntoConstraints = false
        previewView.widthAnchor.constraint(equalToConstant: 260).isActive = true
        previewView.heightAnchor.constraint(equalToConstant: 84).isActive = true
        summary.textColor = NSColor(white: 1, alpha: 0.6)
        summary.font = .systemFont(ofSize: 11)
        let outer = NSStackView(views: [previewView, summary, stack])
        outer.orientation = .vertical
        outer.alignment = .centerX
        outer.spacing = 6
        outer.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 4, right: 12)
        outer.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(outer)
        NSLayoutConstraint.activate([
            outer.leadingAnchor.constraint(equalTo: box.leadingAnchor), outer.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            outer.topAnchor.constraint(equalTo: box.topAnchor), outer.bottomAnchor.constraint(equalTo: box.bottomAnchor),
        ])
        let size = outer.fittingSize
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .statusBar
        panel.contentView = box
        super.init()
        button.target = self
        button.action = #selector(stop)

        var origin = CGPoint(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height - 50)
        if CGRect(origin: origin, size: size).intersects(region) { origin.y = screen.frame.minY + 60 }
        if CGRect(origin: origin, size: size).intersects(region) { origin.x = screen.frame.minX + 20 }
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
    }

    /// Shows the latest stitched rows and how much has been captured so far.
    func update(preview: CGImage?, frames: Int, height: Int) {
        if let preview { previewView.image = NSImage(cgImage: preview, size: NSSize(width: preview.width, height: preview.height)) }
        summary.stringValue = LF("%d frames · %d px", frames, height)
    }

    @objc private func stop() { stopped = true }
    func close() { panel.orderOut(nil) }
}

@MainActor
enum ScrollCapture {
    private static func ensureAccessibility() -> Bool {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    private static func postScroll(atCG p: CGPoint, pixels: Int) {
        CGWarpMouseCursorPosition(p)
        let invert = Pref.bool("reverseScroll") ? -1 : 1
        let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: Int32(-pixels * invert), wheel2: 0, wheel3: 0)
        e?.location = p
        e?.post(tap: .cghidEventTap)
    }

    /// Time to let the page settle after each automatic scroll step: slower means more reliable on heavy pages.
    nonisolated static func settleDelay(for speed: String) -> UInt64 {
        switch speed { case "fast": return 300_000_000; case "slow": return 900_000_000; case "verySlow": return 1_500_000_000; default: return 500_000_000 }
    }

    private static func settleDelay() -> UInt64 { settleDelay(for: Pref.string("scrollSpeed")) }

    static func run(auto: Bool, up: Bool = false) async throws -> Shot? {
        if auto && !ensureAccessibility() {
            Toast.show(L("Allow Snapix in Privacy & Security › Accessibility to scroll automatically, then try again"), duration: 4, symbol: "exclamationmark.triangle.fill")
            return nil
        }
        guard let (rect, screen) = try await Capture.selectRegion() else { return nil }
        let scale = screen.backingScaleFactor
        try? await Task.sleep(nanoseconds: 250_000_000)

        let hud = ScrollHUD(text: auto ? (up ? "Scrolling up…" : "Scrolling…") : "Scroll the content (up or down), then press Done", avoiding: rect, on: screen)
        defer { hud.close() }

        guard let first = try? await Capture.captureRegion(rect, on: screen, excludingSelf: true),
              let stitcher = Stitcher(first: first) else { return nil }

        let centerCG = CGPoint(x: rect.midX, y: Capture.primaryHeight - rect.midY)
        var step = Int(rect.height * 0.35)
        var failures = 0
        var frames = 1
        hud.update(preview: first, frames: 1, height: first.height)

        for _ in 0..<80 {
            if hud.stopped { break }
            if auto { postScroll(atCG: centerCG, pixels: up ? -step : step) }
            try? await Task.sleep(nanoseconds: auto ? settleDelay() : 300_000_000)
            guard let frame = try? await Capture.captureRegion(rect, on: screen, excludingSelf: true) else { break }
            var outcome = stitcher.add(frame, up: up)
            if !auto, case .noMatch = outcome { outcome = stitcher.add(frame, up: true) } // manual: user may scroll either way
            switch outcome {
            case let .appended(offset):
                failures = 0
                frames += 1
                if frames % 2 == 0 || frames < 4 {
                    hud.update(preview: stitcher.preview(rows: Int(Double(first.width) * 84 / 260 * 1.0) * 2, fromTop: up), frames: frames, height: stitcher.height)
                }
                if auto { // aim for ~45% of the frame per scroll step
                    let ratio = (Double(first.height) * 0.45) / Double(offset)
                    step = max(10, min(Int(rect.height * 0.7), Int(Double(step) * ratio)))
                }
            case .noChange:
                if auto { return finish(stitcher, scale: scale, rect: rect) }
            case .noMatch:
                failures += 1
                if auto { step = max(10, step / 2) }
                if auto && failures >= 3 {
                    Toast.show(L("Couldn't align the last frames — kept what was captured"), duration: 3)
                    return finish(stitcher, scale: scale, rect: rect)
                }
            }
            if stitcher.height >= Stitcher.maxHeight { break }
        }
        return finish(stitcher, scale: scale, rect: rect)
    }

    private static func finish(_ s: Stitcher, scale: CGFloat, rect: CGRect) -> Shot? {
        guard let img = s.result() else { return nil }
        return Shot(image: img, scale: scale, screenRect: rect, placeAtRegion: true)
    }
}
