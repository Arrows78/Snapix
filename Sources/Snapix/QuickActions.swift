import Foundation

/// Which buttons a Quick Access card shows for a screenshot, in a fixed order.
enum QuickAction: String, CaseIterable {
    case edit, copy, save, ocr, pin

    var title: String {
        switch self {
        case .edit: return L("Open in Editor")
        case .copy: return L("Copy")
        case .save: return L("Save")
        case .ocr: return L("Recognize text / QR code")
        case .pin: return L("Pin to screen")
        }
    }

    static let `default`: [QuickAction] = QuickAction.allCases

    /// Parses the stored "edit,copy,…" list: unknown names are dropped, order is canonical, and an empty result falls back to all.
    static func parse(_ stored: String) -> [QuickAction] {
        let names = Set(stored.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        let picked = allCases.filter { names.contains($0.rawValue) }
        return picked.isEmpty ? `default` : picked
    }

    static func serialize(_ actions: [QuickAction]) -> String { allCases.filter(actions.contains).map(\.rawValue).joined(separator: ",") }

    static var current: [QuickAction] { parse(Pref.string("quickActions")) }
}
