import AppKit
import ImageIO
import SwiftUI

/// Every capture is kept as a PNG under Application Support so the Library can reopen it later.
@MainActor
enum History {
    nonisolated static let limit = 200

    static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Snapix/History", isDirectory: true)
    }

    static func add(_ shot: Shot) {
        let image = shot.image, scale = Int(shot.scale.rounded())
        let dir = folder
        DispatchQueue.global(qos: .utility).async {
            let f = DateFormatter()
            f.dateFormat = "yyyyMMdd-HHmmss-SSS"
            let url = dir.appendingPathComponent("\(f.string(from: Date()))@\(scale)x.png")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) { try? data.write(to: url) }
            prune(in: dir)
        }
    }

    nonisolated private static func prune(in dir: URL) {
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter({ $0.pathExtension == "png" }).sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) else { return }
        for old in files.dropFirst(limit) { try? FileManager.default.removeItem(at: old) }
    }

    /// Newest first.
    static func items() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "png" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    static func scale(of url: URL) -> CGFloat {
        let name = url.deletingPathExtension().lastPathComponent
        guard let at = name.lastIndex(of: "@") else { return 1 }
        return CGFloat(Int(name[name.index(after: at)...].dropLast()) ?? 1)
    }

    static func shot(for url: URL) -> Shot? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        return Shot(image: img, scale: scale(of: url), screenRect: nil)
    }

    nonisolated static func thumbnail(for url: URL, maxPixel: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(src, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ] as CFDictionary)
    }

    static func clear() { items().forEach { try? FileManager.default.removeItem(at: $0) } }
}

private struct Thumb: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.12))
            if let image { Image(nsImage: image).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 6)).padding(4) }
        }
        .frame(height: 120)
        .task {
            let u = url
            let cg = await Task.detached { History.thumbnail(for: u, maxPixel: 480) }.value
            if let cg { image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)) }
        }
    }
}

private struct LibraryView: View {
    @State private var items = History.items()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(LF("%d screenshot(s)", items.count)).foregroundStyle(.secondary)
                Spacer()
                Button("Reveal in Finder") { NSWorkspace.shared.open(History.folder) }
                Button("Clear All", role: .destructive) { History.clear(); items = [] }.disabled(items.isEmpty)
            }
            .padding(10)
            Divider()
            if items.isEmpty {
                Spacer(); Text("Screenshots you take will appear here.").foregroundStyle(.secondary); Spacer()
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
                        ForEach(items, id: \.self) { url in
                            VStack(spacing: 4) {
                                Thumb(url: url)
                                Text(url.deletingPathExtension().lastPathComponent.components(separatedBy: "@").first ?? "")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            .onTapGesture(count: 2) { if let s = History.shot(for: url) { EditorWindowController.open(s) } }
                            .contextMenu {
                                Button("Open in Editor") { if let s = History.shot(for: url) { EditorWindowController.open(s) } }
                                Button("Copy") { if let s = History.shot(for: url) { Exporter.copy(s.image, scale: s.scale) } }
                                Button("Pin") { if let s = History.shot(for: url) { PinController.pin(s) } }
                                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                                Divider()
                                Button("Delete", role: .destructive) { try? FileManager.default.removeItem(at: url); items = History.items() }
                            }
                        }
                    }
                    .padding(12)
                }
            }
        }
        .frame(minWidth: 560, minHeight: 380)
        .onAppear { items = History.items() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in items = History.items() }
    }
}

@MainActor
enum LibraryWindow {
    private static var window: NSWindow?

    static func show() {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: LibraryView()))
            w.title = L("Snapix Library")
            w.styleMask = [.titled, .closable, .resizable, .miniaturizable]
            w.setContentSize(NSSize(width: 780, height: 520))
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
