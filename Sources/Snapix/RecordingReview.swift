import AVFoundation
import AVKit
import AppKit

/// Plays back a fresh recording and lets the user trim it before it is saved.
@MainActor
final class RecordingReview: NSObject, NSWindowDelegate {
    private static var open: [RecordingReview] = []

    private let url: URL
    private let player: AVPlayer
    private let playerView = AVPlayerView()
    private let window: NSWindow
    private let onSave: (URL) -> Void
    private var finished = false
    private weak var trimButton: NSButton?
    private let speedPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let muteCheck = NSButton(checkboxWithTitle: L("Mute"), target: nil, action: nil)
    static let speeds: [Double] = [0.5, 1, 1.5, 2, 4]

    /// Length of the exported clip: the selected range played at `speed`.
    static func outputDuration(range: Double, speed: Double) -> Double { speed > 0 ? range / speed : range }

    /// `onSave` receives either the original file or a trimmed copy; the review deletes whatever it no longer needs.
    static func show(url: URL, onSave: @escaping (URL) -> Void) {
        let r = RecordingReview(url: url, onSave: onSave)
        open.append(r)
        NSApp.setActivationPolicy(.regular)
        r.window.center()
        r.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        r.player.play()
    }

    private init(url: URL, onSave: @escaping (URL) -> Void) {
        self.url = url
        self.onSave = onSave
        player = AVPlayer(url: url)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 520), styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        super.init()
        window.isReleasedWhenClosed = false
        window.title = L("Review Recording")
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = Theme.window
        window.minSize = NSSize(width: 520, height: 360)
        window.delegate = self

        playerView.player = player
        playerView.controlsStyle = .inline
        playerView.showsFullScreenToggleButton = false

