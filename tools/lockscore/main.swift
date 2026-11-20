import CoreGraphics
import Foundation
import ImageIO
import simd
struct Meta: Decodable { struct B: Decodable { let center: [Float]; let yaw: Float; let side: Float }; let intrinsics: [Float]; let cameraTransform: [Float]; let board: B; let tablePlaneY: Float }
for dir in CommandLine.arguments.dropFirst() {
    let m = try JSONDecoder().decode(Meta.self, from: Data(contentsOf: URL(fileURLWithPath: dir + "/meta.json")))
    let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: dir + "/frame.jpg") as CFURL, nil)!
    let img = CGImageSourceCreateImageAtIndex(src, 0, nil)!
    var bytes = [UInt8](repeating: 0, count: img.width * img.height)
    CGContext(data: &bytes, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0)!.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
    let luma = LumaPlane(width: img.width, height: img.height, bytes: bytes)
    let k = m.intrinsics, t = m.cameraTransform
    let K = simd_float3x3(columns: (SIMD3(k[0], k[3], k[6]), SIMD3(k[1], k[4], k[7]), SIMD3(k[2], k[5], k[8])))
    let C = simd_float4x4(columns: (SIMD4(t[0], t[1], t[2], t[3]), SIMD4(t[4], t[5], t[6], t[7]), SIMD4(t[8], t[9], t[10], t[11]), SIMD4(t[12], t[13], t[14], t[15])))
    let eye = SIMD3(t[12], t[13], t[14])
    let pose = BoardPose(center: SIMD3(m.board.center[0], m.board.center[1], m.board.center[2]), yaw: m.board.yaw, side: m.board.side)
    let h = pose.side / 2
    let predicted = [SIMD4<Float>(-h, 0, -h, 1), SIMD4(h, 0, -h, 1), SIMD4(h, 0, h, 1), SIMD4(-h, 0, h, 1)].map { v -> SIMD3<Float> in
        let w = pose.transform * v; let p = SIMD3(w.x, w.y, w.z)
        return eye + (p - eye) * ((m.tablePlaneY - eye.y) / (p.y - eye.y))
    }
    let tracked = BoardSearch.track(luma: luma, intrinsics: K, camera: C, planeY: m.tablePlaneY, predicted: predicted, finder: GridFinder())
    let fresh = BoardSearch.locate(luma: luma, intrinsics: K, camera: C, planeY: m.tablePlaneY, center: SIMD2(pose.center.x, pose.center.z), finder: GridFinder())
    let fwd = SIMD3(-t[8], -t[9], -t[10]); let hit = eye + fwd * ((m.tablePlaneY - eye.y) / fwd.y)
    let aimed = BoardSearch.locate(luma: luma, intrinsics: K, camera: C, planeY: m.tablePlaneY, center: SIMD2(hit.x, hit.z), finder: GridFinder())
    func f(_ r: GridFinder.Result?) -> String { r.map { String(format: "checker %3d score %6.1f", $0.checker, $0.score) } ?? "none" }
    if let a = tracked, let ag = a.grid, let b = aimed, let bg = b.grid {
        let wa = ag.corners.map(a.image.world), wb = bg.corners.map(b.image.world)
        let ca = wa.reduce(.zero, +) / 4, cb = wb.reduce(.zero, +) / 4
        let cs = predicted.reduce(.zero, +) / 4
        print(String(format: "   saved lock vs refined: %.1fmm, refined vs fresh: %.1fmm", simd_distance(cs, ca) * 1000, simd_distance(ca, cb) * 1000))
    }
    print(dir.suffix(19), "| wrong lock:", f(tracked?.grid), "| fresh at lock:", f(fresh?.grid), "| fresh where aimed:", f(aimed?.grid))
}
