// Replays saved captures through the real board pipeline (rectify, find grid,
// pose) on the Mac, timing each stage and writing the top-down debug view.
// usage: replay [captures dir] [out dir]
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import simd

struct Meta: Decodable {
    let timestamp: String
    let imageWidth: Int
    let imageHeight: Int
    let intrinsics: [Float]
    let cameraTransform: [Float]
    let tablePlaneY: Float?
}

func lumaBuffer(_ url: URL) -> CVPixelBuffer? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
    let w = image.width, h = image.height
    var buffer: CVPixelBuffer?
    CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, nil, &buffer)
    guard let buffer else { return nil }
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!
    let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
    let context = CGContext(data: base, width: w, height: h, bitsPerComponent: 8, bytesPerRow: stride,
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0)!
    context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    return buffer
}

let args = CommandLine.arguments
let dir = URL(fileURLWithPath: args.count > 1 ? args[1] : "samples/captures")
let out = URL(fileURLWithPath: args.count > 2 ? args[2] : "/tmp/kibli_replay")
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

var sessions: [[(name: String, observation: BoardObservation, edge: Float)]] = []
var frames: [String: (luma: LumaPlane, intrinsics: simd_float3x3, camera: simd_float4x4)] = [:]
var lastTime: Date?
let iso = ISO8601DateFormatter()

for name in try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() {
    let folder = dir.appendingPathComponent(name)
    guard let data = try? Data(contentsOf: folder.appendingPathComponent("meta.json")),
          let meta = try? JSONDecoder().decode(Meta.self, from: data),
          let planeY = meta.tablePlaneY,
          let buffer = lumaBuffer(folder.appendingPathComponent("frame.jpg"))
    else { print("\(name): skipped"); continue }

    let k = meta.intrinsics
    let intrinsics = simd_float3x3(columns: (SIMD3(k[0], k[3], k[6]), SIMD3(k[1], k[4], k[7]), SIMD3(k[2], k[5], k[8])))
    let t = meta.cameraTransform
    let camera = simd_float4x4(columns: (
        SIMD4(t[0], t[1], t[2], t[3]), SIMD4(t[4], t[5], t[6], t[7]),
        SIMD4(t[8], t[9], t[10], t[11]), SIMD4(t[12], t[13], t[14], t[15])))
    let origin = SIMD3(camera.columns.3.x, camera.columns.3.y, camera.columns.3.z)
    let forward = -SIMD3(camera.columns.2.x, camera.columns.2.y, camera.columns.2.z)
    let tHit = (planeY - origin.y) / forward.y
    let hit = origin + forward * tHit

    let t0 = Date()
    var finder = GridFinder()
    if let v = ProcessInfo.processInfo.environment["FLAT"].flatMap(Float.init) { finder.flatVariance = v }
    guard let found = BoardSearch.locate(luma: LumaPlane(buffer)!, intrinsics: intrinsics, camera: camera, planeY: planeY,
                                         center: SIMD2(hit.x, hit.z), finder: finder)
    else { print("\(name): rectify failed"); continue }
    let t1 = t0
    let image = found.image, grid = found.grid
    let t2 = Date()

    if let grid, grid.checker >= 55, grid.edge > 12 {
        let nudged = grid.corners.enumerated().map { $1 + SIMD2(Float($0 % 2 == 0 ? 6 : -5), Float($0 < 2 ? 5 : -6)) }
        let t3 = Date()
        if let tracked = finder.track(in: image, predicted: nudged) {
            let back = zip(tracked.corners, grid.corners).map { simd_distance($0, $1) }.max()!
            print(String(format: "    track: back within %.1fpx checker=%d %.0fms", back, tracked.checker, Date().timeIntervalSince(t3) * 1000))
        } else { print("    track: lost") }
    }
    let validFraction = Float(image.valid.filter { $0 }.count) / Float(image.valid.count)
    if let grid, let time = iso.date(from: meta.timestamp) {
        if lastTime == nil || time.timeIntervalSince(lastTime!) > 30 { sessions.append([]) }
        lastTime = time
        var observation = BoardObservation(corners: grid.corners.map(image.world), planeY: planeY, camera: origin)
        observation.time = time.timeIntervalSinceReferenceDate
        sessions[sessions.count - 1].append((name, observation, grid.edge))
        frames[name] = (LumaPlane(buffer)!, intrinsics, camera)
    }
    if let grid {
        let sides = (0..<4).map { simd_distance(grid.corners[$0], grid.corners[($0 + 1) % 4]) * 2 }
        print(String(format: "%@ dist=%.2fm valid=%.0f%% checker=%3d edge=%5.1f side=%5.1fmm rectify=%.0fms find=%.0fms",
                     name, tHit, validFraction * 100, grid.checker, grid.edge, sides.reduce(0, +) / 4,
                     t1.timeIntervalSince(t0) * 1000, t2.timeIntervalSince(t1) * 1000))
    } else {
        print("\(name): no grid")
    }

    let n = image.size
    var bytes = image.pixels.map { UInt8(min(max($0, 0), 255)) }
    if let grid {
        let h = Homography(unitSquareTo: grid.corners, scale: 8)
        for i in 0...8 {
            for s in stride(from: Float(0), through: 8, by: 0.01) {
                for p in [h.apply(SIMD2(Float(i), s)), h.apply(SIMD2(s, Float(i)))] {
                    let x = Int(p.x), y = Int(p.y)
                    if x >= 0, y >= 0, x < n, y < n { bytes[y * n + x] = 0 }
                }
            }
        }
    }
    var pgm = Data("P5\n\(n) \(n)\n255\n".utf8)
    pgm.append(contentsOf: bytes)
    try pgm.write(to: out.appendingPathComponent("\(name).pgm"))
}

