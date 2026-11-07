import AppKit
import CryptoKit
import Foundation
import Security

/// AWS Signature Version 4 for S3-compatible storage (Amazon, Cloudflare R2, Backblaze, MinIO…).
enum SigV4 {
    static func hex(_ d: some Sequence<UInt8>) -> String { d.map { String(format: "%02x", $0) }.joined() }
    static func sha256Hex(_ data: Data) -> String { hex(SHA256.hash(data: data)) }
    private static func hmac(_ key: Data, _ message: String) -> Data { Data(HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: key))) }

    /// Percent-encoding of AWS: only unreserved characters stay; `/` stays in paths.
    static func encode(_ s: String, keepSlash: Bool) -> String {
        var allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        if keepSlash { allowed.insert("/") }
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    static func amzDate(_ date: Date) -> (stamp: String, day: String) {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let stamp = f.string(from: date)
        return (stamp, String(stamp.prefix(8)))
    }

    static func signingKey(secret: String, day: String, region: String) -> Data {
        let kDate = hmac(Data(("AWS4" + secret).utf8), day)
        return hmac(hmac(hmac(kDate, region), "s3"), "aws4_request")
    }

    static func scope(day: String, region: String) -> String { "\(day)/\(region)/s3/aws4_request" }

    /// The `Authorization` signature for a request whose canonical form is built from `method`, `path`, `query` and `headers`.
    static func signature(method: String, path: String, query: [(String, String)], headers: [String: String], payloadHash: String,
                          secret: String, region: String, stamp: String, day: String) -> (signature: String, signedHeaders: String) {
        let lower = headers.map { ($0.key.lowercased(), $0.value.trimmingCharacters(in: .whitespaces)) }.sorted { $0.0 < $1.0 }
        let canonicalHeaders = lower.map { "\($0.0):\($0.1)\n" }.joined()
        let signedHeaders = lower.map(\.0).joined(separator: ";")
        var pairs: [(String, String)] = []
        for (k, v) in query { pairs.append((encode(k, keepSlash: false), encode(v, keepSlash: false))) }
        pairs.sort { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }
        let canonicalQuery = pairs.map { "\($0.0)=\($0.1)" }.joined(separator: "&")
        let canonical = [method, path, canonicalQuery, canonicalHeaders, signedHeaders, payloadHash].joined(separator: "\n")
        let toSign = ["AWS4-HMAC-SHA256", stamp, scope(day: day, region: region), sha256Hex(Data(canonical.utf8))].joined(separator: "\n")
        let sig = hex(HMAC<SHA256>.authenticationCode(for: Data(toSign.utf8), using: SymmetricKey(data: signingKey(secret: secret, day: day, region: region))))
        return (sig, signedHeaders)
    }
}

/// Settings and requests for uploading to S3-compatible storage.
struct S3Config: Equatable {
    var endpoint: String
    var region: String
    var bucket: String
    var accessKey: String
    var secretKey: String
    var prefix: String
    var publicBase: String
    /// "none", "presigned" or "public".
    var linkMode: String
    var expiryDays: Int

    static var current: S3Config {
        S3Config(endpoint: Pref.string("s3Endpoint"), region: Pref.string("s3Region"), bucket: Pref.string("s3Bucket"), accessKey: Pref.string("s3AccessKey"),
                 secretKey: Keychain.get("s3SecretKey") ?? "", prefix: Pref.string("s3Prefix"), publicBase: Pref.string("s3PublicBase"),
                 linkMode: Pref.string("s3LinkMode"), expiryDays: UserDefaults.standard.integer(forKey: "s3ExpiryDays"))
    }

    var missing: String? {
        if bucket.trimmingCharacters(in: .whitespaces).isEmpty { return L("Enter the S3 bucket in the settings") }
        if accessKey.trimmingCharacters(in: .whitespaces).isEmpty { return L("Enter the S3 access key in the settings") }
        if secretKey.isEmpty { return L("Enter the S3 secret key in the settings") }
        if endpoint.trimmingCharacters(in: .whitespaces).isEmpty && region.trimmingCharacters(in: .whitespaces).isEmpty { return L("Enter the S3 region or endpoint in the settings") }
        return nil
    }

