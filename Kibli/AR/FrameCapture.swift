import ARKit
import CoreImage
import Foundation

/// Saves the raw camera frame plus everything needed to reproject it onto the
/// board: intrinsics, camera pose and the locked board pose. With the board
/// pose known, every square can be cropped later, which makes these frames
/// cheap training data for piece detection and replay fixtures for the board
/// finder.
///
/// Captures land in Documents/captures, visible in the Files app.
enum FrameCapture {
    struct Metadata: Codable {
        let timestamp: Date
        let imageWidth: Int
        let imageHeight: Int
        /// Row-major 3x3, pixels of the saved image (sensor orientation).
        let intrinsics: [Float]
        /// Column-major 4x4 camera-to-world.
        let cameraTransform: [Float]
        let tablePlaneY: Float?
        let board: Board?
        var note: String?

        struct Board: Codable {
            let center: [Float]
            let yaw: Float
            let side: Float
            /// Extra quarter turns the user applied to put a1 in the right corner.
            let quarterTurns: Int
        }
    }

    static var directory: URL {
        URL.documentsDirectory.appending(path: "captures", directoryHint: .isDirectory)
    }

    static func save(frame: ARFrame, board: BoardPose?, quarterTurns: Int, tablePlaneY: Float?) async throws -> URL {
        let image = CIImage(cvPixelBuffer: frame.capturedImage)
        let depth = DepthPlane(frame)
        let intrinsics = frame.camera.intrinsics
        let transform = frame.camera.transform
        let metadata = Metadata(
            timestamp: .now,
            imageWidth: CVPixelBufferGetWidth(frame.capturedImage),
            imageHeight: CVPixelBufferGetHeight(frame.capturedImage),
            intrinsics: (0..<3).flatMap { row in (0..<3).map { col in intrinsics[col][row] } },
            cameraTransform: (0..<4).flatMap { col in (0..<4).map { row in transform[col][row] } },
            tablePlaneY: tablePlaneY,
            board: board.map {
                .init(center: [$0.center.x, $0.center.y, $0.center.z], yaw: $0.yaw, side: $0.side, quarterTurns: quarterTurns)
            }
        )

        return try await Task.detached(priority: .utility) {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
            let folder = directory.appending(path: formatter.string(from: metadata.timestamp), directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

            let context = CIContext()
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let jpeg = context.jpegRepresentation(
                    of: image, colorSpace: space,
                    options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.92]
                  )
            else { throw CocoaError(.fileWriteUnknown) }
            try jpeg.write(to: folder.appending(path: "frame.jpg"))
            if let depth { try depth.encoded.write(to: folder.appending(path: "depth.bin")) }

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(metadata).write(to: folder.appending(path: "meta.json"))
            return folder
        }.value
    }

    static var count: Int {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path()).count) ?? 0
    }
}