// Self-consistency: within a session the board doesn't move, so each frame's
// height-corrected center should agree with the fused estimate. A frame a
// square off shows up as roughly 4 cm of error.
print("\nconsistency (error from session fusion)")
var slid = 0, total = 0
for session in sessions where session.count >= 3 {
    var estimator = BoardEstimator()
    estimator.window = .infinity
    for frame in session { estimator.add(frame.observation) }
    guard let height = estimator.height(), let fused = estimator.pose(referenceYaw: 0) else { continue }
    for frame in session {
        let corners = frame.observation.corners(atHeight: height)
        let center = corners.reduce(.zero, +) / 4
        let error = simd_distance(center, fused.center)
        total += 1
        if error > 0.02 { slid += 1 }
        print(String(format: "  %@ error=%5.1fcm %@", frame.name, error * 100, error > 0.02 ? "SLID" : ""))
    }
}
print("slid \(slid)/\(total)")

// Board snapshots from the fused pose, and how much they differ frame to
// frame. Nothing moved within these sessions except where noted, so this is
// the noise the move detector has to see past.
print("\nsnapshots")
for session in sessions where session.count >= 3 {
    var estimator = BoardEstimator()
    estimator.window = .infinity
    for frame in session { estimator.add(frame.observation) }
    guard let fused = estimator.pose(referenceYaw: 0) else { continue }
    var last: BoardSnapshot?
    for frame in session {
        guard let f = frames[frame.name],
              let snap = BoardSnapshot(luma: f.luma, intrinsics: f.intrinsics, cameraTransform: f.camera,
                                       board: fused.transform, side: fused.side) else { continue }
        var pgm = Data("P5\n\(BoardSnapshot.size) \(BoardSnapshot.size)\n255\n".utf8)
        pgm.append(contentsOf: snap.pixels.map { UInt8(min(max($0, 0), 255)) })
        try pgm.write(to: out.appendingPathComponent("snap_\(frame.name).pgm"))
        if let last {
            let d = snap.difference(from: last)
            let sorted = d.sorted()
            print(String(format: "  %@ median=%5.1f p90=%5.1f max=%5.1f", frame.name, sorted[32], sorted[57], sorted[63]))
        }
        last = snap
        print("  \(frame.name) start orientation: \(snap.startOrientation().map(String.init) ?? "not a start position")")
    }
}