    var effectiveRegion: String { region.trimmingCharacters(in: .whitespaces).isEmpty ? "auto" : region.trimmingCharacters(in: .whitespaces) }

    /// Scheme and host: the custom endpoint, or Amazon's regional one.
    var base: URL? {
        let e = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        if e.isEmpty { return URL(string: "https://s3.\(effectiveRegion).amazonaws.com") }
        let withScheme = e.contains("://") ? e : "https://" + e
        guard var c = URLComponents(string: withScheme), c.host != nil else { return nil }
        c.path = ""
        return c.url
    }

    /// Object key for a file name: the prefix (trimmed of slashes) then the name.
    func key(for name: String) -> String {
        let p = prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        return p.isEmpty ? name : p + "/" + name
    }

    /// Path-style URL: `<base>/<bucket>/<key>`.
    func url(forKey key: String?) -> URL? {
        guard let base, var c = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        c.percentEncodedPath = "/" + SigV4.encode(bucket, keepSlash: false) + (key.map { "/" + SigV4.encode($0, keepSlash: true) } ?? "")
        return c.url
    }

    /// Signed request: PUT of `body` at `key`, or a HEAD on the bucket when `key` is nil.
    func request(method: String, key: String?, body: Data?, contentType: String?, date: Date = Date()) -> URLRequest? {
        guard let url = url(forKey: key), let host = url.host else { return nil }
        let (stamp, day) = SigV4.amzDate(date)
        let hash = SigV4.sha256Hex(body ?? Data())
        var headers = ["host": url.port.map { "\(host):\($0)" } ?? host, "x-amz-content-sha256": hash, "x-amz-date": stamp]
        if let contentType { headers["content-type"] = contentType }
        let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? "/"
        let (sig, signed) = SigV4.signature(method: method, path: path, query: [], headers: headers, payloadHash: hash, secret: secretKey, region: effectiveRegion, stamp: stamp, day: day)
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.httpBody = body
        req.timeoutInterval = 60
        for (k, v) in headers where k != "host" { req.setValue(v, forHTTPHeaderField: k) }
        req.setValue("AWS4-HMAC-SHA256 Credential=\(accessKey)/\(SigV4.scope(day: day, region: effectiveRegion)), SignedHeaders=\(signed), Signature=\(sig)", forHTTPHeaderField: "Authorization")
        return req
    }

    /// A GET link valid for `days` (1...7), signed in the query string.
    func presignedURL(forKey key: String, days: Int, date: Date = Date()) -> URL? {
        guard let url = url(forKey: key), let host = url.host else { return nil }
        let (stamp, day) = SigV4.amzDate(date)
        let seconds = max(1, min(7, days)) * 86_400
        let query: [(String, String)] = [("X-Amz-Algorithm", "AWS4-HMAC-SHA256"), ("X-Amz-Credential", "\(accessKey)/\(SigV4.scope(day: day, region: effectiveRegion))"),
                                         ("X-Amz-Date", stamp), ("X-Amz-Expires", String(seconds)), ("X-Amz-SignedHeaders", "host")]
        let hostHeader = url.port.map { "\(host):\($0)" } ?? host
        let encodedPath = SigV4.encode("/" + bucket + "/" + key, keepSlash: true)
        let (sig, _) = SigV4.signature(method: "GET", path: encodedPath, query: query, headers: ["host": hostHeader], payloadHash: "UNSIGNED-PAYLOAD",
                                       secret: secretKey, region: effectiveRegion, stamp: stamp, day: day)
        var c = URLComponents(url: url, resolvingAgainstBaseURL: false)
        c?.percentEncodedQuery = (query.map { "\(SigV4.encode($0.0, keepSlash: false))=\(SigV4.encode($0.1, keepSlash: false))" } + ["X-Amz-Signature=\(sig)"]).joined(separator: "&")
        return c?.url
    }

    /// The link to hand the user for an uploaded key, per the chosen mode (nil for "none").
    func link(forKey key: String) -> URL? {
        switch linkMode {
        case "presigned": return presignedURL(forKey: key, days: expiryDays > 0 ? expiryDays : 7)
        case "public":
            let b = publicBase.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
            return b.isEmpty ? nil : URL(string: b + "/" + SigV4.encode(key, keepSlash: true))
        default: return nil
        }
    }

