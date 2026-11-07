import AppKit
import Vision

enum OCR {
    struct Result {
        var text: String
        var qrPayloads: [String]
        /// What ends up on the clipboard: QR payloads win over free text.
        var clipboardText: String { qrPayloads.isEmpty ? text : qrPayloads.joined(separator: "\n") }
        var isEmpty: Bool { clipboardText.isEmpty }
    }

    static func recognize(_ image: CGImage, removeBreaks: Bool, completion: @escaping (Result) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let textRequest = VNRecognizeTextRequest()
            textRequest.recognitionLevel = .accurate
            textRequest.usesLanguageCorrection = true
            let lang = Pref.string("ocrLanguage")
            if lang.isEmpty || lang == "auto" {
                textRequest.automaticallyDetectsLanguage = true
            } else {
                textRequest.recognitionLanguages = [lang]
                textRequest.automaticallyDetectsLanguage = false
            }
            let barcodeRequest = VNDetectBarcodesRequest()

            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            try? handler.perform([textRequest, barcodeRequest])

            let lines = (textRequest.results ?? [])
                .sorted { $0.boundingBox.midY > $1.boundingBox.midY }
                .compactMap { $0.topCandidates(1).first?.string }
            let text = lines.joined(separator: removeBreaks ? " " : "\n")
            let codes = (barcodeRequest.results ?? []).compactMap { $0.payloadStringValue }
            DispatchQueue.main.async { completion(Result(text: text, qrPayloads: codes)) }
        }
    }

    /// Line-level boxes of the text found in `region`, in image pixel coordinates (top-left origin).
    static func textBoxes(in image: CGImage, region: CGRect, completion: @escaping ([CGRect]) -> Void) {
        let r = region.integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard r.width >= 4, r.height >= 4, let crop = image.cropping(to: r) else { completion([]); return }
        DispatchQueue.global(qos: .userInitiated).async {
            let req = VNRecognizeTextRequest()
            req.recognitionLevel = .accurate
            try? VNImageRequestHandler(cgImage: crop, options: [:]).perform([req])
            let boxes = (req.results ?? []).map { o -> CGRect in
                let b = o.boundingBox // normalized, origin bottom-left
                return CGRect(x: r.minX + b.minX * r.width, y: r.minY + (1 - b.maxY) * r.height, width: b.width * r.width, height: b.height * r.height)
            }
            DispatchQueue.main.async { completion(boxes) }
        }
    }

    /// Languages Vision can recognise with the accurate model, for the preferences picker.
    static var supportedLanguages: [String] {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        return (try? req.supportedRecognitionLanguages()) ?? []
    }

    /// Web links (http, https, www) found in `text`, in order and without duplicates.
    static func links(in text: String) -> [URL] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        var seen = Set<URL>()
        return detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { $0.url }
            .filter { $0.scheme == "http" || $0.scheme == "https" }
            .filter { seen.insert($0).inserted }
    }

    @MainActor
    static func recognizeAndCopy(_ image: CGImage) {
        Toast.show(L("Recognizing…"), duration: 1)
        recognize(image, removeBreaks: Pref.bool("ocrRemoveBreaks")) { result in
            guard !result.isEmpty else { Toast.show(L("No text or QR code found"), symbol: "exclamationmark.triangle.fill"); return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(result.clipboardText, forType: .string)
            Toast.show(result.qrPayloads.isEmpty ? LF("Text copied (%d characters)", result.text.count) : L("QR code copied"), symbol: "checkmark.circle.fill")
            if Pref.bool("ocrDetectLinks"), let link = links(in: result.clipboardText).first {
                let alert = NSAlert()
                alert.messageText = L("Link detected")
                alert.informativeText = link.absoluteString
                alert.addButton(withTitle: L("Open Link"))
                alert.addButton(withTitle: L("Not Now"))
                NSApp.activate(ignoringOtherApps: true)
                if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(link) }
            }
        }
    }
}
