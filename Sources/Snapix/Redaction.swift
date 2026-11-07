import AppKit
import Vision

/// Finds text that should not be shared (emails, card and bank numbers, phone numbers, secrets, IP addresses).
enum Redaction {
    enum Kind: CaseIterable {
        case email, card, iban, secret, phone, ipAddress

        var prefKey: String {
            switch self {
            case .email: return "redact.email"
            case .card: return "redact.card"
            case .iban: return "redact.iban"
            case .secret: return "redact.secret"
            case .phone: return "redact.phone"
            case .ipAddress: return "redact.ipAddress"
            }
        }

        /// On unless the user turned it off in Preferences.
        var isEnabled: Bool { UserDefaults.standard.object(forKey: prefKey) as? Bool ?? true }

        var pattern: String {
            switch self {
            case .email: return #"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#
            case .card: return #"\b\d(?:[ \-]?\d){12,18}\b"#
            case .iban: return #"\b[A-Z]{2}\d{2}(?:[ ]?[A-Z0-9]{4}){2,7}(?:[ ]?[A-Z0-9]{1,4})?\b"#
            case .secret: return #"\b(?:sk-[A-Za-z0-9_\-]{16,}|gh[pousr]_[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16}|xox[abprs]-[A-Za-z0-9\-]{10,}|eyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}|[A-Fa-f0-9]{32,}|[A-Za-z0-9+/_\-]{40,})\b"#
            case .phone: return #"(?<![\w.])(?:\+|00)?\d{1,3}?[ .\-]?\(?\d{1,4}\)?(?:[ .\-]?\d{2,4}){2,4}(?![\w])"#
            case .ipAddress: return #"\b(?:(?:25[0-5]|2[0-4]\d|1?\d?\d)\.){3}(?:25[0-5]|2[0-4]\d|1?\d?\d)\b"#
            }
        }

        /// Cheap sanity check on top of the pattern, to keep false positives down.
        func accepts(_ s: String) -> Bool {
            let digits = s.filter(\.isNumber)
            switch self {
            case .card: return (13...19).contains(digits.count) && Redaction.luhn(digits)
            case .iban: return Redaction.ibanChecksum(s)
            case .phone: return (8...15).contains(digits.count) && !Redaction.looksLikeDateOrDecimal(s)
            case .secret: return s.contains { $0.isNumber } && s.contains { $0.isLetter }
            default: return true
            }
        }
    }

    private static let expressions: [(Kind, NSRegularExpression)] = Kind.allCases.compactMap { k in
        (try? NSRegularExpression(pattern: k.pattern)).map { (k, $0) }
    }

    /// Ranges of `text` that look sensitive, merged so that overlapping hits (a card number also matching as a phone number) count once.
    static func ranges(in text: String) -> [Range<String.Index>] {
        let ns = text as NSString
        var found: [NSRange] = []
        for (kind, re) in expressions where kind.isEnabled {
            for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) where kind.accepts(ns.substring(with: m.range)) {
                found.append(m.range)
            }
        }
        var merged: [NSRange] = []
        for r in found.sorted(by: { $0.location < $1.location }) {
            if let last = merged.last, r.location <= last.location + last.length {
                merged[merged.count - 1] = NSUnionRange(last, r)
            } else {
                merged.append(r)
            }
        }
        return merged.compactMap { Range($0, in: text) }
    }

    static func luhn(_ digits: String) -> Bool {
        var sum = 0
        for (i, ch) in digits.reversed().enumerated() {
            guard var d = ch.wholeNumberValue else { return false }
            if i % 2 == 1 { d *= 2; if d > 9 { d -= 9 } }
            sum += d
        }
        return sum % 10 == 0
    }

    /// ISO 7064 mod 97-10, as used by IBANs.
    static func ibanChecksum(_ s: String) -> Bool {
        let iban = s.filter { !$0.isWhitespace }.uppercased()
        guard (15...34).contains(iban.count) else { return false }
        let rearranged = iban.dropFirst(4) + iban.prefix(4)
        var rem = 0
        for ch in rearranged {
            guard let v = ch.isNumber ? ch.wholeNumberValue : ch.asciiValue.map({ Int($0) - 55 }) else { return false }
            rem = (v > 9 ? rem * 100 + v : rem * 10 + v) % 97
        }
        return rem == 1
    }

    /// Filters out "2024-11-07", "3.14159" or "1 234 567" which the phone pattern would otherwise accept.
    static func looksLikeDateOrDecimal(_ s: String) -> Bool {
        s.range(of: #"^\d{1,4}[\-/.]\d{1,2}[\-/.]\d{1,4}$"#, options: .regularExpression) != nil
            || s.range(of: #"^\d+\.\d+$"#, options: .regularExpression) != nil
    }

    /// Pixel boxes (top-left origin) of every sensitive piece of text in the image.
    static func findBoxes(in image: CGImage, completion: @escaping ([CGRect]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let req = VNRecognizeTextRequest()
            req.recognitionLevel = .accurate
            req.usesLanguageCorrection = false
            try? VNImageRequestHandler(cgImage: image, options: [:]).perform([req])
            let w = CGFloat(image.width), h = CGFloat(image.height)
            var boxes: [CGRect] = []
            for obs in req.results ?? [] {
                guard let cand = obs.topCandidates(1).first else { continue }
                for range in ranges(in: cand.string) {
                    guard let b = try? cand.boundingBox(for: range)?.boundingBox else { continue }
                    boxes.append(CGRect(x: b.minX * w, y: (1 - b.maxY) * h, width: b.width * w, height: b.height * h))
                }
            }
            DispatchQueue.main.async { completion(boxes) }
        }
    }
}
