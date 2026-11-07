import AppKit

/// A saved annotation style: colour, stroke width and the tool-specific options.
struct StylePreset: Codable, Equatable {
    var name: String
    var colorHex: UInt32
    var width: CGFloat
    var arrowStyle = 0
    var filled = false
    var blur = BlurMode.pixelate.rawValue

    var color: NSColor { NSColor(hex: colorHex) }

    static let builtIn: [StylePreset] = [
        StylePreset(name: "Alert", colorHex: 0xFF3B30, width: 4),
        StylePreset(name: "Highlight", colorHex: 0xFFC200, width: 14, filled: true),
        StylePreset(name: "Note", colorHex: 0x34C759, width: 3, arrowStyle: 2),
        StylePreset(name: "Subtle", colorHex: 0xFFFFFF, width: 2, arrowStyle: 1),
    ]

    private static let key = "stylePresets"

    static func saved(in store: UserDefaults = .standard) -> [StylePreset] {
        guard let data = store.data(forKey: key), let list = try? JSONDecoder().decode([StylePreset].self, from: data) else { return [] }
        return list
    }

    /// Adds a preset, or replaces the one with the same name.
    static func save(_ preset: StylePreset, in store: UserDefaults = .standard) {
        var list = saved(in: store).filter { $0.name != preset.name }
        list.append(preset)
        if let data = try? JSONEncoder().encode(list) { store.set(data, forKey: key) }
    }

    static func delete(named name: String, in store: UserDefaults = .standard) {
        let list = saved(in: store).filter { $0.name != name }
        if let data = try? JSONEncoder().encode(list) { store.set(data, forKey: key) }
    }
}
