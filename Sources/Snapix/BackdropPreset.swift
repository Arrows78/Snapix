import Foundation

/// A named backdrop look (colours, padding, corners, pattern…) the user can bring back with one click.
struct BackdropPreset: Codable, Equatable {
    static let limit = 20
    var name: String
    var config: BackdropConfig

    private static let key = "backdropPresets"

    static func saved(in store: UserDefaults = .standard) -> [BackdropPreset] {
        guard let data = store.data(forKey: key), let list = try? JSONDecoder().decode([BackdropPreset].self, from: data) else { return [] }
        return list
    }

    /// Adds or replaces (by name) a preset; false when the limit is reached for a new name.
    @discardableResult
    static func save(_ preset: BackdropPreset, in store: UserDefaults = .standard) -> Bool {
        var list = saved(in: store)
        if let i = list.firstIndex(where: { $0.name == preset.name }) { list[i] = preset }
        else if list.count >= limit { return false }
        else { list.append(preset) }
        if let data = try? JSONEncoder().encode(list) { store.set(data, forKey: key) }
        return true
    }

    static func delete(named name: String, in store: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(saved(in: store).filter { $0.name != name }) { store.set(data, forKey: key) }
    }
}
