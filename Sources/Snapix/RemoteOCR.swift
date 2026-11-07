import AppKit

/// Text recognition by a server of your choice that speaks the common "chat completions" format with image input.
/// Nothing is sent unless the engine is switched to Custom in Preferences.
enum RemoteOCR {
    struct Config: Equatable {
        var baseURL: String
        var model: String
        var prompt: String
        var apiKey: String

        static var current: Config {
            Config(baseURL: Pref.string("ocrEndpoint"), model: Pref.string("ocrModel"), prompt: Pref.string("ocrPrompt"), apiKey: Pref.string("ocrAPIKey"))
        }

        var isUsable: Bool { endpoint != nil && !model.trimmingCharacters(in: .whitespaces).isEmpty }

        /// `<base>/chat/completions`, tolerating a trailing slash or an already complete path.
        var endpoint: URL? {
            var s = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            while s.hasSuffix("/") { s.removeLast() }
            guard !s.isEmpty else { return nil }
            if !s.hasSuffix("/chat/completions") { s += "/chat/completions" }
            guard let url = URL(string: s), let scheme = url.scheme, scheme == "http" || scheme == "https", url.host != nil else { return nil }
            return url
        }
    }

    static let defaultPrompt = "Transcribe all the text in this image exactly as written. Reply with the text only, no commentary."

    enum Failure: Error { case notConfigured, encoding, http(Int), malformed, message(String) }

    /// The request for `png`, or for a text-only ping when `png` is nil (used to test the connection).
    static func request(_ config: Config, png: Data?) throws -> URLRequest {
        guard let url = config.endpoint, config.isUsable else { throw Failure.notConfigured }
        let prompt = config.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        var content: [[String: Any]] = [["type": "text", "text": png == nil ? "Reply with the single word OK." : (prompt.isEmpty ? defaultPrompt : prompt)]]
        if let png { content.append(["type": "image_url", "image_url": ["url": "data:image/png;base64," + png.base64EncodedString()]]) }
        let body: [String: Any] = ["model": config.model, "messages": [["role": "user", "content": content]], "temperature": 0]
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 60
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !config.apiKey.isEmpty { req.setValue("Bearer " + config.apiKey, forHTTPHeaderField: "Authorization") }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }

    /// The reply text of a chat-completions response (a plain string or a list of text parts).
    static func parse(_ data: Data) throws -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.malformed }
        if let err = json["error"] as? [String: Any], let m = err["message"] as? String { throw Failure.message(m) }
        guard let message = (json["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any] else { throw Failure.malformed }
        if let text = message["content"] as? String { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let parts = message["content"] as? [[String: Any]] {
            return parts.compactMap { $0["text"] as? String }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        throw Failure.malformed
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case Failure.notConfigured: return L("Set the server address and model in Preferences › Editor first")
        case Failure.encoding: return L("Could not prepare the image")
        case let Failure.http(code): return LF("The server answered HTTP %d", code)
        case Failure.malformed: return L("The server's answer was not understood")
        case let Failure.message(m): return m
        default: return error.localizedDescription
        }
    }

    /// PNG of `image`, scaled down so its longest side stays within `maxSide` pixels.
    nonisolated static func pngData(_ image: CGImage, maxSide: Int = 2000) -> Data? {
        var img = image
        let longest = max(image.width, image.height)
        if longest > maxSide {
            let k = CGFloat(maxSide) / CGFloat(longest)
            let w = max(1, Int(CGFloat(image.width) * k)), h = max(1, Int(CGFloat(image.height) * k))
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: Renderer.sRGB,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            ctx.interpolationQuality = .high
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            guard let scaled = ctx.makeImage() else { return nil }
            img = scaled
        }
        return NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])
    }

    /// Sends the image and returns the recognised text.
    static func recognize(_ image: CGImage, config: Config = .current) async throws -> String {
        guard let png = pngData(image) else { throw Failure.encoding }
        return try await send(try request(config, png: png))
    }

    /// Checks the address, key and model with a text-only request; returns the round-trip time in milliseconds.
    static func test(config: Config = .current) async throws -> Int {
        let start = Date()
        _ = try await send(try request(config, png: nil))
        return Int(Date().timeIntervalSince(start) * 1000)
    }

    private static func send(_ req: URLRequest) async throws -> String {
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let code = (resp as? HTTPURLResponse)?.statusCode, !(200..<300).contains(code) {
            if let m = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? [String: Any], let text = m["message"] as? String { throw Failure.message(text) }
            throw Failure.http(code)
        }
        return try parse(data)
    }
}
