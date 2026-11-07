import AppKit

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
