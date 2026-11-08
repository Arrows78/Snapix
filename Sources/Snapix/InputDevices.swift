import AVFoundation

/// Microphones and cameras the user can pick for a recording.
enum InputDevices {
    struct Device: Equatable { let id: String; let name: String }

    static func microphones() -> [Device] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices.map { Device(id: $0.uniqueID, name: $0.localizedName) }
    }

    static func cameras() -> [Device] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera], mediaType: .video, position: .unspecified).devices
            .map { Device(id: $0.uniqueID, name: $0.localizedName) }
    }

    /// The device with `id` among `list`, or nil (meaning "use the system default") when none is chosen or it is gone.
    static func resolve(_ id: String, in list: [Device]) -> Device? { id.isEmpty ? nil : list.first { $0.id == id } }
}
