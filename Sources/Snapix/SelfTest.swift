import AppKit
import CoreMedia

/// `Snapix --selftest <outdir>` exercises the non-interactive pieces (render, stitching, contrast) and exits.
@MainActor
enum SelfTest {
    static func run(outDir: String) -> Int32 {
        var failures = 0
        func check(_ ok: Bool, _ name: String) { print(ok ? "PASS" : "FAIL", name); if !ok { failures += 1 } }

        // Synthetic "page": 400 x 3000 with distinct rows.
        func page(rows: Range<Int>) -> CGImage {
            let w = 400, h = rows.count
            let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: Renderer.sRGB,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            for (i, row) in rows.enumerated() {
                let r = CGFloat((row * 37) % 255) / 255, g = CGFloat((row * 91) % 255) / 255, b = CGFloat((row / 7 * 53) % 255) / 255
                ctx.setFillColor(CGColor(srgbRed: r, green: g, blue: b, alpha: 1))
                ctx.fill(CGRect(x: 0, y: h - 1 - i, width: w, height: 1))
                ctx.setFillColor(CGColor(srgbRed: b, green: r, blue: g, alpha: 1))
                ctx.fill(CGRect(x: (row * 13) % 380, y: h - 1 - i, width: 10, height: 1))
            }
            return ctx.makeImage()!
        }
        let frameH = 500
        let stitcher = Stitcher(first: page(rows: 0..<frameH))!
        var y = 0
        for step in [200, 180, 220, 150] {
            y += step
            if case .appended(let d) = stitcher.add(page(rows: y..<(y + frameH))) { check(d == step, "stitch offset \(step) -> \(d)") }
            else { check(false, "stitch step \(step)") }
        }
        check(stitcher.height == frameH + y, "stitched height \(stitcher.height) == \(frameH + y)")
        if case .noChange = stitcher.add(page(rows: y..<(y + frameH))) { check(true, "detects end of scroll") } else { check(false, "detects end of scroll") }
        if let img = stitcher.result() {
            let expected = page(rows: 0..<(frameH + y))
            check(PixelBuffer(img)?.color(x: 5, y: 1234)?.hexValue == PixelBuffer(expected)?.color(x: 5, y: 1234)?.hexValue, "stitched pixels identical")
        }

        // Preview of the stitched result: the tail of a downward scroll, the head of an upward one.
        if let tail = stitcher.preview(rows: 50, fromTop: false), let whole = stitcher.result() {
            check(tail.height == 50 && tail.width == whole.width && PixelBuffer(tail)?.color(x: 5, y: 49)?.hexValue == PixelBuffer(whole)?.color(x: 5, y: whole.height - 1)?.hexValue, "scroll preview shows the latest rows")
        } else { check(false, "scroll preview") }

        // Scrolling upwards: start at the bottom of the page and move towards the top.
        let upStitcher = Stitcher(first: page(rows: 1000..<(1000 + frameH)))!
        var top = 1000
        for step in [200, 170, 230] {
            top -= step
            if case .appended(let d) = upStitcher.add(page(rows: top..<(top + frameH)), up: true) { check(d == step, "stitch up offset \(step) -> \(d)") }
            else { check(false, "stitch up step \(step)") }
        }
        check(upStitcher.height == frameH + 1000 - top, "stitched-up height \(upStitcher.height)")
        if let img = upStitcher.result() {
            let expected = page(rows: top..<(1000 + frameH))
            check(PixelBuffer(img)?.color(x: 7, y: 321)?.hexValue == PixelBuffer(expected)?.color(x: 7, y: 321)?.hexValue, "stitched-up pixels identical")
        }
        if case .noMatch = Stitcher(first: page(rows: 0..<frameH))!.add(page(rows: 2000..<(2000 + frameH))) { check(true, "unrelated frame rejected") }
        else { check(false, "unrelated frame rejected") }

        // Settings backup round trip, in a throwaway defaults suite.
        let suite = UserDefaults(suiteName: "snapix.selftest")!
        suite.removePersistentDomain(forName: "snapix.selftest")
        suite.set("png", forKey: "format"); suite.set("secret", forKey: "uploadAuthHeader"); suite.set(1, forKey: "unrelated")
        if let data = Pref.backupData(from: suite) {
            let other = UserDefaults(suiteName: "snapix.selftest2")!
            other.removePersistentDomain(forName: "snapix.selftest2")
            check(Pref.restore(data, into: other) == 1, "backup restores only known keys")
            check(other.string(forKey: "format") == "png" && other.string(forKey: "uploadAuthHeader") == nil, "backup omits the upload credential")
            other.removePersistentDomain(forName: "snapix.selftest2")
        } else { check(false, "backup encodes") }
        check(Pref.restore(Data("nope".utf8)) == nil, "backup rejects garbage")
        suite.removePersistentDomain(forName: "snapix.selftest")

        // Version comparison for the update check.
        check(UpdateCheck.isNewer("v1.2.0", than: "1.1.9") && UpdateCheck.isNewer("1.10", than: "1.9.5") && UpdateCheck.isNewer("2", than: "1.9"), "update: newer versions")
        check(!UpdateCheck.isNewer("v1.0.0", than: "1.0.0") && !UpdateCheck.isNewer("1.0", than: "1.0.1") && !UpdateCheck.isNewer("v1.0.0-beta", than: "1.0.0"), "update: same or older versions")

        // Rotation and mirroring.
        let strip = page(rows: 0..<100) // 400 wide, 100 tall
        if let cw = ImageTransform.rotated(strip, clockwise: true) {
            check(cw.width == 100 && cw.height == 400, "rotate swaps dimensions")
            check(PixelBuffer(cw)?.color(x: 99, y: 5)?.hexValue == PixelBuffer(strip)?.color(x: 5, y: 0)?.hexValue, "rotate clockwise moves top-left to top-right")
        } else { check(false, "rotate clockwise") }
        if let ccw = ImageTransform.rotated(strip, clockwise: false) {
            check(PixelBuffer(ccw)?.color(x: 0, y: 394)?.hexValue == PixelBuffer(strip)?.color(x: 5, y: 0)?.hexValue, "rotate counter-clockwise moves top-left to bottom-left")
        } else { check(false, "rotate counter-clockwise") }
        if let fh = ImageTransform.flipped(strip, horizontal: true), let fv = ImageTransform.flipped(strip, horizontal: false) {
            check(PixelBuffer(fh)?.color(x: 394, y: 3)?.hexValue == PixelBuffer(strip)?.color(x: 5, y: 3)?.hexValue, "flip horizontal")
            check(PixelBuffer(fv)?.color(x: 5, y: 96)?.hexValue == PixelBuffer(strip)?.color(x: 5, y: 3)?.hexValue, "flip vertical")
        } else { check(false, "flip") }

        // Backdrop aspect ratio.
        var ds = DocState(image: strip)
        ds.backdrop = BackdropConfig(enabled: true, padding: 10)
        ds.backdrop.ratio = 1
        let sq = Renderer.canvasSize(ds)
        check(sq.width == sq.height && sq.width == 420, "backdrop 1:1 canvas \(sq)")
        check(Renderer.origin(ds) == CGPoint(x: 10, y: 160), "backdrop keeps the screenshot centred \(Renderer.origin(ds))")
        ds.backdrop.ratio = 16.0 / 9
        let wide = Renderer.canvasSize(ds)
        check(abs(wide.width / wide.height - 16.0 / 9) < 0.01 && wide.height >= 120, "backdrop 16:9 canvas \(wide)")

        // Glow and pattern sample, written for a visual check.
        do {
            var gs = DocState(image: page(rows: 0..<240))
            gs.backdrop = BackdropConfig(enabled: true, padding: 70, innerRadius: 14)
            gs.backdrop.glow = true; gs.backdrop.pattern = 1; gs.backdrop.tape = 3; gs.backdrop.ratio = 16.0 / 9
            if let img = Renderer.render(gs) { write(img, "\(outDir)/glow.png"); check(img.width > 400, "glow backdrop renders") }
        }

        // Window frame adds a title bar above the screenshot.
        var wf = DocState(image: strip)
        wf.backdrop = BackdropConfig(enabled: true, padding: 10)
        let plainSize = Renderer.canvasSize(wf)
        wf.backdrop.windowFrame = true
        let bar = Renderer.chromeHeight(wf)
        check(bar >= 28 && Renderer.canvasSize(wf).height == plainSize.height + bar, "window frame grows the canvas by the bar height")
        check(Renderer.origin(wf).y == 10 + bar, "window frame pushes the screenshot below the bar")
        if let img = Renderer.render(wf), let px = PixelBuffer(img) {
            check(px.color(x: Int(plainSize.width) - 20, y: 10 + Int(bar) / 2)?.hexValue == 0x2B2B2F, "title bar is drawn")
        } else { check(false, "window frame render") }
        let old = Data(#"{"enabled":true,"padding":64,"innerRadius":12,"outerRadius":0,"shadow":true,"gradient":true,"fromHex":1,"toHex":2,"angle":45,"radial":false}"#.utf8)
        check((try? JSONDecoder().decode(BackdropConfig.self, from: old))?.windowFrame == nil, "old backdrop settings still decode")

        // Trimming uniform borders.
        let framed = CGContext(data: nil, width: 120, height: 80, bitsPerComponent: 8, bytesPerRow: 0, space: Renderer.sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        framed.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)); framed.fill(CGRect(x: 0, y: 0, width: 120, height: 80))
        framed.setFillColor(CGColor(srgbRed: 0.1, green: 0.2, blue: 0.8, alpha: 1)); framed.fill(CGRect(x: 30, y: 20, width: 50, height: 40))
        check(PixelBuffer(framed.makeImage()!)?.contentBounds() == CGRect(x: 30, y: 20, width: 50, height: 40), "content bounds found")
        let flatCtx = CGContext(data: nil, width: 10, height: 10, bitsPerComponent: 8, bytesPerRow: 0, space: Renderer.sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        flatCtx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)); flatCtx.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
        check(PixelBuffer(flatCtx.makeImage()!)?.contentBounds() == nil, "flat image has no content bounds")

