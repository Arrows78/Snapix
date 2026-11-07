import AppKit

/// The look a tool had the last time it was used: colour, thickness and its own options.
struct ToolStyle: Codable, Equatable {
    var hex: UInt32
    var width: CGFloat
    var arrowStyle = 0
    var filled = false
    var dashed = false
    var dotted = false
    var blur = BlurMode.pixelate.rawValue

    /// Tools that have no colour or thickness to remember.
    static func remembers(_ tool: Tool) -> Bool { ![.select, .crop, .overlay, .spotlight].contains(tool) }

    private static func key(_ tool: Tool) -> String { "toolStyle.\(tool.rawValue)" }

    static func load(_ tool: Tool, from store: UserDefaults = .standard) -> ToolStyle? {
        guard let data = store.data(forKey: key(tool)) else { return nil }
        return try? JSONDecoder().decode(ToolStyle.self, from: data)
    }

    static func save(_ style: ToolStyle, for tool: Tool, in store: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(style) { store.set(data, forKey: key(tool)) }
    }

    static func forget(in store: UserDefaults = .standard) {
        for t in Tool.allCases { store.removeObject(forKey: key(t)) }
    }
}
