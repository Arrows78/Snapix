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

    /// The release archive to download: a .dmg if there is one, else a .zip, and only from GitHub over https.
    static func pickAsset(from json: [String: Any]) -> (url: URL, name: String)? {
        let assets = (json["assets"] as? [[String: Any]] ?? []).compactMap { a -> (URL, String)? in
            guard let s = a["browser_download_url"] as? String, let url = URL(string: s), let name = a["name"] as? String,
                  url.scheme == "https", let host = url.host, host == "github.com" || host.hasSuffix(".github.com") || host.hasSuffix(".githubusercontent.com") else { return nil }
            return (url, name)
        }
        return assets.first { $0.1.lowercased().hasSuffix(".dmg") } ?? assets.first { $0.1.lowercased().hasSuffix(".zip") }
    }

    /// Downloads the archive into Downloads and shows it in the Finder; installing it stays a manual step.
    @MainActor
    static func download(_ asset: (url: URL, name: String)) {
        Toast.show(L("Downloading the update…"), duration: 120)
        URLSession.shared.downloadTask(with: asset.url) { temp, resp, error in
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            var dest: URL?
            if let temp, error == nil, (200..<300).contains(status), let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first {
                let target = Exporter.uniqueURLUnchecked(in: folder, name: asset.name)
                if (try? FileManager.default.moveItem(at: temp, to: target)) != nil { dest = target }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let dest else { Toast.show(L("The download failed"), duration: 3, symbol: "exclamationmark.triangle.fill"); return }
                    Toast.show(LF("Downloaded %@", dest.lastPathComponent), duration: 3, symbol: "checkmark.circle.fill")
                    NSWorkspace.shared.activateFileViewerSelecting([dest])
                }
            }
        }.resume()
    }

    /// The release to offer: the latest stable one, or, on the beta channel, the newest of all releases (pre-releases included).
    static func pick(from releases: [[String: Any]], includePrereleases: Bool) -> [String: Any]? {
        releases.first { ($0["draft"] as? Bool) != true && (includePrereleases || ($0["prerelease"] as? Bool) != true) }
    }

    /// Looks for an update once a day at launch when the preference is on; only speaks up when there is one.
    @MainActor
    static func checkAtLaunch() {
        guard Pref.bool("updateCheckAtLaunch") else { return }
        let last = UserDefaults.standard.double(forKey: "lastUpdateCheck")
        guard Date().timeIntervalSince1970 - last > 86_400 else { return }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "lastUpdateCheck")
        run(quiet: true)
    }

    @MainActor
    static func run(quiet: Bool = false) {
        let beta = Pref.string("updateChannel") == "beta"
        guard let url = URL(string: beta ? "https://api.github.com/repos/Arrows78/Snapix/releases?per_page=10" : "https://api.github.com/repos/Arrows78/Snapix/releases/latest") else { return }
        if !quiet { Toast.show(L("Checking for updates…"), duration: 10) }
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 10
        URLSession.shared.dataTask(with: req) { data, _, _ in
            var json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            if beta, let list = data.flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] }) { json = pick(from: list, includePrereleases: true) }
            let tag = json?["tag_name"] as? String
            let page = (json?["html_url"] as? String).flatMap(URL.init(string:))
            let asset = json.flatMap { pickAsset(from: $0) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let tag else { if !quiet { Toast.show(L("Could not check for updates"), duration: 3, symbol: "exclamationmark.triangle.fill") }; return }
                    let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
                    guard isNewer(tag, than: current) else {
                        if !quiet { Toast.show(LF("Snapix %@ is up to date", current), duration: 3, symbol: "checkmark.circle.fill") }
                        return
                    }
                    let alert = NSAlert()
                    alert.messageText = LF("Snapix %@ is available", tag)
                    alert.informativeText = L("You are using version %@.").replacingOccurrences(of: "%@", with: current)
                    if asset != nil { alert.addButton(withTitle: L("Download")) }
                    alert.addButton(withTitle: L("View Release"))
                    alert.addButton(withTitle: L("Later"))
                    NSApp.activate(ignoringOtherApps: true)
                    let answer = alert.runModal()
                    if asset != nil, answer == .alertFirstButtonReturn, let asset { download(asset) }
                    else if (asset != nil && answer == .alertSecondButtonReturn) || (asset == nil && answer == .alertFirstButtonReturn), let page { NSWorkspace.shared.open(page) }
                }
            }
        }.resume()
    }
}
