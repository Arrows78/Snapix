import AppKit
import ImageIO
import SwiftUI

/// Every capture is kept as a PNG under Application Support so the Library can reopen it later.
@MainActor
enum History {
    /// Most captures kept in the Library: the "historyLimit" preference (-1 = no limit), 200 by default.
    nonisolated static var limit: Int {
        let v = UserDefaults.standard.integer(forKey: "historyLimit")
        return v == 0 ? 200 : (v < 0 ? Int.max : v)
    }

    nonisolated static var folderURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Snapix/History", isDirectory: true)
    }

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
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])
            .filter({ $0.pathExtension == "png" }).sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) else { return }
        for old in files.dropFirst(limit) { try? FileManager.default.removeItem(at: old) }
        let days = UserDefaults.standard.integer(forKey: "historyRetentionDays")
        guard days > 0, let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) else { return }
        for url in files.prefix(limit) {
            if let d = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate, d < cutoff {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    /// Applies the retention preference without waiting for the next capture (called at launch).
    static func pruneNow() {
        let dir = folder
        DispatchQueue.global(qos: .utility).async { prune(in: dir) }
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
        return Shot(image: img, scale: scale(of: url), screenRect: nil, historyURL: url)
    }

    nonisolated static func thumbnail(for url: URL, maxPixel: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(src, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ] as CFDictionary)
    }

    static func totalBytes() -> Int {
        items().reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    static func clear() { items().forEach { try? FileManager.default.removeItem(at: $0) }; TextIndex.clear() }
}

/// Text found in each Library screenshot, so the Library can be searched. Stored next to the images and built in the background.
enum TextIndex {
    private static var file: URL { History.folderURL.appendingPathComponent("index.json") }

    nonisolated static func load() -> [String: String] {
        guard let data = try? Data(contentsOf: History.folderURL.appendingPathComponent("index.json")),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return dict
    }

    nonisolated static func save(_ dict: [String: String]) {
        if let data = try? JSONEncoder().encode(dict) { try? data.write(to: History.folderURL.appendingPathComponent("index.json")) }
    }

    static func clear() { try? FileManager.default.removeItem(at: file) }

    /// True when every word of `query` appears in `text`, ignoring case and accents.
    nonisolated static func matches(_ query: String, in text: String) -> Bool {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return true }
        let opts: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        return words.allSatisfy { text.range(of: $0, options: opts) != nil }
    }

    /// Recognises the text of every screenshot missing from the index, saving after each one; `onUpdate` receives the fresh index.
    nonisolated static func build(for urls: [URL], onUpdate: @escaping @Sendable ([String: String]) -> Void) async {
        var dict = load()
        let existing = Set(urls.map(\.lastPathComponent))
        dict = dict.filter { existing.contains($0.key) }
        for url in urls where dict[url.lastPathComponent] == nil {
            if Task.isCancelled { break }
            let text = History.thumbnail(for: url, maxPixel: 1800).map { OCR.plainText(of: $0, fast: true) } ?? ""
            dict[url.lastPathComponent] = text
            save(dict)
            onUpdate(dict)
        }
        save(dict)
        onUpdate(dict)
    }
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
    @State private var query = ""
    @State private var index: [String: String] = TextIndex.load()
    @State private var indexing = false

    /// Screenshots whose recognised text (or date stamp) contains every word typed in the search field.
    private var visible: [URL] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return items }
        return items.filter { TextIndex.matches(query, in: (index[$0.lastPathComponent] ?? "") + " " + $0.lastPathComponent) }
    }

    private func refreshIndex() {
        let urls = items
        guard !urls.isEmpty, !indexing, urls.contains(where: { index[$0.lastPathComponent] == nil }) else { return }
        indexing = true
        Task.detached(priority: .utility) {
            await TextIndex.build(for: urls) { dict in DispatchQueue.main.async { index = dict } }
            DispatchQueue.main.async { indexing = false }
        }
    }
    /// In the order the user clicked, which is the order images are combined in.
    @State private var selection: [URL] = []
    @AppStorage("combineGap") private var gap = 0

    private func combine(horizontal: Bool) {
        let images = selection.compactMap { History.shot(for: $0)?.image }
        guard let img = Combine.images(images, horizontal: horizontal, spacing: gap) else { return }
        let scale = selection.first.map(History.scale(of:)) ?? 1
        EditorWindowController.open(Shot(image: img, scale: scale, screenRect: nil))
        selection = []
    }

    private func toggle(_ url: URL) {
        if let i = selection.firstIndex(of: url) { selection.remove(at: i) } else { selection.append(url) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(LF("%d screenshot(s)", items.count)).foregroundStyle(.secondary)
                TextField(L("Search text in screenshots"), text: $query).textFieldStyle(.roundedBorder).frame(width: 200)
                if indexing { ProgressView().controlSize(.small).help(L("Reading the text of your screenshots…")) }
                Spacer()
                if !selection.isEmpty {
                    Text(LF("%d selected", selection.count)).foregroundStyle(.secondary)
                    Stepper(LF("Gap: %d px", gap), value: $gap, in: 0...200, step: 8).controlSize(.small)
                    Button("Combine Vertically") { combine(horizontal: false) }.disabled(selection.count < 2)
                    Button("Combine Horizontally") { combine(horizontal: true) }.disabled(selection.count < 2)
                    Button("Delete Selected", role: .destructive) {
                        selection.forEach { try? FileManager.default.removeItem(at: $0) }
                        selection = []
                        items = History.items()
                    }
                    Button("Deselect") { selection = [] }
                }
                Button("Reveal in Finder") { NSWorkspace.shared.open(History.folder) }
                Button("Clear All", role: .destructive) { History.clear(); items = [] }.disabled(items.isEmpty)
            }
            .padding(10)
            Divider()
            if items.isEmpty || visible.isEmpty {
                Spacer(); Text(items.isEmpty ? "Screenshots you take will appear here." : "No screenshot matches your search.").foregroundStyle(.secondary); Spacer()
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
                        ForEach(visible, id: \.self) { url in
                            VStack(spacing: 4) {
                                Thumb(url: url)
                                    .overlay(alignment: .topLeading) {
                                        if let n = selection.firstIndex(of: url) {
                                            Text("\(n + 1)").font(.caption.bold()).foregroundStyle(.white)
                                                .frame(width: 20, height: 20).background(Circle().fill(Color.accentColor)).padding(6)
                                        }
                                    }
                                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor, lineWidth: selection.contains(url) ? 2 : 0))
                                Text(url.deletingPathExtension().lastPathComponent.components(separatedBy: "@").first ?? "")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { if let s = History.shot(for: url) { EditorWindowController.open(s) } }
                            .onTapGesture { toggle(url) }
                            .contextMenu {
                                Button("Open in Editor") { if let s = History.shot(for: url) { EditorWindowController.open(s) } }
                                Button("Copy") { if let s = History.shot(for: url) { Exporter.copy(s.image, scale: s.scale) } }
                                Button("Pin") { if let s = History.shot(for: url) { PinController.pin(s) } }
                                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                                Divider()
                                Button("Delete", role: .destructive) { try? FileManager.default.removeItem(at: url); selection.removeAll { $0 == url }; items = History.items() }
                            }
                        }
                    }
                    .padding(12)
                }
            }
        }
        .frame(minWidth: 560, minHeight: 380)
        .onAppear { items = History.items(); refreshIndex() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in items = History.items(); refreshIndex() }
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
