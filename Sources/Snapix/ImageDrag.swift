import AppKit

/// Starts a drag session carrying the image as a temporary file, so it can be dropped into Finder, Mail, Slack…
@MainActor
enum ImageDrag {
    /// Drags an existing file (a recording) with its first frame as the drag image.
    static func beginFile(from view: NSView, source: NSDraggingSource, event: NSEvent, url: URL, preview: CGImage) {
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        let size = NSSize(width: 120, height: 120 * CGFloat(preview.height) / CGFloat(max(1, preview.width)))
        item.setDraggingFrame(NSRect(origin: .zero, size: size), contents: NSImage(cgImage: preview, size: size))
        view.beginDraggingSession(with: [item], event: event, source: source)
    }

    @discardableResult
    static func begin(from view: NSView, source: NSDraggingSource, event: NSEvent, image: CGImage, scale: CGFloat) -> Bool {
        let prepared = Exporter.prepared(image, scale: scale)
        guard let (data, ext) = Exporter.encode(prepared.image, forceLossless: Exporter.hasTransparency(prepared.image)) else { return false }
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("SnapixDrag", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(Exporter.filename(ext: ext))
        guard (try? data.write(to: url)) != nil else { return false }

        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        let size = NSSize(width: 120, height: 120 * CGFloat(image.height) / CGFloat(max(1, image.width)))
        item.setDraggingFrame(NSRect(origin: .zero, size: size), contents: NSImage(cgImage: image, size: size))
        view.beginDraggingSession(with: [item], event: event, source: source)
        return true
    }
}
