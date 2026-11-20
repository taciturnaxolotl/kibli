// Renders the move detector's board snapshot for captures that saved a
// locked board pose, and diffs consecutive ones.
// usage: snapshot [captures dir] [out dir]
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import simd

struct Meta: Decodable {
    struct Board: Decodable { let center: [Float]; let yaw: Float; let side: Float; let quarterTurns: Int }
    let intrinsics: [Float]
    let cameraTransform: [Float]
    let board: Board?
}

func luma(_ url: URL) -> LumaPlane? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
    var buffer: CVPixelBuffer?
    CVPixelBufferCreate(nil, image.width, image.height, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, nil, &buffer)
    guard let buffer else { return nil }
    CVPixelBufferLockBaseAddress(buffer, [])
    let context = CGContext(data: CVPixelBufferGetBaseAddressOfPlane(buffer, 0), width: image.width, height: image.height,
                            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRowOfPlane(buffer, 0),
                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0)!
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    CVPixelBufferUnlockBaseAddress(buffer, [])
    return LumaPlane(buffer)
}

let args = CommandLine.arguments
let dir = URL(fileURLWithPath: args.count > 1 ? args[1] : "samples/captures")
let out = URL(fileURLWithPath: args.count > 2 ? args[2] : "/tmp/kibli_snap")
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
var last: (String, BoardSnapshot)?
for name in try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() {
    let folder = dir.appendingPathComponent(name)
    guard let data = try? Data(contentsOf: folder.appendingPathComponent("meta.json")),
          let meta = try? JSONDecoder().decode(Meta.self, from: data), let b = meta.board,
          let plane = luma(folder.appendingPathComponent("frame.jpg")) else { continue }
    let k = meta.intrinsics, t = meta.cameraTransform
    let intrinsics = simd_float3x3(columns: (SIMD3(k[0], k[3], k[6]), SIMD3(k[1], k[4], k[7]), SIMD3(k[2], k[5], k[8])))
    let camera = simd_float4x4(columns: (SIMD4(t[0], t[1], t[2], t[3]), SIMD4(t[4], t[5], t[6], t[7]),
                                         SIMD4(t[8], t[9], t[10], t[11]), SIMD4(t[12], t[13], t[14], t[15])))
    let pose = BoardPose(center: SIMD3(b.center[0], b.center[1], b.center[2]),
                         yaw: b.yaw + Float(b.quarterTurns) * .pi / 2, side: b.side)
    guard let snap = BoardSnapshot(luma: plane, intrinsics: intrinsics, cameraTransform: camera, board: pose.transform, side: pose.side) else {
        print("\(name): snapshot failed (board out of view)"); continue
    }
    var pgm = Data("P5\n\(BoardSnapshot.size) \(BoardSnapshot.size)\n255\n".utf8)
    pgm.append(contentsOf: snap.pixels.map { UInt8(min(max($0, 0), 255)) })
    try pgm.write(to: out.appendingPathComponent("\(name).pgm"))
    print(String(format: "%@ camera(board units)=(%.1f, %.1f, %.1f) start=%@", name, snap.camera.x, snap.camera.y, snap.camera.z,
                 snap.startOrientation().map(String.init) ?? "-"))
    let fen = ProcessInfo.processInfo.environment["FEN_\(name.suffix(10).replacingOccurrences(of: "-", with: "_"))"]
    let position = fen.flatMap { Position(fen: $0) } ?? .start
    let bare = Occupancy.expectedBare(position, camera: snap.camera)
    if ProcessInfo.processInfo.environment["STATS"] != nil {
        let st = snap.squareStats()
        for rank in (0..<8).reversed() {
            print("   " + (0..<8).map { f -> String in let s = st[rank * 8 + f]; return String(format: "%@%3.0f/%2.0f/%2.0f", bare[rank * 8 + f] ? "." : "#", s.mean, s.deviation, s.edges) }.joined(separator: " "))
        }
    }
    if let observed = Occupancy.bareness(snap, reference: bare) {
        print("  predicted bare (.) vs covered (#), with observed bareness 0-9:")
        for rank in (0..<8).reversed() {
            let row = (0..<8).map { file -> String in
                let i = rank * 8 + file
                return (bare[i] ? "." : "#") + String(Int(min(observed[i] * 9.99, 9)))
            }
            print("   \(rank + 1) " + row.joined(separator: " "))
        }
        print(String(format: "  agreement with %@: %.1f  fit %.2f  empty fit %.2f", fen == nil ? "start" : "given", Occupancy.agreement(bare, observed), Occupancy.fit(position, snap) ?? -9, Occupancy.fit(Occupancy.empty, snap) ?? -9))
        // Compare against every legal move from the start, to see how sharp it is.
        var scores: [(Float, String)] = []
        for move in position.legalMoves() {
            let next = position.playing(move)
            let b = Occupancy.expectedBare(next, camera: snap.camera)
            if let o = Occupancy.bareness(snap, reference: b) {
                scores.append((Occupancy.agreement(b, o), position.san(move)))
            }
        }
        scores.sort { $0.0 > $1.0 }
        print("  best moves: " + scores.prefix(4).map { String(format: "%@ %.1f", $0.1, $0.0) }.joined(separator: ", "))
    }
    if ProcessInfo.processInfo.environment["SEARCH"] != nil {
        let t0 = Date()
        let found = Occupancy.search(from: .start, plies: 4, beam: 40, snapshot: snap)
        print(String(format: "  search from start (%.0fms):", Date().timeIntervalSince(t0) * 1000))
        for line in found.prefix(5) {
            var p = Position.start
            let san = line.moves.map { m -> String in let s = p.san(m); p = p.playing(m); return s }
            print(String(format: "    %5.1f %@", line.score, san.isEmpty ? "(no moves)" : san.joined(separator: " ")))
        }
    }
    if let (prevName, prev) = last {
        let d = snap.difference(from: prev)
        print("  vs \(prevName): camera moved \(String(format: "%.2f", simd_distance(snap.camera, prev.camera))) squares")
        for rank in (0..<8).reversed() {
            print("   " + (0..<8).map { String(format: "%4.0f", d[rank * 8 + $0]) }.joined())
        }
    }
    last = (name, snap)
}