    /// A readable explanation for an S3 HTTP status.
    static func explain(status: Int) -> String {
        switch status {
        case 301: return L("Wrong region or endpoint for this bucket")
        case 400: return L("Bad request: check the access key and endpoint")
        case 401, 403: return L("The server rejected the credentials or the signature")
        case 404: return L("Bucket or path not found")
        case 409: return L("Conflict with the bucket state")
        case 429: return L("Too many requests, try again later")
        default: return LF("The server answered HTTP %d", status)
        }
    }
}

/// Minimal generic-password Keychain access for secrets that must not sit in preferences.
enum Keychain {
    private static let service = "com.labs.snapix"

    static func get(_ account: String) -> String? {
        let q: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account, kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func set(_ value: String, for account: String) {
        let base: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return }
        var add = base
        add[kSecValueData] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}

/// Past uploads, newest first, so a link can be copied again.
struct UploadRecord: Codable, Equatable {
    var name: String
    var key: String
    var link: String?
    var date: Date
}

enum UploadLog {
    static let limit = 100
    private static var file: URL { History.folderURL.deletingLastPathComponent().appendingPathComponent("uploads.json") }

    static func all(from f: URL? = nil) -> [UploadRecord] {
        guard let data = try? Data(contentsOf: f ?? file) else { return [] }
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        return ((try? d.decode([UploadRecord].self, from: data)) ?? []).sorted { $0.date > $1.date }
    }

    static func add(_ r: UploadRecord, to f: URL? = nil) {
        var list = all(from: f).filter { $0.key != r.key }
        list.insert(r, at: 0)
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        let target = f ?? file
        try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? e.encode(Array(list.prefix(limit))) { try? data.write(to: target) }
    }

    static func clear() { try? FileManager.default.removeItem(at: file) }
}

@MainActor
enum S3Uploader {
    static func upload(data: Data, ext: String) {
        let cfg = S3Config.current
        if let problem = cfg.missing { Toast.show(problem, duration: 3.5, symbol: "exclamationmark.triangle.fill"); return }
        let name = Exporter.filename(ext: ext)
        let key = cfg.key(for: name)
        let type = ["png": "image/png", "jpg": "image/jpeg", "heic": "image/heic", "gif": "image/gif", "mp4": "video/mp4"][ext] ?? "application/octet-stream"
        guard let req = cfg.request(method: "PUT", key: key, body: data, contentType: type) else { Toast.show(L("The server address looks wrong"), symbol: "exclamationmark.triangle.fill"); return }
        Toast.show(L("Uploading…"), duration: 30)
        Task { @MainActor in
            do {
                let (_, resp) = try await URLSession.shared.data(for: req)
                let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
                guard (200..<300).contains(status) else { Toast.show(S3Config.explain(status: status), duration: 4, symbol: "exclamationmark.triangle.fill"); return }
                let link = cfg.link(forKey: key)
                UploadLog.add(UploadRecord(name: name, key: key, link: link?.absoluteString, date: Date()))
                if let link {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(link.absoluteString, forType: .string)
                    Toast.show(L("Link copied"), duration: 3, symbol: "checkmark.circle.fill")
                } else {
                    Toast.show(L("Uploaded"), duration: 3, symbol: "checkmark.circle.fill")
                }
            } catch {
                Toast.show(LF("Upload failed (%@)", error.localizedDescription), duration: 4, symbol: "exclamationmark.triangle.fill")
            }
        }
    }

    /// Checks the endpoint, credentials and bucket with a signed HEAD on the bucket.
    static func test() async -> String {
        let cfg = S3Config.current
        if let problem = cfg.missing { return problem }
        guard let req = cfg.request(method: "HEAD", key: nil, body: nil, contentType: nil) else { return L("The server address looks wrong") }
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            return (200..<300).contains(status) ? L("Connection successful") : S3Config.explain(status: status)
        } catch { return error.localizedDescription }
    }
}
