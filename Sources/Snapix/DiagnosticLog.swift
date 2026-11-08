import AppKit
import UserNotifications

/// One small log file per day, kept on this Mac only, so a problem can be described precisely in a bug report.
enum DiagnosticLog {
    static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Snapix/Logs", isDirectory: true)
    }

    nonisolated static func fileName(for date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date) + ".log"
    }

    nonisolated static func line(_ message: String, category: String, at date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss"
        return "\(f.string(from: date)) [\(category)] \(message.replacingOccurrences(of: "\n", with: " "))\n"
    }

    private static let queue = DispatchQueue(label: "snapix.log", qos: .utility)

    /// Appends a line to today's file when logging is on.
    static func write(_ message: String, category: String = "app") {
        guard UserDefaults.standard.object(forKey: "diagnosticLogs") as? Bool ?? true else { return }
        let now = Date()
        queue.async {
            let dir = folder
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent(fileName(for: now))
            guard let data = line(message, category: category, at: now).data(using: .utf8) else { return }
            if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(data); try? h.close() } else { try? data.write(to: url) }
        }
    }

    /// Deletes log files older than `days` days; returns how many were removed.
    @discardableResult
    nonisolated static func prune(in dir: URL, keepingDays days: Int, now: Date = Date()) -> Int {
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -max(1, days), to: now) else { return 0 }
        let cutoffName = fileName(for: cutoff)
        var removed = 0
        for url in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] where url.pathExtension == "log" && url.lastPathComponent < cutoffName {
            if (try? FileManager.default.removeItem(at: url)) != nil { removed += 1 }
        }
        return removed
    }

    static func pruneNow() { prune(in: folder, keepingDays: UserDefaults.standard.object(forKey: "logDays") as? Int ?? 7) }

    /// The last `maxLines` lines across the newest files, for the bug report.
    static func recent(maxLines: Int = 40) -> String {
        let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "log" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
        var lines: [String] = []
        for f in files.prefix(3) {
            let text = (try? String(contentsOf: f, encoding: .utf8)) ?? ""
            lines = text.split(separator: "\n").map { "\(f.deletingPathExtension().lastPathComponent) \($0)" } + lines
            if lines.count >= maxLines { break }
        }
        return lines.suffix(maxLines).joined(separator: "\n")
    }

    static func clear() { try? FileManager.default.removeItem(at: folder) }
}

/// System notifications as an alternative (or addition) to the on-screen bubble.
@MainActor
enum Notifier {
    nonisolated static func mode() -> String {
        let m = UserDefaults.standard.string(forKey: "confirmationStyle") ?? "bubble"
        return ["bubble", "system", "both"].contains(m) ? m : "bubble"
    }

    static var showsBubble: Bool { mode() != "system" }
    static var postsSystem: Bool { mode() != "bubble" }

    static func post(_ text: String) {
        guard postsSystem else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Snapix"
            content.body = text
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}
