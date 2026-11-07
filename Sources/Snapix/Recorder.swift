import AVFoundation
import AppKit
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

/// Receives ScreenCaptureKit frames and writes them to an MP4 file.
private final class FrameWriter: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    private let audio: AVAssetWriterInput?
    private var sessionStarted = false
    var onError: ((Error) -> Void)?

    init(url: URL, width: Int, height: Int, audio withAudio: Bool) throws {
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: width * height * 4, AVVideoExpectedSourceFrameRateKey: 30],
        ])
        video.expectsMediaDataInRealTime = true
        writer.add(video)
        if withAudio {
            let a = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVNumberOfChannelsKey: 2, AVSampleRateKey: 48_000, AVEncoderBitRateKey: 128_000,
            ])
            a.expectsMediaDataInRealTime = true
            writer.add(a)
            audio = a
        } else {
            audio = nil
        }
        super.init()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sb.isValid, CMSampleBufferGetNumSamples(sb) > 0 else { return }
        switch type {
        case .screen:
            // Only complete frames carry pixels; idle/blank ones must be skipped.
            guard let info = (CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
                  let raw = info[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete else { return }
            if !sessionStarted {
                guard writer.startWriting() else { return }
                writer.startSession(atSourceTime: sb.presentationTimeStamp)
                sessionStarted = true
            }
            if video.isReadyForMoreMediaData { video.append(sb) }
        case .audio:
            if sessionStarted, let audio, audio.isReadyForMoreMediaData { audio.append(sb) }
        default:
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) { onError?(error) }

    /// Closes the file; false when no frame was ever written.
    func finish() async -> Bool {
        guard sessionStarted else { writer.cancelWriting(); return false }
        video.markAsFinished()
        audio?.markAsFinished()
        await writer.finishWriting()
        return writer.status == .completed
    }
}

/// Records a region of a screen to MP4, or to an animated GIF.
@MainActor
final class Recorder {
    static let shared = Recorder()

    enum Format { case video, gif }

    private var stream: SCStream?
    private var frames: FrameWriter?
    private var outputURL: URL?
    private var format = Format.video
    private var hud: RecordingHUD?
    private var border: NSWindow?

    var isRecording: Bool { stream != nil }

    // MARK: Start / stop

    func start(format: Format) async throws {
        guard !isRecording, let (rect, screen) = try await Capture.selectRegion() else { return }
        let countdown = UserDefaults.standard.integer(forKey: "recordCountdown")
        for n in stride(from: countdown, through: 1, by: -1) {
            Toast.show(LF("Recording in %d…", n), duration: 1)
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        // The indicators go up first so the content list below includes their windows and can leave them out of the video.
        showIndicators(rect: rect, screen: screen)
        var started = false
        defer { if !started { hideIndicators() } }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == Capture.displayID(screen) }) else { throw CaptureError.notFound }

        let scale = screen.backingScaleFactor
        // H.264 needs even dimensions.
        let w = Int((rect.width * scale).rounded()) & ~1, h = Int((rect.height * scale).rounded()) & ~1
        guard w >= 16, h >= 16 else { throw CaptureError.notFound }

        let withAudio = format == .video && Pref.bool("recordAudio")
        let url = Self.temporaryURL(for: format)
        let writer = try FrameWriter(url: url, width: w, height: h, audio: withAudio)
        writer.onError = { [weak self] _ in Task { @MainActor in await self?.stop() } }

        let cfg = SCStreamConfiguration()
        cfg.sourceRect = CGRect(x: rect.minX - screen.frame.minX, y: screen.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
        cfg.width = w
        cfg.height = h
        cfg.showsCursor = Pref.bool("recordCursor")
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: format == .gif ? 15 : 30)
        cfg.queueDepth = 6
        if withAudio { cfg.capturesAudio = true; cfg.excludesCurrentProcessAudio = true }

        let filter = Capture.filter(display: display, content: content, excludingSelf: true)
        let s = SCStream(filter: filter, configuration: cfg, delegate: writer)
        let queue = DispatchQueue(label: "snapix.recorder")
        try s.addStreamOutput(writer, type: .screen, sampleHandlerQueue: queue)
        if withAudio { try s.addStreamOutput(writer, type: .audio, sampleHandlerQueue: queue) }
        try await s.startCapture()

        stream = s
        frames = writer
        outputURL = url
        self.format = format
        started = true
        Feedback.recordingChime(start: true)
    }

    func stop() async {
        guard let s = stream, let writer = frames, let url = outputURL else { return }
        stream = nil; frames = nil; outputURL = nil
        hideIndicators()
        try? await s.stopCapture()
        let ok = await writer.finish()
        Feedback.recordingChime(start: false)
        guard ok else { Toast.show(L("Nothing was recorded"), symbol: "exclamationmark.triangle.fill"); return }
        if format == .gif {
            Toast.show(L("Creating the GIF…"), duration: 30)
            let gif = await Self.makeGIF(from: url)
            try? FileManager.default.removeItem(at: url)
            guard let gif else { Toast.show(L("Could not create the GIF"), symbol: "exclamationmark.triangle.fill"); return }
            finalize(gif)
        } else {
            finalize(url)
        }
    }

    func toggle(format: Format) async throws {
        if isRecording { await stop() } else { try await start(format: format) }
    }

    // MARK: Output

    private static func temporaryURL(for format: Format) -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("SnapixRecordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(UUID().uuidString + ".mp4")
    }

    /// Moves the finished file into the save folder and puts it on the clipboard as a file.
    private func finalize(_ file: URL) {
        let folder = URL(fileURLWithPath: Pref.string("saveFolder"), isDirectory: true)
        let ext = file.pathExtension
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let dest = Exporter.uniqueURL(in: folder, name: Exporter.filename(ext: ext, suffix: " " + L("recording")))
            try FileManager.default.moveItem(at: file, to: dest)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([dest as NSURL])
            Toast.show(LF("Recording saved and copied: %@", dest.lastPathComponent), duration: 3, symbol: "checkmark.circle.fill")
            if Pref.bool("recordReveal") { NSWorkspace.shared.activateFileViewerSelecting([dest]) }
        } catch {
            Toast.show(LF("Capture failed: %@", error.localizedDescription), duration: 3, symbol: "exclamationmark.triangle.fill")
        }
    }

    /// Re-encodes an MP4 as a looping GIF (at most 720 px wide, 12 images per second).
    private static func makeGIF(from url: URL) async -> URL? {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration).seconds, duration > 0 else { return nil }
        let fps = 12.0
        let count = max(1, Int(duration * fps))
        let out = url.deletingPathExtension().appendingPathExtension("gif")
        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.gif.identifier as CFString, count, nil) else { return nil }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 720, height: 10_000)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let frameProps = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / fps]] as CFDictionary
        var added = 0
        for i in 0..<count {
            let t = CMTime(seconds: Double(i) / fps, preferredTimescale: 600)
            if let img = try? await generator.image(at: t).image {
                CGImageDestinationAddImage(dest, img, frameProps)
                added += 1
            }
        }
        guard added > 0, CGImageDestinationFinalize(dest) else { return nil }
        return out
    }

    // MARK: On-screen indicators

    private func showIndicators(rect: CGRect, screen: NSScreen) {
        let b = NSWindow(contentRect: rect.insetBy(dx: -3, dy: -3), styleMask: .borderless, backing: .buffered, defer: false)
        b.isOpaque = false
        b.backgroundColor = .clear
        b.ignoresMouseEvents = true
        b.level = .statusBar
        b.isReleasedWhenClosed = false
        b.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let v = NSView()
        v.wantsLayer = true
        v.layer?.borderColor = NSColor.systemRed.withAlphaComponent(0.9).cgColor
        v.layer?.borderWidth = 2
        v.layer?.cornerRadius = 3
        b.contentView = v
        b.orderFrontRegardless()
        border = b
        hud = RecordingHUD(near: rect, on: screen) { [weak self] in Task { await self?.stop() } }
    }

    private func hideIndicators() {
        border?.orderOut(nil); border = nil
        hud?.close(); hud = nil
    }
}

