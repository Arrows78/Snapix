import AppKit

/// Audible confirmation of a capture.
@MainActor
enum Feedback {
    private static let shutterSound: NSSound? = {
        let path = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Grab.aif"
        return NSSound(contentsOfFile: path, byReference: true) ?? NSSound(named: "Tink")
    }()

    static func shutter() {
        guard Pref.bool("captureSound") else { return }
        shutterSound?.stop()
        shutterSound?.play()
    }

    /// Short cue when a recording starts or stops.
    static func recordingChime(start: Bool) {
        guard Pref.bool("captureSound") else { return }
        let name = start ? "begin_record" : "end_record"
        let path = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/\(name).caf"
        (NSSound(contentsOfFile: path, byReference: true) ?? NSSound(named: "Pop"))?.play()
    }
}
