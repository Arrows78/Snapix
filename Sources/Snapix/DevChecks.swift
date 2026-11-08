import AVFoundation
import AppKit
import ImageIO

/// `Snapix --check <name> …`: exercises the parts that need a real screen, a network peer or files, and prints what it measured.
/// Used by the maintainer; it never touches the clipboard, the Library or the save folder.
@MainActor
enum DevChecks {
    static func run(_ args: [String]) -> Int32 {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        var code: Int32 = 99
        var done = false
        Task { @MainActor in code = await execute(args); done = true }
        while !done { RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05)) }
        return code
    }

    private static func execute(_ a: [String]) async -> Int32 {
        guard let name = a.first else { print("usage: --check record <dir> | s3 <endpoint> <bucket> <access> <secret> | ocr <endpoint> <model>"); return 2 }
        switch name {
        case "record": return await checkRecording(dir: a.count > 1 ? a[1] : NSTemporaryDirectory())
        case "s3": return a.count >= 5 ? await checkS3(endpoint: a[1], bucket: a[2], access: a[3], secret: a[4]) : 2
        case "window": return await checkWindowBackground()
        case "ocr": return a.count >= 3 ? await checkOCR(endpoint: a[1], model: a[2]) : 2
        default: print("unknown check \(name)"); return 2
        }
    }

    // MARK: S3

    private static func checkS3(endpoint: String, bucket: String, access: String, secret: String) async -> Int32 {
        let cfg = S3Config(endpoint: endpoint, region: "us-east-1", bucket: bucket, accessKey: access, secretKey: secret, prefix: "checks", publicBase: "", linkMode: "presigned", expiryDays: 1)
        var failures = 0
        func report(_ ok: Bool, _ what: String, _ detail: String = "") { print(ok ? "PASS" : "FAIL", what, detail); if !ok { failures += 1 } }
        func status(_ req: URLRequest?) async -> Int {
            guard let req, let (_, resp) = try? await URLSession.shared.data(for: req) else { return -1 }
            return (resp as? HTTPURLResponse)?.statusCode ?? -1
        }
        report(await status(cfg.request(method: "HEAD", key: nil, body: nil, contentType: nil)) == 200, "signed HEAD on the bucket")
        let key = cfg.key(for: "hello world.txt")
        report(await status(cfg.request(method: "PUT", key: key, body: Data("hello".utf8), contentType: "text/plain")) == 200, "signed PUT of an object with a space in its name")
        if let link = cfg.link(forKey: key) {
            let got = await status(URLRequest(url: link))
            report(got == 200, "presigned GET link", "status \(got)")
        } else { report(false, "presigned link built") }
        var wrong = cfg; wrong.secretKey = "not-the-secret"
        report(await status(wrong.request(method: "PUT", key: key, body: Data("x".utf8), contentType: "text/plain")) == 403, "a wrong secret is refused")
        return failures == 0 ? 0 : 1
    }

    // MARK: Custom OCR

    private static func checkOCR(endpoint: String, model: String) async -> Int32 {
        let cfg = RemoteOCR.Config(baseURL: endpoint, model: model, prompt: "", apiKey: "test-key")
        var failures = 0
        func report(_ ok: Bool, _ what: String, _ detail: String = "") { print(ok ? "PASS" : "FAIL", what, detail); if !ok { failures += 1 } }
        do { let ms = try await RemoteOCR.test(config: cfg); report(true, "connection test", "\(ms) ms") } catch { report(false, "connection test", RemoteOCR.describe(error)) }
        let ctx = CGContext(data: nil, width: 400, height: 100, bitsPerComponent: 8, bytesPerRow: 0, space: Renderer.sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 100))
        do { let text = try await RemoteOCR.recognize(ctx.makeImage()!, config: cfg); report(text == "Hello from the mock server", "image recognition round trip", "got \"\(text)\"") }
        catch { report(false, "image recognition round trip", RemoteOCR.describe(error)) }
        var bad = cfg; bad.baseURL = "http://127.0.0.1:1"
        do { _ = try await RemoteOCR.test(config: bad); report(false, "an unreachable server is reported") } catch { report(true, "an unreachable server is reported") }
        return failures == 0 ? 0 : 1
    }

    // MARK: Window capture with a background

    private static func checkWindowBackground() async -> Int32 {
        var failures = 0
        func report(_ ok: Bool, _ what: String, _ detail: String = "") { print(ok ? "PASS" : "FAIL", what, detail); if !ok { failures += 1 } }
        guard CGPreflightScreenCaptureAccess() else { print("SKIP window: no Screen Recording permission"); return 3 }
        let win = NSWindow(contentRect: NSRect(x: 300, y: 300, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor(hex: 0x00AA55).cgColor
        win.contentView = view
        win.orderFrontRegardless()
        try? await Task.sleep(nanoseconds: 700_000_000)
        let defaults = UserDefaults.standard
        let saved = (defaults.object(forKey: "windowBackground"), defaults.object(forKey: "windowBackgroundColor"))
        defer {
            if let v = saved.0 { defaults.set(v, forKey: "windowBackground") } else { defaults.removeObject(forKey: "windowBackground") }
            if let v = saved.1 { defaults.set(v, forKey: "windowBackgroundColor") } else { defaults.removeObject(forKey: "windowBackgroundColor") }
        }
        defaults.set("transparent", forKey: "windowBackground")
        guard let plain = try? await Capture.captureWindow(id: CGWindowID(win.windowNumber)) else { print("FAIL could not capture the test window"); return 1 }
        defaults.set("solid", forKey: "windowBackground"); defaults.set(0xFF8800, forKey: "windowBackgroundColor")
        guard let framed = try? await Capture.captureWindow(id: CGWindowID(win.windowNumber)) else { print("FAIL could not capture the framed window"); return 1 }
        let margin = WindowBackground.margin(for: CGSize(width: plain.image.width, height: plain.image.height))
        print("INFO plain \(plain.image.width)x\(plain.image.height), framed \(framed.image.width)x\(framed.image.height), margin \(margin)")
        report(framed.image.width == plain.image.width + 2 * margin && framed.image.height == plain.image.height + 2 * margin, "a solid background adds the margin around the window")
        if let px = PixelBuffer(framed.image) {
            report(px.color(x: 3, y: 3)?.hexValue == 0xFF8800, "the margin takes the chosen colour")
            let mid = px.color(x: framed.image.width / 2, y: framed.image.height / 2)?.hexValue ?? 0
            report(abs(Int(mid >> 8 & 0xFF) - 0xAA) < 24 && abs(Int(mid & 0xFF) - 0x55) < 24, "the window content stays in the middle", String(mid, radix: 16))
        } else { report(false, "read the framed image") }
        win.orderOut(nil)
        return failures == 0 ? 0 : 1
    }

    // MARK: Recording

    private static func checkRecording(dir: String) async -> Int32 {
        var failures = 0
        func report(_ ok: Bool, _ what: String, _ detail: String = "") { print(ok ? "PASS" : "FAIL", what, detail); if !ok { failures += 1 } }
        guard CGPreflightScreenCaptureAccess() else { print("SKIP recording: this process has no Screen Recording permission"); return 3 }
        guard let screen = NSScreen.main else { print("SKIP recording: no screen"); return 3 }
        let region = CGRect(x: screen.frame.minX + 40, y: screen.frame.minY + 40, width: 320, height: 200)
        var produced: URL?
        Recorder.outputHook = { produced = $0 }
        defer { Recorder.outputHook = nil }
        do {
            try await Recorder.shared.begin(format: .video, rect: region, screen: screen)
        } catch { print("FAIL could not start:", error.localizedDescription); return 1 }
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        Recorder.shared.togglePause()
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        Recorder.shared.togglePause()
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        await Recorder.shared.stop()
        guard let url = produced else { print("FAIL no file was produced"); return 1 }
        defer { try? FileManager.default.removeItem(at: url) }
        let asset = AVURLAsset(url: url)
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        let videoTracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
        let audioTracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        let size = try? await videoTracks.first?.load(.naturalSize)
        print("INFO duration \(String(format: "%.2f", duration)) s, video tracks \(videoTracks.count), audio tracks \(audioTracks.count), size \(size.map { "\(Int($0.width))x\($0.height)" } ?? "?")")
        report(videoTracks.count == 1 && (size?.width ?? 0) > 0, "the file holds a video track")
        report(duration > 2.6 && duration < 3.6, "1.5 s + 1.5 s paused + 1.5 s = about 3 s, not 4.5 s", "duration \(String(format: "%.2f", duration))")

        // Speed change on the produced file: 2x halves the duration, muting leaves no audio track.
        let out = URL(fileURLWithPath: dir).appendingPathComponent("check-speed-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: out) }
        let range = CMTimeRange(start: .zero, duration: CMTime(seconds: duration, preferredTimescale: 600))
        let ok = await RecordingReview.render(source: url, range: range, speed: 2, mute: true, to: out)
        let fast = AVURLAsset(url: out)
        let fastDuration = (try? await fast.load(.duration).seconds) ?? 0
        let fastAudio = (try? await fast.loadTracks(withMediaType: .audio)) ?? []
        report(ok && abs(fastDuration - duration / 2) < 0.35 && fastAudio.isEmpty, "2x speed halves the duration and mute leaves no audio", "\(String(format: "%.2f", fastDuration)) s")

        // GIF conversion.
        if let gif = await Recorder.makeGIF(from: url), let src = CGImageSourceCreateWithURL(gif as CFURL, nil) {
            let n = CGImageSourceGetCount(src)
            report(n >= 2, "GIF conversion yields several frames", "\(n) frames")
            try? FileManager.default.removeItem(at: gif)
        } else { report(false, "GIF conversion") }
        return failures == 0 ? 0 : 1
    }
}
