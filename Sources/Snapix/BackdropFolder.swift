import Foundation

/// Pictures the user keeps in a folder to use as backdrops.
enum BackdropFolder {
    static let limit = 24
    static let extensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tiff", "webp"]

    /// Image files directly inside `folder`, sorted by name and capped at `limit`.
    static func images(in folder: URL) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return Array(files.filter { extensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }.prefix(limit))
    }
}
