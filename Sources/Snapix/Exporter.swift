import AppKit
import UniformTypeIdentifiers

/// A captured image plus where it came from.
struct Shot {
    var image: CGImage
    /// Backing scale of the screen it was taken on (2 on Retina).
    var scale: CGFloat
    /// Position on screen in AppKit global coordinates, used to place pins where the capture happened.
    var screenRect: CGRect?
    /// True for region captures (area, repeat, scrolling): the floating preview appears where the region was, not in the screen corner.
    var placeAtRegion = false
    /// Where an area selection ended (AppKit global coordinates); the preview appears next to it.
    var anchorPoint: CGPoint?
}

@MainActor
enum Exporter {
    /// Applies the "downscale Retina" preference.
    static func prepared(_ image: CGImage, scale: CGFloat) -> (image: CGImage, scale: CGFloat) {
        guard Pref.bool("downscale"), scale > 1 else { return (image, scale) }
        let w = Int((CGFloat(image.width) / scale).rounded()), h = Int((CGFloat(image.height) / scale).rounded())
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: Renderer.sRGB,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return (image, scale) }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return (ctx.makeImage() ?? image, 1)
    }

    // MARK: Encoding

    /// Screenshots with gradients/photos compress better as JPEG; flat UI and text stays PNG.
    static func looksLikePhoto(_ image: CGImage) -> Bool {
        let side = 128
        var buf = [UInt8](repeating: 0, count: side * side * 4)
        guard let ctx = CGContext(data: &buf, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4, space: Renderer.sRGB,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.interpolationQuality = .none
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        var seen = Set<UInt32>()
        for i in stride(from: 0, to: buf.count, by: 4) {
            seen.insert((UInt32(buf[i] >> 4) << 8) | (UInt32(buf[i + 1] >> 4) << 4) | UInt32(buf[i + 2] >> 4))
        }
        return seen.count > 900
    }

    static func hasTransparency(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: return true
        }
    }

    static func encode(_ image: CGImage, forceLossless: Bool = false) -> (data: Data, ext: String)? {
        let rep = NSBitmapImageRep(cgImage: image)
        var useJPEG: Bool
        switch Pref.string("format") {
        case "png": useJPEG = false
        case "jpeg": useJPEG = true
        default: useJPEG = looksLikePhoto(image)
        }
        if forceLossless { useJPEG = false }
        if useJPEG {
            guard let d = rep.representation(using: .jpeg, properties: [.compressionFactor: Pref.double("jpegQuality")]) else { return nil }
            return (d, "jpg")
        }
        guard let d = rep.representation(using: .png, properties: [:]) else { return nil }
        return (d, "png")
    }

    // MARK: Destinations

    static func copy(_ image: CGImage, scale: CGFloat, quiet: Bool = false) {
        let (img, sc) = prepared(image, scale: scale)
        let nsImage = NSImage(cgImage: img, size: NSSize(width: CGFloat(img.width) / sc, height: CGFloat(img.height) / sc))
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([nsImage])
        if !quiet { Toast.show(L("Copied to the clipboard")) }
    }

    static func filename(ext: String, suffix: String = "") -> String {
        let now = Date()
        let d = DateFormatter(); d.dateFormat = "yyyy-MM-dd"
        let t = DateFormatter(); t.dateFormat = "HH.mm.ss"
        let name = Pref.string("filenameTemplate")
            .replacingOccurrences(of: "{date}", with: d.string(from: now))
            .replacingOccurrences(of: "{time}", with: t.string(from: now))
            .replacingOccurrences(of: "{timestamp}", with: String(Int(now.timeIntervalSince1970)))
            .replacingOccurrences(of: "/", with: "-")
        return "\(name)\(suffix).\(ext)"
    }

    static func uniqueURL(in folder: URL, name: String) -> URL {
        var url = folder.appendingPathComponent(name)
        let base = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base) \(n).\(ext)"); n += 1
        }
        return url
    }

    @discardableResult
    static func save(_ image: CGImage, scale: CGFloat, quiet: Bool = false) -> URL? {
        let (img, _) = prepared(image, scale: scale)
        guard let (data, ext) = encode(img, forceLossless: hasTransparency(img)) else { return nil }
        let folder = URL(fileURLWithPath: Pref.string("saveFolder"), isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = uniqueURL(in: folder, name: filename(ext: ext))
            try data.write(to: url)
            if !quiet { Toast.show(LF("Saved %@", url.lastPathComponent)) }
            return url
        } catch {
            Toast.show(LF("Could not save: %@", error.localizedDescription), duration: 3)
            return nil
        }
    }

    static func saveAs(_ image: CGImage, scale: CGFloat, window: NSWindow?) {
        let (img, _) = prepared(image, scale: scale)
        guard let (data, ext) = encode(img, forceLossless: hasTransparency(img)) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [ext == "png" ? .png : .jpeg]
        panel.nameFieldStringValue = filename(ext: ext)
        panel.directoryURL = URL(fileURLWithPath: Pref.string("saveFolder"))
        let finish: (NSApplication.ModalResponse) -> Void = { resp in
            guard resp == .OK, let url = panel.url else { return }
            do { try data.write(to: url); Toast.show(LF("Saved %@", url.lastPathComponent)) }
            catch { Toast.show(LF("Could not save: %@", error.localizedDescription), duration: 3) }
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: finish) } else { finish(panel.runModal()) }
    }

    /// Multipart POST to the user-configured endpoint; the returned URL (plain text or JSON `url`) lands on the clipboard.
    static func upload(_ image: CGImage, scale: CGFloat) {
        let endpoint = Pref.string("uploadURL").trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: endpoint), url.scheme?.hasPrefix("http") == true else {
            Toast.show(L("Set an upload URL in Preferences › Upload first"), duration: 3)
            return
        }
        let (img, _) = prepared(image, scale: scale)
        guard let (data, ext) = encode(img, forceLossless: hasTransparency(img)) else { return }
        let field = Pref.string("uploadField").isEmpty ? "file" : Pref.string("uploadField")
        let auth = Pref.string("uploadAuthHeader")

        let boundary = "snapix-\(UUID().uuidString)"
        var body = Data()
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(field)\"; filename=\"\(filename(ext: ext))\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(ext == "png" ? "image/png" : "image/jpeg")\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if !auth.isEmpty { req.setValue(auth, forHTTPHeaderField: "Authorization") }
        req.httpBody = body

        Toast.show(L("Uploading…"), duration: 30)
        URLSession.shared.dataTask(with: req) { data, resp, error in
            DispatchQueue.main.async {
                let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
                guard error == nil, (200..<300).contains(status), let data else {
                    Toast.show(LF("Upload failed (%@)", error?.localizedDescription ?? "HTTP \(status)"), duration: 3)
                    return
                }
                var link = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let u = json["url"] as? String { link = u }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(link, forType: .string)
                Toast.show(link.isEmpty ? L("Uploaded") : LF("Link copied: %@", link), duration: 3)
            }
        }.resume()
    }
}
