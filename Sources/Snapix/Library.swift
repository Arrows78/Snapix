import AVFoundation
import AppKit
import ImageIO
import SwiftUI

/// One finished recording, remembered so the Library can list it next to the screenshots.
struct RecordingEntry: Codable, Equatable {
    var path: String
    var date: Date
}

/// The list of recordings (video and GIF files the user saved), kept beside the screenshot history.
enum RecordingLog {
    nonisolated static let limit = 300
    nonisolated static var defaultFile: URL { History.folderURL.appendingPathComponent("recordings.json") }

    private nonisolated static func read(_ file: URL) -> [RecordingEntry] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([RecordingEntry].self, from: data)) ?? []
    }

    private nonisolated static func write(_ entries: [RecordingEntry], to file: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? encoder.encode(entries) { try? data.write(to: file) }
    }

    /// Newest first, leaving out files that no longer exist.
    nonisolated static func all(from file: URL = defaultFile) -> [RecordingEntry] {
        read(file).filter { FileManager.default.fileExists(atPath: $0.path) }.sorted { $0.date > $1.date }
    }

    nonisolated static func add(_ url: URL, date: Date = Date(), to file: URL = defaultFile) {
        var list = read(file).filter { $0.path != url.path }
        list.append(RecordingEntry(path: url.path, date: date))
        write(Array(list.sorted { $0.date > $1.date }.prefix(limit)), to: file)
    }

    nonisolated static func remove(path: String, from file: URL = defaultFile) {
        write(read(file).filter { $0.path != path }, to: file)
    }

    /// First picture of a video or GIF, for thumbnails and Quick Access cards.
    nonisolated static func firstFrame(of url: URL, maxPixel: Int) async -> CGImage? {
        if url.pathExtension.lowercased() == "gif" { return History.thumbnail(for: url, maxPixel: maxPixel) }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        return try? await generator.image(at: .zero).image
    }
}

/// A screenshot or a recording as shown in the Library.
struct LibraryItem: Identifiable, Hashable {
    enum Kind { case screenshot, video, gif }
    let url: URL
    let kind: Kind
    let date: Date
    var id: URL { url }

    nonisolated static func kind(of url: URL) -> Kind {
        switch url.pathExtension.lowercased() {
        case "gif": return .gif
        case "mp4", "mov", "m4v": return .video
        default: return .screenshot
        }
    }

    /// Image and video types the Library lists when it indexes the screenshots folder.
    nonisolated static let folderExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tiff", "gif", "mp4", "mov", "m4v"]

    /// True for files Snapix keeps itself (its history); the others belong to the user and go to the Trash, never get deleted.
    nonisolated var isStored: Bool { url.path.hasPrefix(History.folderURL.path) }

    /// "20261107-231905-123@2x" -> its date.
    nonisolated static func date(ofHistoryFile url: URL) -> Date {
        let stamp = url.deletingPathExtension().lastPathComponent.components(separatedBy: "@").first ?? ""
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return f.date(from: stamp) ?? .distantPast
    }
}

enum LibraryFilter: String, CaseIterable {
    case all, screenshots, videos, gifs

    var title: String {
        switch self {
        case .all: return L("All")
        case .screenshots: return L("Screenshots")
        case .videos: return L("Videos")
        case .gifs: return L("GIFs")
        }
    }

    func includes(_ kind: LibraryItem.Kind) -> Bool {
        switch self {
        case .all: return true
        case .screenshots: return kind == .screenshot
        case .videos: return kind == .video
        case .gifs: return kind == .gif
        }
    }
}

@MainActor
enum LibraryItems {
    /// Screenshots and recordings together, newest first.
    static func load() -> [LibraryItem] {
        let shots = History.items().map { LibraryItem(url: $0, kind: .screenshot, date: LibraryItem.date(ofHistoryFile: $0)) }
        let recs = RecordingLog.all().map { e -> LibraryItem in
            let url = URL(fileURLWithPath: e.path)
            return LibraryItem(url: url, kind: LibraryItem.kind(of: url), date: e.date)
        }
        var all = shots + recs
        if Pref.bool("libraryIndexFolder") {
            let known = Set(all.map(\.url.path))
            all += folderItems(in: URL(fileURLWithPath: Pref.string("saveFolder"), isDirectory: true)).filter { !known.contains($0.url.path) }
        }
        return all.sorted { $0.date > $1.date }
    }

