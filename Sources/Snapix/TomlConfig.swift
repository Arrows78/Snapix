import Foundation

/// A small, human-editable `config.toml` mirror of the settings: one `key = value` line each, with comments.
/// Only flat values are written (booleans, numbers, strings, and binary blobs as "base64:…").
enum TomlConfig {
    static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/snapix/config.toml")
    }

    private static func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n") + "\""
    }

    private static func render(_ value: Any) -> String? {
        switch value {
        case let b as Bool: return b ? "true" : "false"
        case let d as Data: return quote("base64:" + d.base64EncodedString())
        case let s as String: return quote(s)
        case let n as NSNumber:
            // Booleans arrive as NSNumber too; CFBoolean is handled above, so what is left is numeric.
            let d = n.doubleValue
            return d == d.rounded() && !CFNumberIsFloatType(n) ? String(n.int64Value) : String(d)
        default: return nil
        }
    }

    static func encode(_ settings: [String: Any]) -> String {
        var out = "# Snapix settings. Edit a value and choose \"Apply config.toml\" in Preferences (or restart Snapix).\n# Secrets (upload header, API keys) are never written here.\n\n[settings]\n"
        for key in settings.keys.sorted() {
            if let v = render(settings[key]) { out += "\"\(key)\" = \(v)\n" }
        }
        return out
    }

    private static func unquote(_ s: String) -> String? {
        guard s.count >= 2, s.hasPrefix("\""), s.hasSuffix("\"") else { return nil }
        var out = "", escaped = false
        for ch in s.dropFirst().dropLast() {
            if escaped { out.append(ch == "n" ? "\n" : ch); escaped = false }
            else if ch == "\\" { escaped = true }
            else { out.append(ch) }
        }
        return out
    }

    /// The quoted string at the start of `s`, up to its closing quote (honouring backslash escapes); anything after it, such as a comment, is dropped.
    private static func closedString(_ s: String) -> String {
        var escaped = false
        var end = s.startIndex
        for i in s.indices.dropFirst() {
            if escaped { escaped = false; continue }
            if s[i] == "\\" { escaped = true; continue }
            if s[i] == "\"" { end = i; break }
        }
        return end == s.startIndex ? s : String(s[...end])
    }

    /// Parses what `encode` writes, tolerating comments, blank lines, other sections and unquoted keys.
    static func decode(_ text: String) -> [String: Any] {
        var result: [String: Any] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix("["), let eq = line.firstIndex(of: "=") else { continue }
            var key = line[..<eq].trimmingCharacters(in: .whitespaces)
            if let k = unquote(key) { key = k }
            var value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\"") { value = closedString(value) }
            else if let hash = value.firstIndex(of: "#") { value = value[..<hash].trimmingCharacters(in: .whitespaces) }
            guard !key.isEmpty else { continue }
            if let s = unquote(value) {
                if s.hasPrefix("base64:"), let d = Data(base64Encoded: String(s.dropFirst(7))) { result[key] = d } else { result[key] = s }
            } else if value == "true" || value == "false" { result[key] = value == "true" }
            else if let i = Int(value) { result[key] = i }
            else if let d = Double(value) { result[key] = d }
        }
        return result
    }
}

extension Pref {
    /// Current settings as the dictionary that goes into config.toml (the same keys a backup holds).
    static func configDictionary(from store: UserDefaults = .standard) -> [String: Any] {
        store.dictionaryRepresentation().filter { isBackedUp($0.key) }
    }

    /// Writes config.toml, creating its folder; returns false on failure.
    @discardableResult
    static func writeConfigFile(to url: URL = TomlConfig.defaultURL, from store: UserDefaults = .standard) -> Bool {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try TomlConfig.encode(configDictionary(from: store)).write(to: url, atomically: true, encoding: .utf8)
            return true
        } catch { return false }
    }

    /// Applies config.toml; returns how many settings changed value, or nil when the file is missing or holds nothing usable.
    @discardableResult
    static func applyConfigFile(at url: URL = TomlConfig.defaultURL, into store: UserDefaults = .standard) -> Int? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let parsed = TomlConfig.decode(text).filter { isBackedUp($0.key) }
        guard !parsed.isEmpty else { return nil }
        var changed = 0
        for (k, v) in parsed {
            if let old = store.object(forKey: k), (old as AnyObject).isEqual(v) { continue }
            store.set(v, forKey: k)
            changed += 1
        }
        return changed
    }
}
