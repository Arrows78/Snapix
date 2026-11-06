import Foundation

/// Looks the English text up in the app's Localizable.strings (falls back to the English key).
func L(_ key: String) -> String { NSLocalizedString(key, comment: "") }

/// Localized format string, e.g. LF("Saved %@", name).
func LF(_ key: String, _ args: CVarArg...) -> String { String(format: L(key), arguments: args) }
