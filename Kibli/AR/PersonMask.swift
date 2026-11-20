#if canImport(ARKit) && os(iOS)
import ARKit
#endif
import CoreVideo
import Foundation

/// A private copy of ARKit's person segmentation mask: which pixels of the
/// camera image show a person (in practice, hands and arms over the board).
/// It is lower resolution than the camera image but lines up with it.
struct PersonMask: Sendable {
    let width: Int
    let height: Int
    let bytes: [UInt8]

    init(width: Int, height: Int, bytes: [UInt8]) {
        self.width = width
        self.height = height
        self.bytes = bytes
    }

    #if canImport(ARKit) && os(iOS)
    init?(_ frame: ARFrame) {
        guard let buffer = frame.segmentationBuffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let source = base.assumingMemoryBound(to: UInt8.self)
        var bytes = [UInt8](repeating: 0, count: w * h)
        for row in 0..<h {
            for col in 0..<w { bytes[row * w + col] = source[row * stride + col] }
        }
        width = w
        height = h
        self.bytes = bytes
    }
    #endif

    /// Whether a point in camera-image pixels (of an image `imageWidth`
    /// wide) shows a person.
    func isPerson(u: Float, v: Float, imageWidth: Int) -> Bool {
        let scale = Float(width) / Float(imageWidth)
        let x = Int(u * scale), y = Int(v * scale)
        guard x >= 0, y >= 0, x < width, y < height else { return false }
        return bytes[y * width + x] > 127
    }

    /// Width and height as UInt16, then one byte per pixel.
    var encoded: Data {
        var data = Data()
        withUnsafeBytes(of: UInt16(width).littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt16(height).littleEndian) { data.append(contentsOf: $0) }
        data.append(contentsOf: bytes)
        return data
    }
}
