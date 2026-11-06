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
            textRequest.automaticallyDetectsLanguage = true
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

    @MainActor
    static func recognizeAndCopy(_ image: CGImage) {
        Toast.show(L("Recognizing…"), duration: 1)
        recognize(image, removeBreaks: Pref.bool("ocrRemoveBreaks")) { result in
            guard !result.isEmpty else { Toast.show(L("No text or QR code found")); return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(result.clipboardText, forType: .string)
            Toast.show(result.qrPayloads.isEmpty ? LF("Text copied (%d characters)", result.text.count) : L("QR code copied"))
        }
    }
}
