import AppKit

/// Asks GitHub for the latest release, only when the user chooses "Check for Updates".
enum UpdateCheck {
    /// True when `latest` is a newer semantic version than `current` ("v1.2.0" and "1.2" are accepted).
    static func isNewer(_ latest: String, than current: String) -> Bool {
        func parts(_ s: String) -> [Int] { s.trimmingCharacters(in: CharacterSet(charactersIn: "vV")).split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 } }
        let a = parts(latest), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    @MainActor
    static func run() {
        guard let url = URL(string: "https://api.github.com/repos/Arrows78/Snapix/releases/latest") else { return }
        Toast.show(L("Checking for updates…"), duration: 10)
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 10
        URLSession.shared.dataTask(with: req) { data, _, _ in
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let tag = json?["tag_name"] as? String
            let page = (json?["html_url"] as? String).flatMap(URL.init(string:))
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let tag else { Toast.show(L("Could not check for updates"), duration: 3, symbol: "exclamationmark.triangle.fill"); return }
                    let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
                    guard isNewer(tag, than: current) else {
                        Toast.show(LF("Snapix %@ is up to date", current), duration: 3, symbol: "checkmark.circle.fill")
                        return
                    }
                    let alert = NSAlert()
                    alert.messageText = LF("Snapix %@ is available", tag)
                    alert.informativeText = L("You are using version %@.").replacingOccurrences(of: "%@", with: current)
                    alert.addButton(withTitle: L("View Release"))
                    alert.addButton(withTitle: L("Later"))
                    NSApp.activate(ignoringOtherApps: true)
                    if alert.runModal() == .alertFirstButtonReturn, let page { NSWorkspace.shared.open(page) }
                }
            }
        }.resume()
    }
}
