import ARKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A flight recorder for tuning. While on, it writes a JSON line for every
/// camera frame (pose, intrinsics, tracking state) and every decision the
/// app makes (detections, locks, relocks, move reads), plus a half-size
/// grayscale camera image twice a second. Enough to replay a session on the
/// Mac and see why the board slid or a move was misread.
///
/// Recordings land in Documents/recordings/<start time>/, next to captures.
@MainActor
final class Recorder {
    private(set) var isRecording = false
    private(set) var folder: URL?
    private(set) var startedAt: Date?

    private let queue = DispatchQueue(label: "sh.dunkirk.kibli.recorder", qos: .utility)
    private nonisolated(unsafe) var handle: FileHandle?
    private var lastFrameLog: TimeInterval = 0
    private var lastImage: TimeInterval = 0
    private var imageIndex = 0

    static var directory: URL {
        URL.documentsDirectory.appending(path: "recordings", directoryHint: .isDirectory)
    }

    func start() {
        guard !isRecording else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let now = Date.now
        let folder = Self.directory.appending(path: formatter.string(from: now), directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: folder.appending(path: "frames"), withIntermediateDirectories: true)
            let log = folder.appending(path: "log.jsonl")
            FileManager.default.createFile(atPath: log.path(), contents: nil)
            handle = try FileHandle(forWritingTo: log)
        } catch {
            return
        }
        self.folder = folder
        startedAt = now
        imageIndex = 0
        lastFrameLog = 0
        lastImage = 0
        isRecording = true
        log("start", ["device": UIDevice.current.model, "system": UIDevice.current.systemVersion])
    }

    func stop() {
        guard isRecording else { return }
        log("stop", [:])
        isRecording = false
        queue.async { [self] in
            try? handle?.close()
            handle = nil
        }
    }

    /// Logs an event. Values must be JSON-friendly: numbers, strings, bools,
    /// arrays and dictionaries of those.
    func log(_ kind: String, _ fields: [String: Any], time: TimeInterval? = nil) {
        guard isRecording else { return }
        var record = fields
        record["kind"] = kind
        record["wall"] = Date.now.timeIntervalSince1970
        if let time { record["t"] = time }
        guard let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) else { return }
        queue.async { [self] in
            handle?.write(data)
            handle?.write(Data([0x0A]))
        }
    }

    /// Logs the camera pose about ten times a second and saves an image
    /// twice a second.
    func frame(_ frame: ARFrame, luma: () -> LumaPlane?, mask: () -> PersonMask?) {
        guard isRecording, frame.timestamp - lastFrameLog >= 0.1 else { return }
        lastFrameLog = frame.timestamp

        var fields: [String: Any] = [
            "camera": frame.camera.transform.array,
            "intrinsics": frame.camera.intrinsics.array,
            "tracking": Self.describe(frame.camera.trackingState),
            "exposure": frame.camera.exposureDuration,
        ]
        if frame.timestamp - lastImage >= 0.5, let plane = luma() {
            lastImage = frame.timestamp
            imageIndex += 1
            let name = String(format: "frames/%06d.jpg", imageIndex)
            fields["image"] = name
            fields["imageScale"] = 0.5
            let url = folder!.appending(path: name)
            queue.async { Self.writeHalfSize(plane, to: url) }
            if let mask = mask() {
                let maskName = String(format: "frames/%06d.mask", imageIndex)
                fields["mask"] = maskName
                let maskURL = folder!.appending(path: maskName)
                queue.async { try? mask.encoded.write(to: maskURL) }
            }
        }
        log("frame", fields, time: frame.timestamp)
    }

    private nonisolated static func writeHalfSize(_ plane: LumaPlane, to url: URL) {
        let w = plane.width / 2, h = plane.height / 2
        var bytes = [UInt8](repeating: 0, count: w * h)
        plane.bytes.withUnsafeBufferPointer { src in
            for y in 0..<h {
                for x in 0..<w {
                    let i = 2 * y * plane.width + 2 * x
                    let sum = Int(src[i]) + Int(src[i + 1]) + Int(src[i + plane.width]) + Int(src[i + plane.width + 1])
                    bytes[y * w + x] = UInt8(sum / 4)
                }
            }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(
                width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
              ),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        CGImageDestinationFinalize(destination)
    }

    private static func describe(_ state: ARCamera.TrackingState) -> String {
        switch state {
        case .normal: "normal"
        case .notAvailable: "unavailable"
        case .limited(.initializing): "initializing"
        case .limited(.excessiveMotion): "excessiveMotion"
        case .limited(.insufficientFeatures): "insufficientFeatures"
        case .limited(.relocalizing): "relocalizing"
        case .limited: "limited"
        }
    }

    static var count: Int {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path()).count) ?? 0
    }
}

extension simd_float4x4 {
    /// Column-major, the way simd stores it.
    var array: [Float] { (0..<4).flatMap { c in (0..<4).map { r in self[c][r] } } }
}

extension simd_float3x3 {
    /// Row-major, matching the capture metadata.
    var array: [Float] { (0..<3).flatMap { r in (0..<3).map { c in self[c][r] } } }
}

extension SIMD3<Float> {
    var array: [Float] { [x, y, z] }
}

extension SIMD2<Float> {
    var array: [Float] { [x, y] }
}
