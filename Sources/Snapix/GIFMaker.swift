import ImageIO
import UniformTypeIdentifiers

/// Builds animated GIFs from pictures.
enum GIFMaker {
    /// A looping GIF showing each frame for `delay` seconds; nil when there is nothing to encode.
    static func data(frames: [CGImage], delay: Double) -> Data? {
        guard !frames.isEmpty else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.gif.identifier as CFString, frames.count, nil) else { return nil }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let props = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: max(0.02, delay)]] as CFDictionary
        for f in frames { CGImageDestinationAddImage(dest, f, props) }
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }

    static func frameCount(of data: Data) -> Int {
        CGImageSourceCreateWithData(data as CFData, nil).map(CGImageSourceGetCount) ?? 0
    }
}
