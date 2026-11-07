import AppKit
import CoreImage
import Vision

/// Isolates the foreground subject of an image on a transparent background, using Vision's on-device segmentation.
enum Cutout {
    static func subject(of image: CGImage, completion: @escaping (CGImage?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var result: CGImage?
            let req = VNGenerateForegroundInstanceMaskRequest()
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            if (try? handler.perform([req])) != nil, let obs = req.results?.first, !obs.allInstances.isEmpty,
               let buffer = try? obs.generateMaskedImage(ofInstances: obs.allInstances, from: handler, croppedToInstancesExtent: false) {
                let ci = CIImage(cvPixelBuffer: buffer)
                result = CIContext().createCGImage(ci, from: ci.extent, format: .RGBA8, colorSpace: Renderer.sRGB)
            }
            DispatchQueue.main.async { completion(result) }
        }
    }
}