        // Recording size cap.
        check(Recorder.capped(width: 3840, height: 2160, limit: "1080") == (1920, 1080) && Recorder.capped(width: 1280, height: 720, limit: "1080") == (1280, 720)
              && Recorder.capped(width: 3000, height: 2000, limit: "native") == (3000, 2000), "recording size cap")
        UserDefaults.standard.set("heic", forKey: "format")
        check(Exporter.encode(strip)?.ext == "heic", "HEIC encoding")
        UserDefaults.standard.removeObject(forKey: "format")

        // Empty space around an image.
        if let ex = ImageTransform.expanded(strip, top: 5, right: 7, bottom: 3, left: 2, fill: CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)) {
            check(ex.width == 409 && ex.height == 108, "expand size \(ex.width)x\(ex.height)")
            check(PixelBuffer(ex)?.color(x: 2 + 5, y: 5 + 3)?.hexValue == PixelBuffer(strip)?.color(x: 5, y: 3)?.hexValue, "expand keeps content offset")
            check(PixelBuffer(ex)?.color(x: 0, y: 0)?.hexValue == 0xFF0000, "expand fills the margin")
        } else { check(false, "expand") }

        // Watermark.
        UserDefaults.standard.set(true, forKey: "watermarkEnabled"); UserDefaults.standard.set("© Test", forKey: "watermarkText")
        UserDefaults.standard.set("bottomRight", forKey: "watermarkPosition")
        let plainBase = page(rows: 0..<100)
        let stamped = Watermark.apply(to: plainBase)
        var changedInCorner = false, changedElsewhere = false
        if let a = PixelBuffer(plainBase), let b = PixelBuffer(stamped) {
            for y in 0..<100 { for x in 0..<400 where a.color(x: x, y: y)?.hexValue != b.color(x: x, y: y)?.hexValue {
                if x > 200 && y > 60 { changedInCorner = true } else { changedElsewhere = true }
            } }
        }
        check(changedInCorner && !changedElsewhere, "watermark marks only the bottom-right corner")
        UserDefaults.standard.set(false, forKey: "watermarkEnabled")
        check(Watermark.apply(to: plainBase) === plainBase, "disabled watermark leaves the image untouched")
        UserDefaults.standard.removeObject(forKey: "watermarkEnabled"); UserDefaults.standard.removeObject(forKey: "watermarkText")

        // Backdrop pattern decoding.
        check((try? JSONDecoder().decode(BackdropConfig.self, from: old))?.pattern == nil, "old backdrop settings have no pattern")

        // Recording pauses.
        var clock = PauseClock()
        let t0 = clock.map(video: CMTime(seconds: 10, preferredTimescale: 600))
        let t1 = clock.map(video: CMTime(seconds: 10.033, preferredTimescale: 600))
        clock.pause()
        check(clock.map(audio: CMTime(seconds: 12, preferredTimescale: 600)) == nil, "audio dropped while paused")
        clock.resume()
        check(clock.map(audio: CMTime(seconds: 20, preferredTimescale: 600)) == nil, "audio dropped until the first frame after resume")
        let t2 = clock.map(video: CMTime(seconds: 20, preferredTimescale: 600))
        check(abs(t0.seconds - 10) < 0.002 && abs(t1.seconds - 10.033) < 0.002, "frames before a pause keep their time (\(t0.seconds), \(t1.seconds))")
        check(abs(t2.seconds - 10.066) < 0.002, "first frame after a pause follows the last one (\(t2.seconds))")
        check(abs((clock.map(audio: CMTime(seconds: 20.5, preferredTimescale: 600))?.seconds ?? 0) - 10.566) < 0.002, "audio shifted by the same gap")

        // Keystroke labels.
        check(KeystrokeFormat.label(keyCode: 8, characters: "c", flags: [.command]) == "⌘C", "keystroke ⌘C")
        check(KeystrokeFormat.label(keyCode: 124, characters: nil, flags: [.shift, .option]) == "⌥⇧→", "keystroke modifiers and arrow")
        check(KeystrokeFormat.label(keyCode: 0, characters: "a", flags: []) == "a" && KeystrokeFormat.label(keyCode: 49, characters: " ", flags: []) == "Space", "keystroke plain keys")

        // Links in recognised text.
        check(OCR.links(in: "see https://example.com/a and www.example.org, mail me@x.io, https://example.com/a").map(\.absoluteString) == ["https://example.com/a", "https://www.example.org"], "OCR links")

        // Library limit preference.
        UserDefaults.standard.set(-1, forKey: "historyLimit"); check(History.limit == Int.max, "history: no limit")
        UserDefaults.standard.set(50, forKey: "historyLimit"); check(History.limit == 50, "history: custom limit")
        UserDefaults.standard.removeObject(forKey: "historyLimit"); check(History.limit == 200, "history: default limit")

        // Crop ratio.
        let bnds = CGRect(x: 0, y: 0, width: 400, height: 300)
        check(CropGeometry.rect(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 210, y: 200), ratio: nil, bounds: bnds) == CGRect(x: 10, y: 10, width: 200, height: 190), "crop free")
        check(CropGeometry.rect(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 210, y: 200), ratio: 1, bounds: bnds) == CGRect(x: 10, y: 10, width: 190, height: 190), "crop 1:1")
        check(CropGeometry.rect(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 20, y: 20), ratio: 2, bounds: bnds) == CGRect(x: 20, y: 60, width: 80, height: 40), "crop 2:1 dragged up-left")
        let clamped = CropGeometry.rect(from: CGPoint(x: 350, y: 250), to: CGPoint(x: 900, y: 900), ratio: 16.0 / 9, bounds: bnds)
        check(bnds.contains(clamped) && abs(clamped.width / clamped.height - 16.0 / 9) < 0.01, "crop stays inside the image at the ratio")
        let refit = CropGeometry.refit(CGRect(x: 50, y: 50, width: 200, height: 100), ratio: 1, bounds: bnds)
        check(refit.width == refit.height && bnds.contains(refit) && abs(refit.midX - 150) < 1, "crop refit keeps the centre")

        // Backdrop presets.
        let bs = UserDefaults(suiteName: "snapix.selftest5")!
        bs.removePersistentDomain(forName: "snapix.selftest5")
        var cfgA = BackdropConfig(); cfgA.padding = 99; cfgA.pattern = 2
        BackdropPreset.save(BackdropPreset(name: "A", config: cfgA), in: bs)
        BackdropPreset.save(BackdropPreset(name: "A", config: BackdropConfig()), in: bs)
        check(BackdropPreset.saved(in: bs).count == 1 && BackdropPreset.saved(in: bs)[0].config.padding == 64, "backdrop preset replaced by name")
        for i in 0..<BackdropPreset.limit { BackdropPreset.save(BackdropPreset(name: "P\(i)", config: cfgA), in: bs) }
        check(BackdropPreset.saved(in: bs).count == BackdropPreset.limit, "backdrop preset limit")
        check(!BackdropPreset.save(BackdropPreset(name: "extra", config: cfgA), in: bs), "backdrop preset over the limit refused")
        BackdropPreset.delete(named: "P0", in: bs)
        check(BackdropPreset.saved(in: bs).count == BackdropPreset.limit - 1 && BackdropPreset.saved(in: bs).first(where: { $0.name == "P1" })?.config.pattern == 2, "backdrop preset delete keeps the others")
        bs.removePersistentDomain(forName: "snapix.selftest5")

        // Overlay and click ring preferences stay in range.
        UserDefaults.standard.set(5.0, forKey: "clickSize"); UserDefaults.standard.set(0.0, forKey: "clickDuration")
        UserDefaults.standard.set(2.0, forKey: "overlayDim")
        check(ClickStyle.current.size == 24 && ClickStyle.current.duration == 0.2 && Overlay.dim == 0.8, "overlay preferences are clamped")
        ["clickSize", "clickDuration", "overlayDim"].forEach { UserDefaults.standard.removeObject(forKey: $0) }
        check(ClickStyle.current == ClickStyle() && Overlay.dim == 0.4, "overlay preferences default")

        // Camera bubble placement.
        let area = CGRect(x: 100, y: 200, width: 800, height: 600)
        check(CameraBubble.frame(side: 180, corner: "bottomRight", in: area) == CGRect(x: 704, y: 216, width: 180, height: 180), "camera bottom right")
        check(CameraBubble.frame(side: 180, corner: "topLeft", in: area) == CGRect(x: 116, y: 604, width: 180, height: 180), "camera top left")
        check(CameraBubble.side(for: "small") == 120 && CameraBubble.side(for: "large") == 260 && CameraBubble.side(for: "x") == 180, "camera sizes")

        // Review speed.
        check(RecordingReview.outputDuration(range: 10, speed: 2) == 5 && RecordingReview.outputDuration(range: 10, speed: 0.5) == 20 && RecordingReview.outputDuration(range: 10, speed: 0) == 10, "review output duration")

        // Library text search.
        check(TextIndex.matches("invoice total", in: "Facture\nInvoice no. 42\nTotal: 10") && !TextIndex.matches("invoice refund", in: "Invoice no. 42"), "text search needs every word")
        check(TextIndex.matches("  ", in: "anything") && !TextIndex.matches("absent", in: "some text") && TextIndex.matches("cafe", in: "Café du coin"), "text search is case and accent insensitive")
        let ocrImage = CGContext(data: nil, width: 600, height: 120, bitsPerComponent: 8, bytesPerRow: 0, space: Renderer.sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ocrImage.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)); ocrImage.fill(CGRect(x: 0, y: 0, width: 600, height: 120))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ocrImage, flipped: false)
        NSAttributedString(string: "Snapix invoice 2026", attributes: [.font: NSFont.systemFont(ofSize: 56, weight: .bold), .foregroundColor: NSColor.black]).draw(at: NSPoint(x: 20, y: 30))
        NSGraphicsContext.restoreGraphicsState()
        check(TextIndex.matches("invoice", in: OCR.plainText(of: ocrImage.makeImage()!, fast: true)), "OCR reads rendered text")

        // Contact sheet of the icon family, for a visual check.
        do {
            let tools = Tool.allCases
            let cell = 80, cols = 9, rows = (tools.count + 2 + cols - 1) / cols
            if let sheet = CGContext(data: nil, width: cell * cols, height: cell * rows, bitsPerComponent: 8, bytesPerRow: 0, space: Renderer.sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                sheet.setFillColor(CGColor(srgbRed: 0.145, green: 0.145, blue: 0.157, alpha: 1)); sheet.fill(CGRect(x: 0, y: 0, width: cell * cols, height: cell * rows))
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: sheet, flipped: false)
                let images = tools.map { ToolGlyph.image(for: $0) } + [ToolGlyph.backdrop, ToolGlyph.more]
                for (i, img) in images.enumerated() {
                    let r = NSRect(x: (i % cols) * cell + 10, y: (rows - 1 - i / cols) * cell + 10, width: 60, height: 60)
                    let tinted = NSImage(size: img.size, flipped: false) { rect in
                        img.draw(in: rect); NSColor.white.withAlphaComponent(0.9).setFill(); rect.fill(using: .sourceAtop); return true }
                    tinted.draw(in: r)
                }
                NSGraphicsContext.restoreGraphicsState()
                if let img = sheet.makeImage() { write(img, "\(outDir)/glyphs.png") }
            }
        }

        // Highlight snapping.
        let lineBox = CGRect(x: 100, y: 200, width: 300, height: 20)
        let sn = HighlightSnap.snapped(stroke: CGRect(x: 120, y: 195, width: 200, height: 30), boxes: [CGRect(x: 100, y: 300, width: 300, height: 20), lineBox])
        check(sn?.points == [CGPoint(x: 120, y: 210), CGPoint(x: 320, y: 210)] && abs((sn?.width ?? 0) - 23) < 0.01, "highlight snaps to the matching line")
        check(HighlightSnap.snapped(stroke: CGRect(x: 0, y: 0, width: 50, height: 10), boxes: [lineBox]) == nil, "highlight far from text is left alone")

        // Auto-balance.
        let bal = BackdropConfig().balanced(for: CGSize(width: 1000, height: 600))
        check(bal.enabled && bal.padding == 48 && bal.innerRadius == 7 && bal.shadow && bal.ratio == nil, "auto-balance proportions")
        check(BackdropConfig().balanced(for: CGSize(width: 40, height: 40)).padding == 24, "auto-balance minimum padding")

        // Recording log.
        let logFile = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("snapix-rec-\(UUID().uuidString).json")
        let recA = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("snapix-a-\(UUID().uuidString).mp4")
        let recB = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("snapix-b-\(UUID().uuidString).gif")
        FileManager.default.createFile(atPath: recA.path, contents: Data([0])); FileManager.default.createFile(atPath: recB.path, contents: Data([0]))
        RecordingLog.add(recA, date: Date(timeIntervalSince1970: 1000), to: logFile)
        RecordingLog.add(recB, date: Date(timeIntervalSince1970: 2000), to: logFile)
        check(RecordingLog.all(from: logFile).map(\.path) == [recB.path, recA.path], "recording log lists newest first")
        try? FileManager.default.removeItem(at: recA)
        check(RecordingLog.all(from: logFile).map(\.path) == [recB.path], "recording log hides missing files")
        RecordingLog.remove(path: recB.path, from: logFile)
        check(RecordingLog.all(from: logFile).isEmpty, "recording log remove")
        try? FileManager.default.removeItem(at: recB); try? FileManager.default.removeItem(at: logFile)
        check(LibraryItem.kind(of: URL(fileURLWithPath: "/x/a.mp4")) == .video && LibraryItem.kind(of: URL(fileURLWithPath: "/x/a.GIF")) == .gif && LibraryItem.kind(of: URL(fileURLWithPath: "/x/a.png")) == .screenshot, "library item kinds")
        check(LibraryFilter.videos.includes(.video) && !LibraryFilter.videos.includes(.gif) && LibraryFilter.all.includes(.screenshot), "library filters")

        // Per-tool style memory.
        let ts = UserDefaults(suiteName: "snapix.selftest6")!
        ts.removePersistentDomain(forName: "snapix.selftest6")
        ToolStyle.save(ToolStyle(hex: 0x123456, width: 9, arrowStyle: 2, dashed: true), for: .arrow, in: ts)
        check(ToolStyle.load(.arrow, from: ts)?.hex == 0x123456 && ToolStyle.load(.arrow, from: ts)?.dashed == true && ToolStyle.load(.rect, from: ts) == nil, "tool style memory per tool")
        check(ToolStyle.remembers(.arrow) && !ToolStyle.remembers(.crop) && !ToolStyle.remembers(.select), "tool style memory skips crop and select")
        ToolStyle.forget(in: ts)
        check(ToolStyle.load(.arrow, from: ts) == nil, "tool style forget")
        ts.removePersistentDomain(forName: "snapix.selftest6")

        // Tape and wallpapers.
        var tp = DocState(image: page(rows: 0..<200))
        tp.backdrop = BackdropConfig(enabled: true, padding: 60, innerRadius: 0, shadow: false, gradient: false)
        let noTape = Renderer.render(tp)
        tp.backdrop.tape = 1
        let withTape = Renderer.render(tp)
        var tapeChanged = false, farChanged = false
        if let a = noTape.flatMap(PixelBuffer.init), let b = withTape.flatMap(PixelBuffer.init) {
            for y in 40..<110 { for x in 40..<120 where a.color(x: x, y: y)?.hexValue != b.color(x: x, y: y)?.hexValue { tapeChanged = true } }
            for y in 150..<190 { for x in 150..<250 where a.color(x: x, y: y)?.hexValue != b.color(x: x, y: y)?.hexValue { farChanged = true } }
        }
        check(tapeChanged && !farChanged, "tape is drawn on the screenshot's top corner only")
        let wp = BackdropConfig().applying(wallpaper: 4)
        check(wp.enabled && wp.glow == true && wp.fromHex == 0x0F2027 && wp.pattern == 1 && BackdropConfig().applying(wallpaper: 99) == BackdropConfig(), "wallpaper preset applies colours, glow and pattern")
        check((try? JSONDecoder().decode(BackdropConfig.self, from: old))?.tape == nil, "old backdrop settings have no tape")

        // Colour formats and recent colours.
        let amber = NSColor(hex: 0xFFC200)
        check(ColorFormat.android.string(for: amber) == "0xFFFFC200" && ColorFormat.uikit.string(for: amber) == "UIColor(red: 1.00, green: 0.76, blue: 0.00, alpha: 1.00)", "colour formats android and uikit")
        let rc = UserDefaults(suiteName: "snapix.selftest7")!
        rc.removePersistentDomain(forName: "snapix.selftest7")
        for h in 1...10 { RecentColors.add(UInt32(h), in: rc) }
        RecentColors.add(5, in: rc)
        check(RecentColors.all(in: rc).count == RecentColors.limit && RecentColors.all(in: rc).first == 5 && RecentColors.all(in: rc).filter { $0 == 5 }.count == 1, "recent colours newest first, unique, capped")
        rc.removePersistentDomain(forName: "snapix.selftest7")
        UserDefaults.standard.set(999_999, forKey: "scrollMaxHeight"); check(Stitcher.maxHeight == 60_000, "scroll height is capped")
        UserDefaults.standard.set(15_000, forKey: "scrollMaxHeight"); check(Stitcher.maxHeight == 15_000, "scroll height preference")
        UserDefaults.standard.removeObject(forKey: "scrollMaxHeight")

        // Application capture geometry.
        check(Capture.union(of: [CGRect(x: 0, y: 0, width: 100, height: 50), CGRect(x: 80, y: 40, width: 100, height: 100)]) == CGRect(x: 0, y: 0, width: 180, height: 140) && Capture.union(of: []) == nil, "union of window frames")

        // Custom OCR server: request and response handling.
        let rc2 = RemoteOCR.Config(baseURL: " https://api.example.com/v1/ ", model: "vision-1", prompt: "", apiKey: "k")
        check(rc2.endpoint?.absoluteString == "https://api.example.com/v1/chat/completions" && rc2.isUsable, "OCR endpoint is normalised")
        check(RemoteOCR.Config(baseURL: "https://x.io/chat/completions", model: "m", prompt: "", apiKey: "").endpoint?.absoluteString == "https://x.io/chat/completions", "OCR endpoint keeps a complete path")
        check(RemoteOCR.Config(baseURL: "ftp://x", model: "m", prompt: "", apiKey: "").endpoint == nil && !RemoteOCR.Config(baseURL: "https://x.io", model: " ", prompt: "", apiKey: "").isUsable, "OCR rejects bad address or empty model")
        if let req = try? RemoteOCR.request(rc2, png: Data([1, 2, 3])), let body = req.httpBody, let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            let parts = ((obj["messages"] as? [[String: Any]])?.first?["content"] as? [[String: Any]]) ?? []
            check(req.value(forHTTPHeaderField: "Authorization") == "Bearer k" && obj["model"] as? String == "vision-1" && parts.count == 2
                  && ((parts[1]["image_url"] as? [String: Any])?["url"] as? String) == "data:image/png;base64,AQID", "OCR request carries model, key and image")
        } else { check(false, "OCR request") }
        check((try? RemoteOCR.parse(Data(#"{"choices":[{"message":{"content":" Hello\nWorld "}}]}"#.utf8))) == "Hello\nWorld", "OCR parses a text answer")
        check((try? RemoteOCR.parse(Data(#"{"choices":[{"message":{"content":[{"type":"text","text":"A"},{"type":"text","text":"B"}]}}]}"#.utf8))) == "A\nB", "OCR parses a list of parts")
        var gotMessage = false
        do { _ = try RemoteOCR.parse(Data(#"{"error":{"message":"bad key"}}"#.utf8)) } catch RemoteOCR.Failure.message(let m) { gotMessage = m == "bad key" } catch {}
        check(gotMessage, "OCR surfaces a server error message")
        check(RemoteOCR.pngData(ocrImage.makeImage()!, maxSide: 300).flatMap { NSBitmapImageRep(data: $0)?.pixelsWide } == 300, "OCR image is scaled down")
        check(!(Pref.backupData()?.contains(Data("ocrAPIKey".utf8)) ?? false), "backups leave out the OCR key")

        // Quick Access buttons.
        check(QuickAction.parse("copy,edit") == [.edit, .copy] && QuickAction.parse("") == QuickAction.default && QuickAction.parse("nope,pin") == [.pin], "quick actions parse in canonical order")
        check(QuickAction.serialize([.pin, .edit]) == "edit,pin", "quick actions serialize canonically")
        check(RecentStrip.width(cards: 1, screenWidth: 1440) == 240 && RecentStrip.width(cards: 6, screenWidth: 1440) == 1238 && RecentStrip.width(cards: 16, screenWidth: 1440) == 1360, "recent strip width")

        // Backdrop folder and sidebar rows.
        let bfDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("snapix-bf-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: bfDir, withIntermediateDirectories: true)
        for n in ["b10.png", "b2.JPG", "a.heic", "notes.txt", ".hidden.png"] { FileManager.default.createFile(atPath: bfDir.appendingPathComponent(n).path, contents: Data([0])) }
        check(BackdropFolder.images(in: bfDir).map(\.lastPathComponent) == ["a.heic", "b2.JPG", "b10.png"], "backdrop folder lists images in natural order")
        try? FileManager.default.removeItem(at: bfDir)
        var textNote = Annotation(tool: .text, p1: .zero, p2: .zero, color: .red, width: 3); textNote.text = "A rather long caption that will be cut short"
        var counterNote = Annotation(tool: .counter, p1: .zero, p2: .zero, color: .red, width: 3); counterNote.number = 4
        check(SidebarModel.summary(for: textNote).count == 28 && SidebarModel.summary(for: counterNote) == "\(Tool.counter.title) 4", "sidebar row summaries")

        // Window screenshot background.
        let win = page(rows: 0..<50)
        let m = WindowBackground.margin(for: CGSize(width: 400, height: 50))
        check(m == 24, "window background minimum margin")
        if let c = WindowBackground.compose(window: win, picture: nil, color: CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1), margin: m), let px = PixelBuffer(c) {
            check(c.width == 448 && c.height == 98 && px.color(x: 2, y: 2)?.hexValue == 0xFF0000 && px.color(x: m + 5, y: m + 3)?.hexValue == PixelBuffer(win)?.color(x: 5, y: 3)?.hexValue, "window background adds a margin around the window")
        } else { check(false, "window background compose") }

        // Export formats.
        let enc = Exporter.data(for: strip, as: .pdf, scale: 2)
        check(enc.map { $0.starts(with: Data("%PDF".utf8)) } == true, "PDF export")
        check(Exporter.data(for: strip, as: .png, scale: 1).map { $0.starts(with: Data([0x89, 0x50])) } == true, "PNG export")

        // Resetting settings.
        let rs = UserDefaults(suiteName: "snapix.selftest4")!
        rs.removePersistentDomain(forName: "snapix.selftest4")
        rs.set("png", forKey: "format"); rs.set("secret", forKey: "uploadAuthHeader"); rs.set(1, forKey: "unrelated"); rs.set(Data([1]), forKey: "hotkey.area")
        Pref.resetShortcuts(in: rs)
        check(rs.object(forKey: "hotkey.area") == nil && rs.string(forKey: "format") == "png", "reset shortcuts only")
        Pref.resetAll(in: rs)
        check(rs.object(forKey: "format") == nil && rs.object(forKey: "uploadAuthHeader") == nil && rs.integer(forKey: "unrelated") == 1, "reset all keeps unrelated keys")
        rs.removePersistentDomain(forName: "snapix.selftest4")

        // Style presets.
        let ps = UserDefaults(suiteName: "snapix.selftest3")!
        ps.removePersistentDomain(forName: "snapix.selftest3")
        StylePreset.save(StylePreset(name: "A", colorHex: 0x112233, width: 7, filled: true), in: ps)
        StylePreset.save(StylePreset(name: "B", colorHex: 0x445566, width: 2), in: ps)
        StylePreset.save(StylePreset(name: "A", colorHex: 0x778899, width: 9), in: ps)
        check(StylePreset.saved(in: ps).map(\.name) == ["B", "A"] && StylePreset.saved(in: ps).last?.colorHex == 0x778899, "preset save replaces by name")
        StylePreset.delete(named: "B", in: ps)
        check(StylePreset.saved(in: ps).map(\.name) == ["A"], "preset delete")
        ps.removePersistentDomain(forName: "snapix.selftest3")

        // Combining screenshots.
        let colA = page(rows: 0..<100), colB = page(rows: 200..<260)
        if let v = Combine.images([colA, colB], horizontal: false) { check(v.width == 400 && v.height == 160, "combine vertical size \(v.width)x\(v.height)") } else { check(false, "combine vertical") }
        if let hz = Combine.images([colA, colB], horizontal: true, spacing: 10) { check(hz.width == 810 && hz.height == 100, "combine horizontal size \(hz.width)x\(hz.height)") } else { check(false, "combine horizontal") }
        if let v = Combine.images([colA, colB], horizontal: false) {
            check(PixelBuffer(v)?.color(x: 5, y: 10)?.hexValue == PixelBuffer(colA)?.color(x: 5, y: 10)?.hexValue, "combine keeps first image on top")
            check(PixelBuffer(v)?.color(x: 5, y: 110)?.hexValue == PixelBuffer(colB)?.color(x: 5, y: 10)?.hexValue, "combine puts second image below")
        }

        // Sensitive-data detection.
        func hits(_ t: String) -> [String] { Redaction.ranges(in: t).map { String(t[$0]) } }
        check(hits("write to jane.doe@example.com now") == ["jane.doe@example.com"], "redaction: email")
        check(hits("card 4111 1111 1111 1111 ok") == ["4111 1111 1111 1111"], "redaction: card (Luhn)")
        check(hits("card 4111 1111 1111 1112").isEmpty, "redaction: bad card number ignored")
        check(hits("FR76 3000 6000 0112 3456 7890 189") == ["FR76 3000 6000 0112 3456 7890 189"], "redaction: IBAN")
        check(hits("token ghp_abcdefghijklmnopqrstuvwxyz0123456789").count == 1, "redaction: API token")
        check(hits("host 192.168.1.42 up") == ["192.168.1.42"], "redaction: IPv4")
        check(hits("+33 6 12 34 56 78").count == 1, "redaction: phone")
        check(hits("released on 2024-11-07 in version 3.14159").isEmpty, "redaction: dates and decimals ignored")

        // Render every tool onto a gradient screenshot with backdrop.
        let base = page(rows: 0..<600)
        let doc = Document(image: base, scale: 2)
        func add(_ t: Tool, _ a: CGPoint, _ b: CGPoint, mutate: (inout Annotation) -> Void = { _ in }) {
            var an = Annotation(tool: t, p1: a, p2: b, color: .systemRed, width: 5)
            an.points = [a, CGPoint(x: (a.x + b.x) / 2, y: a.y + 30), b]
            mutate(&an)
            doc.state.annotations.append(an)
        }
        add(.arrow, CGPoint(x: 20, y: 20), CGPoint(x: 160, y: 90))
        add(.arrow, CGPoint(x: 200, y: 20), CGPoint(x: 330, y: 90)) { $0.style = 2 }
        add(.rect, CGPoint(x: 20, y: 120), CGPoint(x: 150, y: 190))
        add(.oval, CGPoint(x: 180, y: 120), CGPoint(x: 300, y: 190)) { $0.filled = true }
        add(.line, CGPoint(x: 20, y: 220), CGPoint(x: 140, y: 250))
        add(.pen, CGPoint(x: 160, y: 220), CGPoint(x: 280, y: 250))
        add(.highlighter, CGPoint(x: 20, y: 280), CGPoint(x: 200, y: 280)) { $0.color = NSColor(hex: 0xFFC200); $0.width = 20; $0.points = [CGPoint(x: 20, y: 280), CGPoint(x: 200, y: 280)] }
        add(.text, CGPoint(x: 20, y: 320), CGPoint(x: 20, y: 320)) { $0.text = "Hello Snapix"; $0.color = .white; $0.filled = true }
        add(.counter, CGPoint(x: 60, y: 400), CGPoint(x: 60, y: 400)) { $0.number = 1 }
        add(.counter, CGPoint(x: 120, y: 400), CGPoint(x: 120, y: 400)) { $0.number = 2 }
        add(.ruler, CGPoint(x: 20, y: 450), CGPoint(x: 220, y: 452))
        add(.blur, CGPoint(x: 240, y: 300), CGPoint(x: 380, y: 380))
        add(.blur, CGPoint(x: 240, y: 400), CGPoint(x: 380, y: 460)) { $0.blur = .gaussian }
        add(.blur, CGPoint(x: 240, y: 480), CGPoint(x: 380, y: 540)) { $0.blur = .erase }
        add(.spotlight, CGPoint(x: 10, y: 100), CGPoint(x: 390, y: 200))
        add(.magnifier, CGPoint(x: 320, y: 250), CGPoint(x: 360, y: 250))
        add(.arrow, CGPoint(x: 30, y: 520), CGPoint(x: 220, y: 580)) { $0.bend(through: CGPoint(x: 90, y: 590)) }
        doc.state.overlay = OverlayImage(image: page(rows: 100..<160), origin: CGPoint(x: 30, y: 540), opacity: 0.6, scale: 1)
        var plain = doc.state
        if let img = Renderer.render(plain) {
            check(img.width == 400 && img.height == 600, "render size without backdrop")
            write(img, "\(outDir)/plain.png")
        }
        plain.backdrop = BackdropConfig(enabled: true, padding: 64, innerRadius: 14, outerRadius: 20, shadow: true)
        if let img = Renderer.render(plain) {
            check(img.width == 400 + 128 && img.height == 600 + 128, "render size with backdrop")
            write(img, "\(outDir)/backdrop.png")
        }

        // Uncrop after a crop keeps annotations aligned with their content.
        let d3 = Document(image: base, scale: 1)
        d3.state.annotations.append(Annotation(tool: .rect, p1: CGPoint(x: 100, y: 100), p2: CGPoint(x: 150, y: 150), color: .red, width: 2))
        let cropCanvas = CanvasView(doc: d3)
        cropCanvas.tool = .crop
        d3.mutate { st in
            st.uncrop = UncropInfo(image: st.image, rect: CGRect(x: 50, y: 40, width: 200, height: 200))
            st.image = st.image.cropping(to: CGRect(x: 50, y: 40, width: 200, height: 200))!
            st.annotations[0].translate(by: CGSize(width: -50, height: -40))
        }
        cropCanvas.uncrop()
        check(d3.state.image.height == 600 && d3.state.annotations[0].p1 == CGPoint(x: 100, y: 100) && d3.state.uncrop == nil, "uncrop restores image and annotations")
        d3.undo()
        check(d3.state.image.height == 200 && d3.state.uncrop != nil, "undo of uncrop")

        // Edge snapping + similar-region detection on a white box over black.
        let boxCtx = CGContext(data: nil, width: 200, height: 120, bitsPerComponent: 8, bytesPerRow: 0, space: Renderer.sRGB,
                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        boxCtx.setFillColor(NSColor.black.cgColor); boxCtx.fill(CGRect(x: 0, y: 0, width: 200, height: 120))
        boxCtx.setFillColor(NSColor.white.cgColor); boxCtx.fill(CGRect(x: 50, y: 30, width: 100, height: 60)) // y flipped: rows 30..<90
        if let buf = PixelBuffer(boxCtx.makeImage()!) {
            let sn = buf.snap(CGPoint(x: 47, y: 60), radius: 8)
            check(sn.x == 50, "snap x to left edge (got \(sn.x))")
            let sn2 = buf.snap(CGPoint(x: 100, y: 93), radius: 8)
            check(sn2.y == 90, "snap y to bottom edge (got \(sn2.y))")
            check(buf.snap(CGPoint(x: 100, y: 60), radius: 8) == CGPoint(x: 100, y: 60), "no snap in flat area")
            check(buf.similarRegion(from: 100, 60) == CGRect(x: 50, y: 30, width: 100, height: 60), "similar region = white box")
        }

        // Preview placement: inside a big region's corner, beside a small one, never off screen.
        let vis = CGRect(x: 0, y: 0, width: 1600, height: 900), psz = NSSize(width: 232, height: 300)
        let big = PreviewController.anchoredFrame(region: CGRect(x: 100, y: 100, width: 800, height: 600), size: psz, visible: vis)
        check(big.maxX == 888 && big.minY == 112, "preview inside big region, bottom-right (got \(big))")
        let small = PreviewController.anchoredFrame(region: CGRect(x: 100, y: 100, width: 150, height: 80), size: psz, visible: vis)
        check(small.minX == 262 && small.minY == 100, "preview beside small region (got \(small))")
        let edge = PreviewController.anchoredFrame(region: CGRect(x: 1500, y: 20, width: 90, height: 60), size: psz, visible: vis)
        check(edge.maxX <= 1600 && edge.minX >= 0 && edge.minY >= 0 && edge.maxY <= 900 && !edge.intersects(CGRect(x: 1500, y: 20, width: 90, height: 60)),
              "preview kept on screen next to a region at the edge (got \(edge))")

        // Preview next to where the selection ended: below-right, flipping when cramped.
        let n1 = PreviewController.frame(near: CGPoint(x: 400, y: 600), size: psz, visible: vis)
        check(n1.minX == 416 && n1.maxY == 584, "preview below-right of the end point (got \(n1))")
        let n2 = PreviewController.frame(near: CGPoint(x: 1550, y: 600), size: psz, visible: vis)
        check(n2.maxX == 1534 && n2.maxY == 584, "preview flips left near the right edge (got \(n2))")
        let n3 = PreviewController.frame(near: CGPoint(x: 400, y: 120), size: psz, visible: vis)
        check(n3.minY == 136 && n3.minX == 416, "preview flips above near the bottom (got \(n3))")

        // Curved arrows: the bend handle sits on the curve and survives hit-testing.
        var curved = Annotation(tool: .arrow, p1: CGPoint(x: 0, y: 0), p2: CGPoint(x: 100, y: 0), color: .red, width: 4)
        curved.bend(through: CGPoint(x: 50, y: -40))
        check(curved.ctrl == CGPoint(x: 50, y: -80) && curved.curveMid == CGPoint(x: 50, y: -40), "bend handle lies on the curve (ctrl \(String(describing: curved.ctrl)))")
        check(curved.hitTest(CGPoint(x: 50, y: -40), tolerance: 6) && !curved.hitTest(CGPoint(x: 50, y: 0), tolerance: 6), "hit-test follows the curve")
        curved.bend(through: CGPoint(x: 50, y: 1))
        check(curved.ctrl == nil, "dragging the handle back to the chord straightens the arrow")
        var tapered = curved
        tapered.style = 2
        check(!tapered.isCurvable, "tapered arrows stay straight")

        // Localization: only meaningful inside the bundled app run with a French locale.
        if Bundle.main.localizations.contains("fr"), Locale.preferredLanguages.first?.hasPrefix("fr") == true {
            check(L("Save") == "Enregistrer" && LF("Saved %@", "a.png") == "a.png enregistré", "French localization")
        }

        // Contrast maths against published reference values.
        check(abs(ColorMath.wcagRatio(.black, .white) - 21) < 0.01, "WCAG black/white = 21")
        check(abs(ColorMath.wcagRatio(NSColor(hex: 0x777777), .white) - 4.48) < 0.05, "WCAG #777 on white ≈ 4.48")
        check(abs(ColorMath.apca(text: .black, background: .white) - 106) < 2, "APCA black on white ≈ 106")
        check(ColorMath.apca(text: .white, background: .black) < -100, "APCA white on black < -100")
        check(ColorFormat.hex.string(for: NSColor(hex: 0xFFC200)) == "#FFC200", "hex format")
        check(ColorFormat.rgba.string(for: NSColor(hex: 0xFFC200)) == "rgba(255, 194, 0, 1)", "rgba format")
        check(ColorFormat.csharp.string(for: NSColor(hex: 0xFFC200)) == "Color.FromArgb(255, 194, 0)", "C# format")

        // Undo/redo.
        let d2 = Document(image: base, scale: 1)
        d2.mutate { $0.annotations.append(Annotation(tool: .rect, p1: .zero, p2: CGPoint(x: 5, y: 5), color: .red, width: 2)) }
        d2.undo(); check(d2.state.annotations.isEmpty, "undo")
        d2.redo(); check(d2.state.annotations.count == 1, "redo")

        // Encoding heuristics.
        var noise = [UInt8](repeating: 0, count: 200 * 200 * 4)
        for i in noise.indices { noise[i] = i % 4 == 3 ? 255 : UInt8.random(in: 0...255) }
        let noiseImg = CGContext(data: &noise, width: 200, height: 200, bitsPerComponent: 8, bytesPerRow: 800, space: Renderer.sRGB,
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
        check(Exporter.looksLikePhoto(noiseImg) == true, "noisy image -> JPEG")
        let flat = CGContext(data: nil, width: 200, height: 200, bitsPerComponent: 8, bytesPerRow: 0, space: Renderer.sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        flat.setFillColor(NSColor.white.cgColor); flat.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
        check(Exporter.looksLikePhoto(flat.makeImage()!) == false, "flat image -> PNG")

        print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
        return failures == 0 ? 0 : 1
    }

    private static func write(_ img: CGImage, _ path: String) {
        try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
