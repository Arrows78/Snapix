import AppKit

/// Starts a drag session carrying the image as a temporary file, so it can be dropped into Finder, Mail, Slack…
@MainActor
enum ImageDrag {
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
