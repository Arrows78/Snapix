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