/// A small floating pill with a blinking dot, the elapsed time and a stop button.
@MainActor
private final class RecordingHUD {
    private let panel: NSPanel
    private let label = NSTextField(labelWithString: "0:00")
    private let dot = NSView()
    private var timer: Timer?
    private let started = Date()
    private let onStop: () -> Void

    init(near rect: CGRect, on screen: NSScreen, onStop: @escaping () -> Void) {
        self.onStop = onStop
        let box = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 150, height: 36))
        box.material = .hudWindow
        box.blendingMode = .behindWindow
        box.state = .active
        box.wantsLayer = true
        box.layer?.cornerRadius = 18

        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.systemRed.cgColor
        dot.layer?.cornerRadius = 5
        dot.frame = NSRect(x: 14, y: 13, width: 10, height: 10)
        label.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
        label.frame = NSRect(x: 32, y: 9, width: 50, height: 18)
        let stop = NSButton(title: L("Stop"), target: nil, action: nil)
        stop.bezelStyle = .rounded
        stop.controlSize = .small
        stop.frame = NSRect(x: 84, y: 6, width: 58, height: 24)
        [dot, label, stop].forEach(box.addSubview)

        panel = NSPanel(contentRect: box.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = box
        // Below the region when there is room, otherwise above it.
        let below = rect.minY - 46 >= screen.visibleFrame.minY
        panel.setFrameOrigin(NSPoint(x: max(screen.frame.minX + 8, min(rect.midX - 75, screen.frame.maxX - 158)),
                                     y: below ? rect.minY - 46 : min(rect.maxY + 10, screen.visibleFrame.maxY - 40)))
        panel.orderFrontRegardless()

        stop.target = self
        stop.action = #selector(stopTapped)
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    @objc private func stopTapped() { onStop() }

    private func tick() {
        let s = Int(Date().timeIntervalSince(started))
        label.stringValue = String(format: "%d:%02d", s / 60, s % 60)
        dot.alphaValue = dot.alphaValue < 1 ? 1 : 0.25
    }

    func close() {
        timer?.invalidate()
        panel.orderOut(nil)
    }
}
