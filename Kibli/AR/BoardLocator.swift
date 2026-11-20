import CoreGraphics
import CoreVideo
import Foundation
import simd

/// Runs the rectify, find-grid, build-pose pipeline off the main thread.
final class BoardLocator: @unchecked Sendable {
    struct Request: Sendable {
        let luma: LumaPlane
        let intrinsics: simd_float3x3
        let camera: simd_float4x4
        let planeY: Float
        let center: SIMD2<Float>
        /// Board corners on the table plane when the board is already
        /// locked. Tracking refines these instead of searching from scratch.
        let predicted: [SIMD3<Float>]?
        let wantsDebugImage: Bool
    }

    struct Detection: @unchecked Sendable {
        let pose: BoardPose?
        /// True when this came from refining a known board rather than a
        /// fresh search.
        var tracked = false
        /// The grid corners projected onto the plane the search assumed, before
        /// any correction for how far the board's surface sits above it.
        let observation: BoardObservation?
        let checker: Int
        let edge: Float
        var score: Float = 0
        /// While tracking: how much better the grid scores moved one square
        /// in each of `GridFinder.shifts[1...]` than where it is.
        var shiftLeads: [Float]?
        let debugImage: CGImage?
        /// How many of the best grid's corners were inside the camera image,
        /// 0 to 4, whether or not it was good enough to accept.
        var cornersInView = 0
    }

    var minimumChecker = 55
    var minimumEdge: Float = 12
    /// Tracking already knows roughly where the board is, so it can accept
    /// a partly hidden one.
    var minimumTrackingChecker = 35

    private let finder = GridFinder()
    private let queue = DispatchQueue(label: "sh.dunkirk.kibli.locator", qos: .userInitiated)
    private let lock = NSLock()
    private var busy = false

    /// Returns false without doing anything if a search is still running.
    func locate(_ request: Request, completion: @escaping @Sendable (Detection?) -> Void) -> Bool {
        lock.lock()
        if busy {
            lock.unlock()
            return false
        }
        busy = true
        lock.unlock()

        queue.async { [self] in
            let detection = run(request)
            lock.lock()
            busy = false
            lock.unlock()
            completion(detection)
        }
        return true
    }

    private func run(_ request: Request) -> Detection? {
        let tracking = request.predicted != nil
        let searched: (image: TopDownImage, grid: GridFinder.Result?)?
        if let predicted = request.predicted {
            searched = BoardSearch.track(
                luma: request.luma, intrinsics: request.intrinsics, camera: request.camera,
                planeY: request.planeY, predicted: predicted, finder: finder
            )
        } else {
            searched = BoardSearch.locate(
                luma: request.luma, intrinsics: request.intrinsics, camera: request.camera,
                planeY: request.planeY, center: request.center, finder: finder
            )
        }
        guard let searched else { return nil }
        let image = searched.image

        guard let grid = searched.grid else {
            return Detection(pose: nil, observation: nil, checker: 0, edge: 0, debugImage: request.wantsDebugImage ? Self.debugImage(image, corners: nil) : nil)
        }

        var pose: BoardPose?
        var observation: BoardObservation?
        if grid.checker >= (tracking ? minimumTrackingChecker : minimumChecker), grid.edge >= minimumEdge {
            let corners = grid.corners.map(image.world)
            pose = BoardPose.fromCorners(corners, camera: request.camera.translation).map {
                Self.orientDarkA1($0, in: image)
            }
            observation = BoardObservation(
                corners: corners, planeY: request.planeY, camera: request.camera.translation
            )
        }
        return Detection(
            pose: pose,
            tracked: tracking,
            observation: observation,
            checker: grid.checker,
            edge: grid.edge,
            score: grid.score,
            shiftLeads: tracking ? Self.leads(image, grid.corners) : nil,
            debugImage: request.wantsDebugImage ? Self.debugImage(image, corners: grid.corners) : nil,
            cornersInView: grid.corners.map(image.world).filter { Self.inView($0, request) }.count
        )
    }

    private static func leads(_ image: TopDownImage, _ corners: [SIMD2<Float>]) -> [Float] {
        let scores = GridFinder.shiftScores(image, corners: corners)
        return scores.dropFirst().map { $0 - scores[0] }
    }

    private static func inView(_ world: SIMD3<Float>, _ request: Request) -> Bool {
        let p = request.camera.inverse * SIMD4(world, 1)
        guard -p.z > 0.05 else { return false }
        let k = request.intrinsics
        let u = k.columns.2.x + k.columns.0.x * p.x / -p.z
        let v = k.columns.2.y - k.columns.1.y * p.y / -p.z
        return u >= 0 && v >= 0 && u < Float(request.luma.width) && v < Float(request.luma.height)
    }

    /// a1 is always a dark square. Votes over every neighbouring pair of
    /// squares (so pieces on a few squares don't matter) and turns the board a
    /// quarter if the pattern says the corner is light.
    private static func orientDarkA1(_ pose: BoardPose, in image: TopDownImage) -> BoardPose {
        let square = pose.side / 8
        let radius = 0.3 * square / image.metersPerPixel
        var means = [[Float?]](repeating: [Float?](repeating: nil, count: 8), count: 8)
        for file in 0..<8 {
            for rank in 0..<8 {
                let local = SIMD4<Float>(
                    (-4 + Float(file) + 0.5) * square, 0, (4 - Float(rank) - 0.5) * square, 1
                )
                let world = pose.transform * local
                means[file][rank] = image.mean(around: image.pixel(SIMD3(world.x, world.y, world.z)), radius: radius)
            }
        }

        var votes = 0
        for file in 0..<8 {
            for rank in 0..<8 {
                guard let here = means[file][rank] else { continue }
                let expectBrighterNeighbour = (file + rank) % 2 == 0
                for (df, dr) in [(1, 0), (0, 1)] where file + df < 8 && rank + dr < 8 {
                    guard let there = means[file + df][rank + dr], abs(there - here) > 12 else { continue }
                    votes += (there > here) == expectBrighterNeighbour ? 1 : -1
                }
            }
        }

        guard votes < 0 else { return pose }
        var turned = pose
        turned.yaw += .pi / 2
        return turned
    }

    private static func debugImage(_ image: TopDownImage, corners: [SIMD2<Float>]?) -> CGImage? {
        let n = image.size
        var bytes = [UInt8](repeating: 0, count: n * n)
        for i in 0..<(n * n) where image.valid[i] {
            bytes[i] = UInt8(min(max(image.pixels[i], 0), 255))
        }
        if let corners {
            let h = Homography(unitSquareTo: corners, scale: 8)
            for line in 0...8 {
                for t in stride(from: Float(0), through: 8, by: 0.01) {
                    for p in [h.apply(SIMD2(Float(line), t)), h.apply(SIMD2(t, Float(line)))] {
                        let x = Int(p.x), y = Int(p.y)
                        if x >= 0, y >= 0, x < n, y < n { bytes[y * n + x] = 255 }
                    }
                }
            }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(
            width: n, height: n, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: n,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )
    }
}
