// Times each per-frame stage of the pipeline on one recorded frame.
// usage: bench <recording dir> [seconds into recording]
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import simd

let root = URL(fileURLWithPath: CommandLine.arguments[1])
let at = Double(CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "120")!
var pose: [String: Any]?, frame: [String: Any]?, start: Double?
for line in try String(contentsOf: root.appendingPathComponent("log.jsonl"), encoding: .utf8).split(separator: "\n") {
    guard let r = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], let kind = r["kind"] as? String else { continue }
    let wall = r["wall"] as! Double
    if start == nil { start = wall }
    if kind == "pose" { pose = r }
    if kind == "frame", r["image"] != nil, wall - start! >= at, pose != nil { frame = r; break }
}
guard let frame, let pose else { fatalError("no frame") }
let src = CGImageSourceCreateWithURL(root.appendingPathComponent(frame["image"] as! String) as CFURL, nil)!
let half = CGImageSourceCreateImageAtIndex(src, 0, nil)!
// Recorded frames are half size; upscale to the phone's 1920x1440 so costs match.
let W = half.width * 2, H = half.height * 2
var buffer: CVPixelBuffer?
CVPixelBufferCreate(nil, W, H, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, nil, &buffer)
CVPixelBufferLockBaseAddress(buffer!, [])
CGContext(data: CVPixelBufferGetBaseAddressOfPlane(buffer!, 0), width: W, height: H, bitsPerComponent: 8,
          bytesPerRow: CVPixelBufferGetBytesPerRowOfPlane(buffer!, 0), space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0)!
    .draw(half, in: CGRect(x: 0, y: 0, width: W, height: H))
CVPixelBufferUnlockBaseAddress(buffer!, [])

let k = (frame["intrinsics"] as! [Double]).map(Float.init)
let K = simd_float3x3(columns: (SIMD3(k[0], k[3], k[6]), SIMD3(k[1], k[4], k[7]), SIMD3(k[2], k[5], k[8])))
let t = (frame["camera"] as! [Double]).map(Float.init)
let C = simd_float4x4(columns: (SIMD4(t[0], t[1], t[2], t[3]), SIMD4(t[4], t[5], t[6], t[7]), SIMD4(t[8], t[9], t[10], t[11]), SIMD4(t[12], t[13], t[14], t[15])))
let c = (pose["center"] as! [Double]).map(Float.init)
let bp = BoardPose(center: SIMD3(c[0], c[1], c[2]), yaw: Float(pose["yaw"] as! Double) + Float(pose["quarterTurns"] as? Int ?? 0) * .pi / 2, side: Float(pose["side"] as! Double))
let eye = SIMD3(t[12], t[13], t[14])
let planeY = bp.center.y - 0.015

func time(_ name: String, _ n: Int = 20, _ body: () -> Void) {
    body()
    let t0 = Date()
    for _ in 0..<n { body() }
    let ms = Date().timeIntervalSince(t0) * 1000 / Double(n)
    print(name.padding(toLength: 30, withPad: " ", startingAt: 0) + String(format: "%8.2f ms", ms))
}

var luma: LumaPlane!
time("LumaPlane copy") { luma = LumaPlane(buffer!) }
let h = bp.side / 2
let predicted = [SIMD4<Float>(-h, 0, -h, 1), SIMD4(h, 0, -h, 1), SIMD4(h, 0, h, 1), SIMD4(-h, 0, h, 1)].map { v -> SIMD3<Float> in
    let w = bp.transform * v; let p = SIMD3(w.x, w.y, w.z)
    return eye + (p - eye) * ((planeY - eye.y) / (p.y - eye.y))
}
var img: TopDownImage!
time("rectify 500x500") { img = TopDownImage.rectify(luma: luma, intrinsics: K, cameraTransform: C, planeY: planeY, center: SIMD2(bp.center.x, bp.center.z), size: 500, metersPerPixel: 0.002) }
let finder = GridFinder()
var grid: GridFinder.Result?
time("track (refine+score)") { grid = finder.track(in: img, predicted: predicted.map(img.pixel)) }
time("shiftScores (5 scores)") { _ = GridFinder.shiftScores(img, corners: grid!.corners) }
time("fresh find", 3) { _ = finder.find(in: img) }
var snap: BoardSnapshot!
time("BoardSnapshot") { snap = BoardSnapshot(luma: luma, intrinsics: K, cameraTransform: C, board: bp.transform, side: bp.side) }
let pos = Position.start.playing(Position.start.legalMoves()[0])
time("expectedBare") { _ = Occupancy.expectedBare(pos, camera: snap.camera) }
time("Occupancy.fit (one position)") { _ = Occupancy.fit(pos, snap) }
time("fit x all legal moves", 5) { for m in pos.legalMoves() { _ = Occupancy.fit(pos.playing(m), snap) } }
time("legalMoves") { _ = pos.legalMoves() }
