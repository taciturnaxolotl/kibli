// Scores two board positions against recorded frames with the finder's full
// board score, to see which one each viewpoint prefers.
// usage: spotscore <recording> x,y,z,yaw,side x,y,z,yaw,side [planeY]
import CoreGraphics
import Foundation
import ImageIO
import simd

let args = CommandLine.arguments
let root = URL(fileURLWithPath: args[1])
func parse(_ s: String) -> BoardPose { let v = s.split(separator: ",").map { Float($0)! }; return BoardPose(center: SIMD3(v[0], v[1], v[2]), yaw: v[3], side: v[4]) }
let spots = [parse(args[2]), parse(args[3])]
let planeY = Float(args.count > 4 ? args[4] : "-0.148")!
func luma(_ url: URL) -> LumaPlane? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
    var bytes = [UInt8](repeating: 0, count: img.width * img.height)
    CGContext(data: &bytes, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0)!.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
    return LumaPlane(width: img.width, height: img.height, bytes: bytes)
}
var start: Double?
var totals = [Float](repeating: 0, count: 5)
let finder = GridFinder()
for line in try String(contentsOf: root.appendingPathComponent("log.jsonl"), encoding: .utf8).split(separator: "\n") {
    guard let r = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], r["kind"] as? String == "frame", let image = r["image"] as? String,
          let plane = luma(root.appendingPathComponent(image)) else {
        if start == nil, let r = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] { start = r["wall"] as? Double }
        continue
    }
    let scale = Float(r["imageScale"] as? Double ?? 1)
    let k = (r["intrinsics"] as! [Double]).map(Float.init)
    let K = simd_float3x3(columns: (SIMD3(k[0] * scale, k[3], k[6]), SIMD3(k[1], k[4] * scale, k[7]), SIMD3(k[2] * scale, k[5] * scale, k[8])))
    let t = (r["camera"] as! [Double]).map(Float.init)
    let C = simd_float4x4(columns: (SIMD4(t[0], t[1], t[2], t[3]), SIMD4(t[4], t[5], t[6], t[7]), SIMD4(t[8], t[9], t[10], t[11]), SIMD4(t[12], t[13], t[14], t[15])))
    let eye = SIMD3(t[12], t[13], t[14])
    let mid = (spots[0].center + spots[1].center) / 2
    guard let img = TopDownImage.rectify(luma: plane, intrinsics: K, cameraTransform: C, planeY: planeY, center: SIMD2(mid.x, mid.z), size: 500, metersPerPixel: 0.002) else { continue }
    let fine = img.pixels
    var out = String(format: "%5.1f", (r["wall"] as! Double) - start!)
    for spot in spots {
        let h = spot.side / 2
        let corners = [SIMD4<Float>(-h, 0, -h, 1), SIMD4(h, 0, -h, 1), SIMD4(h, 0, h, 1), SIMD4(-h, 0, h, 1)].map { v -> SIMD2<Float> in
            let w = spot.transform * v; let p = SIMD3(w.x, w.y, w.z)
            return img.pixel(eye + (p - eye) * ((planeY - eye.y) / (p.y - eye.y)))
        }
        let refined = GridFinder.refine(fine, size: img.size, corners: corners)
        let s = GridFinder.boardScore(fine, valid: img.valid, size: img.size, corners: refined.corners, threshold: 12, flatVariance: 30)
        out += String(format: "  checker %3d score %6.1f", s.checker, s.score)
    }
    // Accumulated one-square-shift test, starting from the first spot.
    do {
        let spot = spots[0]
        let h = spot.side / 2
        let corners = [SIMD4<Float>(-h, 0, -h, 1), SIMD4(h, 0, -h, 1), SIMD4(h, 0, h, 1), SIMD4(-h, 0, h, 1)].map { v -> SIMD2<Float> in
            let w = spot.transform * v; let p = SIMD3(w.x, w.y, w.z)
            return img.pixel(eye + (p - eye) * ((planeY - eye.y) / (p.y - eye.y)))
        }
        let refined = GridFinder.refine(fine, size: img.size, corners: corners).corners
        let sc = GridFinder.shiftScores(img, corners: refined)
        for i in 1..<5 { totals[i] = sc[i] - sc[0] }
        out += "  shift lead " + (1..<5).map { String(format: "%6.0f", totals[$0]) }.joined()
    }
    if let found = finder.find(in: img) {
        let w = found.corners.map(img.world).reduce(.zero, +) / 4
        let toward = spots.map { s -> Float in
            var d = w - s.center; d.y = 0; return simd_length(d) - simd_length(SIMD2(s.center.x - eye.x, s.center.z - eye.z)) * 0 }
        out += String(format: "  | find picks %@", toward[0] < toward[1] ? "A" : "B")
    }
    print(out)
}
