#if canImport(ARKit) && os(iOS)
import ARKit
#endif
import Foundation
import simd

/// A private copy of ARKit's LiDAR depth map and its confidence, aligned with
/// the camera image but much smaller (256x192 on current phones).
struct DepthPlane: Sendable {
    let width: Int
    let height: Int
    /// Meters along the camera's viewing axis.
    let depth: [Float]
    /// 0 low, 1 medium, 2 high.
    let confidence: [UInt8]

    #if canImport(ARKit) && os(iOS)
    init?(_ frame: ARFrame) {
        guard let scene = frame.smoothedSceneDepth ?? frame.sceneDepth else { return nil }
        let map = scene.depthMap
        CVPixelBufferLockBaseAddress(map, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(map, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(map) else { return nil }
        let w = CVPixelBufferGetWidth(map), h = CVPixelBufferGetHeight(map)
        let stride = CVPixelBufferGetBytesPerRow(map) / MemoryLayout<Float32>.size
        let source = base.assumingMemoryBound(to: Float32.self)
        var depth = [Float](repeating: 0, count: w * h)
        for row in 0..<h {
            for col in 0..<w { depth[row * w + col] = source[row * stride + col] }
        }

        var confidence = [UInt8](repeating: 2, count: w * h)
        if let conf = scene.confidenceMap {
            CVPixelBufferLockBaseAddress(conf, .readOnly)
            if let cbase = CVPixelBufferGetBaseAddress(conf) {
                let cstride = CVPixelBufferGetBytesPerRow(conf)
                let csource = cbase.assumingMemoryBound(to: UInt8.self)
                for row in 0..<h {
                    for col in 0..<w { confidence[row * w + col] = csource[row * cstride + col] }
                }
            }
            CVPixelBufferUnlockBaseAddress(conf, .readOnly)
        }
        width = w
        height = h
        self.depth = depth
        self.confidence = confidence
    }
    #endif

    /// Little-endian: width and height as UInt16, then depth in millimeters
    /// as UInt16 per pixel, then confidence as UInt8 per pixel.
    var encoded: Data {
        var data = Data()
        func put16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        put16(UInt16(width))
        put16(UInt16(height))
        for d in depth { put16(UInt16(min(max(d * 1000, 0), 65535))) }
        data.append(contentsOf: confidence)
        return data
    }

    init(width: Int, height: Int, depth: [Float], confidence: [UInt8]) {
        self.width = width
        self.height = height
        self.depth = depth
        self.confidence = confidence
    }

    /// How far the board's surface is stood above in each square, from the
    /// LiDAR points that land on it. Points are placed in true 3D, so a piece
    /// shows up on its own square rather than smeared over the ones behind it
    /// the way it is in the camera image. Squares the sensor can't see get nil.
    ///
    /// `imageIntrinsics` are for the full camera image of `imageWidth` pixels;
    /// they are scaled down to the depth map. Heights are in squares, indexed
    /// rank * 8 + file, with the board frame as in `BoardSnapshot`.
    func squareHeights(
        imageIntrinsics: simd_float3x3, imageWidth: Int,
        cameraTransform: simd_float4x4, board: simd_float4x4, side: Float
    ) -> [Float?] {
        let scale = Float(width) / Float(imageWidth)
        let fx = imageIntrinsics.columns.0.x * scale, fy = imageIntrinsics.columns.1.y * scale
        let cx = imageIntrinsics.columns.2.x * scale, cy = imageIntrinsics.columns.2.y * scale
        let toBoard = board.inverse * cameraTransform
        let half = side / 2
        let square = side / 8

        var samples = [[Float]](repeating: [], count: 64)
        for row in 0..<height {
            for col in 0..<width {
                let i = row * width + col
                guard confidence[i] >= 1 else { continue }
                let d = depth[i]
                guard d > 0.1, d < 3 else { continue }
                // Camera space: x right, y up, looking down -z.
                let local = SIMD4((Float(col) + 0.5 - cx) / fx * d, -(Float(row) + 0.5 - cy) / fy * d, -d, 1)
                let p = toBoard * local
                let file = Int(floor((p.x + half) / square))
                let rank = Int(floor((half - p.z) / square))
                guard (0..<8).contains(file), (0..<8).contains(rank) else { continue }
                // Stay away from the square's edges, where a neighbour's
                // piece can lean over.
                let fx = (p.x + half) / square - Float(file), fz = (half - p.z) / square - Float(rank)
                guard fx > 0.12, fx < 0.88, fz > 0.12, fz < 0.88 else { continue }
                samples[rank * 8 + file].append(p.y / square)
            }
        }

        return samples.map { values in
            guard values.count >= 4 else { return nil }
            // A piece only covers part of its square, so look at the tallest
            // points, but not the very tallest, which are often flying pixels.
            let sorted = values.sorted()
            return sorted[min(sorted.count - 1, sorted.count * 85 / 100)]
        }
    }
}