        func button(_ title: String, _ symbol: String, _ action: Selector, primary: Bool = false) -> NSButton {
            let b = NSButton(title: title, target: self, action: action)
            b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            b.imagePosition = .imageLeading
            b.bezelStyle = .rounded
            if primary { b.keyEquivalent = "\r"; b.bezelColor = Theme.accent }
            return b
        }
        let trim = button(L("Trim"), "scissors", #selector(trimTapped))
        trim.isEnabled = playerView.canBeginTrimming
        trimButton = trim
        let discard = button(L("Discard"), "trash", #selector(discardTapped))
        let gif = button(L("Save as GIF"), "photo.stack", #selector(saveGIFTapped))
        let save = button(L("Save"), "square.and.arrow.down", #selector(saveTapped), primary: true)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        speedPopup.addItems(withTitles: Self.speeds.map { $0 == 1 ? L("Normal speed") : String(format: "%g×", $0) })
        speedPopup.selectItem(at: 1)
        speedPopup.toolTip = L("Playback speed of the saved video")
        let bar = NSStackView(views: [trim, speedPopup, muteCheck, spacer, discard, gif, save])
        bar.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 12, right: 14)

        let stack = NSStackView(views: [playerView, bar])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.setHuggingPriority(.init(1), for: .vertical)
        window.contentView = stack
        // The trim control only exists once the movie has loaded.
        Task { @MainActor [weak self] in
            for _ in 0..<20 {
                if self?.playerView.canBeginTrimming == true { self?.trimButton?.isEnabled = true; return }
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
        }
    }

    @objc private func trimTapped() {
        playerView.beginTrimming { _ in }
    }

    @objc private func discardTapped() {
        finished = true
        try? FileManager.default.removeItem(at: url)
        close()
        Toast.show(L("Recording discarded"), symbol: "checkmark.circle.fill")
    }

    @objc private func saveTapped() { save() }
    @objc private func saveGIFTapped() { save(asGIF: true) }

    private func close() {
        player.pause()
        window.close()
    }

    /// Writes the trimmed range when the user trimmed, otherwise hands over the file as is.
    private func save(asGIF: Bool = false) {
        guard !finished else { return }
        finished = true
        player.pause()
        let item = player.currentItem
        let start = item?.reversePlaybackEndTime ?? .invalid, end = item?.forwardPlaybackEndTime ?? .invalid
        let duration = item?.duration ?? .invalid
        let trimmed = start.isNumeric && end.isNumeric && duration.isNumeric
            && (start.seconds > 0.05 || end.seconds < duration.seconds - 0.05) && end > start
        window.orderOut(nil)
        // Hands the final video over as is, or re-encoded as a GIF when asked.
        let deliver: (URL) -> Void = { [weak self] file in
            guard asGIF else { self?.onSave(file); self?.finish(); return }
            Toast.show(L("Creating the GIF…"), duration: 30)
            Task { @MainActor in
                let gif = await Recorder.makeGIF(from: file)
                if let gif { try? FileManager.default.removeItem(at: file) }
                self?.onSave(gif ?? file)
                self?.finish()
            }
        }
        let speed = Self.speeds[max(0, speedPopup.indexOfSelectedItem)]
        let mute = muteCheck.state == .on
        guard trimmed || speed != 1 || mute else { deliver(url); return }

        Toast.show(L("Processing…"), duration: 60)
        let source = url
        if speed != 1 || mute {
            let range = trimmed ? CMTimeRange(start: start, end: end) : CMTimeRange(start: .zero, duration: duration)
            let out = url.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".mp4")
            Task { @MainActor [weak self] in
                let ok = await Self.render(source: source, range: range, speed: speed, mute: mute, to: out)
                if ok { try? FileManager.default.removeItem(at: source) }
                deliver(ok ? out : source) // keep the original recording rather than lose it
                _ = self
            }
            return
        }
        let out = url.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".mp4")
        guard let export = AVAssetExportSession(asset: AVURLAsset(url: source), presetName: AVAssetExportPresetPassthrough) else {
            deliver(url); return
        }
        export.outputURL = out
        export.outputFileType = .mp4
        export.timeRange = CMTimeRange(start: start, end: end)
        nonisolated(unsafe) let session = export
        session.exportAsynchronously { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if session.status == .completed {
                        try? FileManager.default.removeItem(at: source)
                        deliver(out)
                    } else {
                        deliver(source) // keep the untrimmed recording rather than lose it
                    }
                }
            }
        }
    }

    /// Re-encodes `range` of the video at `speed`, optionally without sound.
    static func render(source: URL, range: CMTimeRange, speed: Double, mute: Bool, to out: URL) async -> Bool {
        let asset = AVURLAsset(url: source)
        let comp = AVMutableComposition()
        do {
            if let v = try await asset.loadTracks(withMediaType: .video).first, let ct = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
                try ct.insertTimeRange(range, of: v, at: .zero)
                ct.preferredTransform = try await v.load(.preferredTransform)
            }
            if !mute {
                for a in try await asset.loadTracks(withMediaType: .audio) {
                    guard let ct = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
                    try ct.insertTimeRange(range, of: a, at: .zero)
                }
            }
        } catch { return false }
        if speed != 1 {
            comp.scaleTimeRange(CMTimeRange(start: .zero, duration: range.duration),
                                toDuration: CMTime(seconds: outputDuration(range: range.duration.seconds, speed: speed), preferredTimescale: 600))
        }
        guard let export = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetHighestQuality) else { return false }
        export.outputURL = out
        export.outputFileType = .mp4
        nonisolated(unsafe) let session = export
        return await withCheckedContinuation { cont in
            session.exportAsynchronously { cont.resume(returning: session.status == .completed) }
        }
    }

    private func finish() {
        RecordingReview.open.removeAll { $0 === self }
        if RecordingReview.open.isEmpty && !EditorWindowController.hasOpenEditors { NSApp.setActivationPolicy(AppDelegate.restingPolicy) }
    }

    /// Closing the window keeps the recording, like closing the editor keeps a screenshot.
    func windowWillClose(_ notification: Notification) {
        if !finished { save() }
    }
}
