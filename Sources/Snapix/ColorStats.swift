import AppKit
import SwiftUI

/// Average, darkest, lightest and dominant colours of an image region.
struct ColorStats {
    var average: UInt32
    var darkest: UInt32
    var lightest: UInt32
    var palette: [UInt32]

    static func luma(_ r: Int, _ g: Int, _ b: Int) -> Int { (r * 299 + g * 587 + b * 114) / 1000 }

    /// Reads at most ~65 000 pixels (the image is sampled on a grid); nil for an empty image.
    static func compute(_ image: CGImage, paletteSize: Int = 6) -> ColorStats? {
        let side = 256
        let w = min(side, image.width), h = min(side, image.height)
        guard w > 0, h > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: Renderer.sRGB,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var sum = (0, 0, 0), count = 0
        var dark = (255 * 1000, UInt32(0)), light = (-1, UInt32(0))
        var buckets: [UInt32: Int] = [:]
        for i in stride(from: 0, to: buf.count, by: 4) where buf[i + 3] > 8 {
            let r = Int(buf[i]), g = Int(buf[i + 1]), b = Int(buf[i + 2])
            sum.0 += r; sum.1 += g; sum.2 += b; count += 1
            let l = luma(r, g, b), hex = UInt32(r << 16 | g << 8 | b)
            if l < dark.0 { dark = (l, hex) }
            if l > light.0 { light = (l, hex) }
            // 4 bits per channel groups near-identical shades.
            buckets[UInt32((r >> 4) << 8 | (g >> 4) << 4 | (b >> 4)), default: 0] += 1
        }
        guard count > 0 else { return nil }
        let avg = UInt32((sum.0 / count) << 16 | (sum.1 / count) << 8 | (sum.2 / count))
        var palette: [UInt32] = []
        for (key, _) in buckets.sorted(by: { $0.value > $1.value }) {
            let r = Int((key >> 8) & 0xF) * 17, g = Int((key >> 4) & 0xF) * 17, b = Int(key & 0xF) * 17
            // Skip shades too close to one already chosen.
            if palette.contains(where: { p in abs(Int(p >> 16) - r) + abs(Int((p >> 8) & 0xFF) - g) + abs(Int(p & 0xFF) - b) < 60 }) { continue }
            palette.append(UInt32(r << 16 | g << 8 | b))
            if palette.count == paletteSize { break }
        }
        return ColorStats(average: avg, darkest: dark.1, lightest: light.1, palette: palette)
    }
}

private struct ColorStatsView: View {
    let stats: ColorStats
    let onClose: () -> Void
    @State private var copied: UInt32?

    private func swatch(_ title: String, _ hex: UInt32) -> some View {
        Button {
            let text = ColorFormat.current.string(for: NSColor(hex: hex))
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
            copied = hex
        } label: {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: NSColor(hex: hex))).frame(width: 30, height: 30)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.25)))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 11)).foregroundStyle(Color.primary.opacity(0.55))
                    Text(ColorFormat.hex.string(for: NSColor(hex: hex))).font(.system(size: 12, design: .monospaced)).foregroundStyle(.primary)
                }
                Spacer()
                if copied == hex { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.green) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Color statistics").font(.system(size: 14, weight: .semibold)).foregroundStyle(.primary)
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)) }.buttonStyle(.plain).foregroundStyle(Color.primary.opacity(0.6))
            }
            swatch(L("Average"), stats.average)
            swatch(L("Darkest"), stats.darkest)
            swatch(L("Lightest"), stats.lightest)
            Divider().overlay(Color.primary.opacity(0.1))
            Text("Dominant colors").font(.system(size: 11)).foregroundStyle(Color.primary.opacity(0.55))
            HStack(spacing: 8) {
                ForEach(stats.palette, id: \.self) { h in
                    Button {
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(ColorFormat.current.string(for: NSColor(hex: h)), forType: .string); copied = h
                    } label: {
                        RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: NSColor(hex: h))).frame(width: 32, height: 32)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(copied == h ? 0.9 : 0.25)))
                    }
                    .buttonStyle(.plain).help(ColorFormat.hex.string(for: NSColor(hex: h)))
                }
            }
            Text("Click a color to copy it").font(.system(size: 10)).foregroundStyle(Color.primary.opacity(0.4))
        }
        .padding(14).frame(width: 280)
        .background(Color(nsColor: Theme.adaptiveWindow))
    }
}

@MainActor
enum ColorStatsPanel {
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { true }
        override func resignKey() { super.resignKey(); close() }
        override func cancelOperation(_ sender: Any?) { close() }
    }
    private static var panel: NSPanel?

    static func show(for image: CGImage) {
        guard let stats = ColorStats.compute(image) else { Toast.show(L("Nothing to analyse"), symbol: "exclamationmark.triangle.fill"); return }
        panel?.close()
        let host = NSHostingView(rootView: ColorStatsView(stats: stats, onClose: { panel?.close() }))
        let p = Panel(contentRect: NSRect(origin: .zero, size: host.fittingSize), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.contentView = host
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = true; p.level = .floating; p.isReleasedWhenClosed = false
        host.wantsLayer = true
        host.layer?.cornerRadius = 14; host.layer?.masksToBounds = true
        host.layer?.borderWidth = 1; host.layer?.borderColor = NSColor(white: 1, alpha: 0.12).cgColor
        let vf = (NSApp.keyWindow?.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        p.setFrameOrigin(NSPoint(x: vf.midX - p.frame.width / 2, y: vf.midY - p.frame.height / 2))
        p.makeKeyAndOrderFront(nil)
        panel = p
    }
}