    /// Images and videos directly inside `folder` (not its sub-folders), newest 500, dated by their modification time.
    nonisolated static func folderItems(in folder: URL, limit: Int = 500) -> [LibraryItem] {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])) ?? []
        let items = files.filter { LibraryItem.folderExtensions.contains($0.pathExtension.lowercased()) }.map { url in
            LibraryItem(url: url, kind: LibraryItem.kind(of: url), date: (try? url.resourceValues(forKeys: Set(keys)).contentModificationDate) ?? .distantPast)
        }
        return Array(items.sorted { $0.date > $1.date }.prefix(limit))
    }
}

struct LibraryThumb: View {
    let item: LibraryItem
    var height: CGFloat = 120
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.12))
            if let image { Image(nsImage: image).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 6)).padding(4) }
        }
        .overlay(alignment: .bottomTrailing) {
            if item.kind != .screenshot {
                Label(item.kind == .gif ? "GIF" : "", systemImage: item.kind == .gif ? "photo.stack" : "play.fill")
                    .labelStyle(.titleAndIcon).font(.system(size: 10, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 3).background(Capsule().fill(Color.black.opacity(0.65))).padding(7)
            }
        }
        .frame(height: height)
        .task {
            let u = item.url, kind = item.kind
            let cg = await Task.detached { kind == .screenshot ? History.thumbnail(for: u, maxPixel: 480) : await RecordingLog.firstFrame(of: u, maxPixel: 480) }.value
            if let cg { image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)) }
        }
    }
}

private struct LibraryView: View {
    @State private var items = LibraryItems.load()
    @State private var query = ""
    @State private var index: [String: String] = TextIndex.load()
    @State private var indexing = false
    /// In the order the user clicked, which is the order images are combined in.
    @State private var selection: [URL] = []
    @AppStorage("combineGap") private var gap = 0
    @AppStorage("libraryFilter") private var filterRaw = LibraryFilter.all.rawValue

    private var filter: LibraryFilter { LibraryFilter(rawValue: filterRaw) ?? .all }

