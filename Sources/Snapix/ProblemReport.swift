import AppKit

/// Builds a GitHub "new issue" link prefilled with version info and recent log lines. Nothing is sent until the user submits it in the browser.
enum ProblemReport {
    /// Characters beyond this make browsers or GitHub reject the link.
    static let maxBodyLength = 3500

    static func url(diagnostics: String, log: String) -> URL? {
        var body = "**What happened?**\n\n\n**Diagnostics**\n```\n\(diagnostics)\n```\n"
        if !log.isEmpty { body += "\n**Recent log**\n```\n\(log)\n```\n" }
        if body.count > maxBodyLength { body = String(body.prefix(maxBodyLength)) + "\n…```" }
        var c = URLComponents(string: "https://github.com/Arrows78/Snapix/issues/new")
        c?.queryItems = [URLQueryItem(name: "title", value: "Problem: "), URLQueryItem(name: "body", value: body)]
        return c?.url
    }

    @MainActor
    static func open() {
        if let u = url(diagnostics: PreferencesView.diagnostics, log: DiagnosticLog.recent(maxLines: 25)) { NSWorkspace.shared.open(u) }
    }
}
