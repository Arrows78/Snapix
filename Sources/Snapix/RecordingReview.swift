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
        let save = button(L("Save"), "square.and.arrow.down", #selector(saveTapped), primary: true)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let bar = NSStackView(views: [trim, spacer, discard, save])
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

    private func close() {
        player.pause()
        window.close()
    }

    /// Writes the trimmed range when the user trimmed, otherwise hands over the file as is.
    private func save() {
        guard !finished else { return }
        finished = true
        player.pause()
        let item = player.currentItem
        let start = item?.reversePlaybackEndTime ?? .invalid, end = item?.forwardPlaybackEndTime ?? .invalid
        let duration = item?.duration ?? .invalid
        let trimmed = start.isNumeric && end.isNumeric && duration.isNumeric
            && (start.seconds > 0.05 || end.seconds < duration.seconds - 0.05) && end > start
        window.orderOut(nil)
        guard trimmed else { onSave(url); finish(); return }

        Toast.show(L("Trimming…"), duration: 30)
        let source = url
        let out = url.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".mp4")
        guard let export = AVAssetExportSession(asset: AVURLAsset(url: source), presetName: AVAssetExportPresetPassthrough) else {
            onSave(url); finish(); return
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
                        self.onSave(out)
                    } else {
                        self.onSave(source) // keep the untrimmed recording rather than lose it
                    }
                    self.finish()
                }
            }
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
