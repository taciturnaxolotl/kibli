// For each recorded frame, compares where the app drew the board with where
// the grid actually is in that frame, in millimetres on the board.
// usage: overlaycheck <recording dir>
import CoreGraphics
import Foundation
import ImageIO
import simd

let root = URL(fileURLWithPath: CommandLine.arguments[1])
func luma(_ url: URL) -> LumaPlane? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
    var bytes = [UInt8](repeating: 0, count: img.width * img.height)
    let ctx = CGContext(data: &bytes, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width,
                        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0)!
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
    return LumaPlane(width: img.width, height: img.height, bytes: bytes)
}
var pose: [String: Any]?
var lastOffset: SIMD2<Float>?
var staleErrors: [Float] = [], rawErrors: [Float] = []
var start: Double?
let finder = GridFinder()
for line in try String(contentsOf: root.appendingPathComponent("log.jsonl"), encoding: .utf8).split(separator: "\n") {
    guard let r = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], let kind = r["kind"] as? String else { continue }
    let wall = r["wall"] as! Double
    if start == nil { start = wall }
    if kind == "pose" { pose = r }
    guard kind == "frame", let image = r["image"] as? String, let pose, let plane = luma(root.appendingPathComponent(image)) else { continue }
    let scale = Float(r["imageScale"] as? Double ?? 1)
    let k = (r["intrinsics"] as! [Double]).map(Float.init)
    let intr = simd_float3x3(columns: (SIMD3(k[0] * scale, k[3], k[6]), SIMD3(k[1], k[4] * scale, k[7]), SIMD3(k[2] * scale, k[5] * scale, k[8])))
    let t = (r["camera"] as! [Double]).map(Float.init)
    let cam = simd_float4x4(columns: (SIMD4(t[0], t[1], t[2], t[3]), SIMD4(t[4], t[5], t[6], t[7]), SIMD4(t[8], t[9], t[10], t[11]), SIMD4(t[12], t[13], t[14], t[15])))
    // Prefer the drawn (corrected) pose when the recording has it.
    let drawn = (pose["display"] as? [String: Any]) ?? pose
    let c = (drawn["center"] as! [Double]).map(Float.init)
    let bp = BoardPose(center: SIMD3(c[0], c[1], c[2]), yaw: Float(drawn["yaw"] as! Double), side: Float(drawn["side"] as! Double))
    let h = bp.side / 2
    let corners = [SIMD4<Float>(-h, 0, -h, 1), SIMD4(h, 0, -h, 1), SIMD4(h, 0, h, 1), SIMD4(-h, 0, h, 1)].map { v -> SIMD3<Float> in
        let w = bp.transform * v; return SIMD3(w.x, w.y, w.z)
    }
    // Rectify at the board's own height so the top-down view is exact.
    guard let img = TopDownImage.rectify(luma: plane, intrinsics: intr, cameraTransform: cam, planeY: bp.center.y,
                                         center: SIMD2(bp.center.x, bp.center.z), size: 500, metersPerPixel: 0.001) else { continue }
    let predicted = corners.map(img.pixel)
    guard let snapped = finder.track(in: img, predicted: predicted) else { print(String(format: "%5.1f lost", wall - start!)); continue }
    let errors = zip(snapped.corners, predicted).map { simd_distance($0, $1) }
    let shift = zip(snapped.corners, predicted).map { $0 - $1 }.reduce(.zero, +) / 4
    rawErrors.append(simd_length(shift))
    if let lastOffset { staleErrors.append(simd_length(shift - lastOffset)) }
    lastOffset = shift
    let eye = SIMD3(cam.columns.3.x, cam.columns.3.y, cam.columns.3.z)
    let dir = simd_normalize(SIMD2(bp.center.x - eye.x, bp.center.z - eye.z))
    let along = simd_dot(shift, dir)  // + means grid is really farther from the camera than drawn
    print(String(format: "%5.1f max %4.1fmm  mean shift %4.1fmm (%+5.1f away from camera)  cam dist %.2fm",
                 wall - start!, errors.max()!, simd_length(shift), along, simd_distance(eye, bp.center)))
}

func mean(_ v: [Float]) -> Float { v.reduce(0, +) / Float(max(v.count, 1)) }
print(String(format: "uncorrected mean %.1fmm max %.1fmm; with the correction from the previous frame (0.5s old) mean %.1fmm max %.1fmm",
             mean(rawErrors), rawErrors.max() ?? 0, mean(staleErrors), staleErrors.max() ?? 0))