    /// Items passing the kind filter whose recognised text (or file name) contains every typed word.
    private var visible: [LibraryItem] {
        let byKind = items.filter { filter.includes($0.kind) }
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return byKind }
        return byKind.filter { TextIndex.matches(query, in: (index[$0.url.lastPathComponent] ?? "") + " " + $0.url.lastPathComponent) }
    }

    private var selectedItems: [LibraryItem] { selection.compactMap { u in items.first { $0.url == u } } }
    private var canCombine: Bool { selection.count >= 2 && selectedItems.allSatisfy { $0.kind == .screenshot } }

    private func reload() { items = LibraryItems.load() }

    private func refreshIndex() {
        let urls = items.filter { $0.kind == .screenshot }.map(\.url)
        guard !urls.isEmpty, !indexing, urls.contains(where: { index[$0.lastPathComponent] == nil }) else { return }
        indexing = true
        Task.detached(priority: .utility) {
            await TextIndex.build(for: urls) { dict in DispatchQueue.main.async { index = dict } }
            DispatchQueue.main.async { indexing = false }
        }
    }

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

    private func open(_ item: LibraryItem) {
        if item.kind == .screenshot { if let s = History.shot(for: item.url) { EditorWindowController.open(s) } }
        else { NSWorkspace.shared.open(item.url) }
    }

    private func remove(_ list: [LibraryItem]) {
        let recordings = list.filter { $0.kind != .screenshot || !$0.isStored }
        if !recordings.isEmpty {
            let alert = NSAlert()
            alert.messageText = LF("Move %d recording file(s) to the Trash?", recordings.count)
            alert.informativeText = L("The files you saved are moved to the Trash. Screenshots in the Library are deleted.")
            alert.alertStyle = .warning
            alert.addButton(withTitle: L("Move to Trash"))
            alert.addButton(withTitle: L("Cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        for item in list {
            if item.kind == .screenshot && item.isStored { try? FileManager.default.removeItem(at: item.url) }
            else { try? FileManager.default.trashItem(at: item.url, resultingItemURL: nil); RecordingLog.remove(path: item.url.path) }
        }
        selection.removeAll { u in list.contains { $0.url == u } }
        reload()
    }

    private func copyFile(_ url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([url as NSURL])
        Toast.show(L("Copied as file"), symbol: "checkmark.circle.fill")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("", selection: $filterRaw) { ForEach(LibraryFilter.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) } }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 300)
                TextField(L("Search text in screenshots"), text: $query).textFieldStyle(.roundedBorder).frame(width: 180)
                if indexing { ProgressView().controlSize(.small).help(L("Reading the text of your screenshots…")) }
                Spacer()
                Text(LF("%d item(s)", visible.count)).foregroundStyle(.secondary)
            }
            .padding(10)
            HStack(spacing: 8) {
                if !selection.isEmpty {
                    Text(LF("%d selected", selection.count)).foregroundStyle(.secondary)
                    Stepper(LF("Gap: %d px", gap), value: $gap, in: 0...200, step: 8).controlSize(.small)
                    Button("Combine Vertically") { combine(horizontal: false) }.disabled(!canCombine)
                    Button("Combine Horizontally") { combine(horizontal: true) }.disabled(!canCombine)
                    Button("Delete Selected", role: .destructive) { remove(selectedItems) }
                    Button("Deselect") { selection = [] }
                } else {
                    Button("Select All") { selection = visible.map(\.url) }.disabled(visible.isEmpty)
                }
                Spacer()
                Button("Reveal in Finder") { NSWorkspace.shared.open(History.folder) }
                Button("Clear All", role: .destructive) { History.clear(); reload() }.disabled(!items.contains { $0.kind == .screenshot })
            }
            .padding(.horizontal, 10).padding(.bottom, 8)
            Divider()
            if visible.isEmpty {
                Spacer()
                Text(items.isEmpty ? "Screenshots you take will appear here." : "No item matches your search or filter.").foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
                        ForEach(visible) { item in
                            VStack(spacing: 4) {
                                LibraryThumb(item: item)
                                    .overlay(alignment: .topLeading) {
                                        if let n = selection.firstIndex(of: item.url) {
                                            Text("\(n + 1)").font(.caption.bold()).foregroundStyle(.white)
                                                .frame(width: 20, height: 20).background(Circle().fill(Color.accentColor)).padding(6)
                                        }
                                    }
                                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor, lineWidth: selection.contains(item.url) ? 2 : 0))
                                Text(item.kind == .screenshot ? (item.url.deletingPathExtension().lastPathComponent.components(separatedBy: "@").first ?? "") : item.url.lastPathComponent)
                                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { open(item) }
                            .onTapGesture { toggle(item.url) }
                            .contextMenu {
                                if item.kind == .screenshot {
                                    Button("Open in Editor") { open(item) }
                                    Button("Copy") { if let s = History.shot(for: item.url) { Exporter.copy(s.image, scale: s.scale) } }
                                    Button("Pin") { if let s = History.shot(for: item.url) { PinController.pin(s) } }
                                } else {
                                    Button("Open") { open(item) }
                                    Button("Copy as File") { copyFile(item.url) }
                                }
                                Button("Open in Default App") { NSWorkspace.shared.open(item.url) }
                                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                                Divider()
                                Button(item.kind == .screenshot && item.isStored ? "Delete" : "Move to Trash", role: .destructive) { remove([item]) }
                            }
                        }
                    }
                    .padding(12)
                }
            }
        }
        .frame(minWidth: 640, minHeight: 400)
        .onAppear { reload(); refreshIndex() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in reload(); refreshIndex() }
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
            w.setContentSize(NSSize(width: 820, height: 560))
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
