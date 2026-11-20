import CoreGraphics
import Foundation
import ImageIO
import simd
struct Meta: Decodable { struct B: Decodable { let center: [Float]; let yaw: Float; let side: Float; let quarterTurns: Int }; let intrinsics: [Float]; let cameraTransform: [Float]; let board: B }
for dir in CommandLine.arguments.dropFirst() {
    let m = try JSONDecoder().decode(Meta.self, from: Data(contentsOf: URL(fileURLWithPath: dir + "/meta.json")))
    let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: dir + "/frame.jpg") as CFURL, nil)!
    let img = CGImageSourceCreateImageAtIndex(src, 0, nil)!
    var bytes = [UInt8](repeating: 0, count: img.width * img.height)
    CGContext(data: &bytes, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0)!.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
    let k = m.intrinsics, t = m.cameraTransform
    let K = simd_float3x3(columns: (SIMD3(k[0], k[3], k[6]), SIMD3(k[1], k[4], k[7]), SIMD3(k[2], k[5], k[8])))
    let C = simd_float4x4(columns: (SIMD4(t[0], t[1], t[2], t[3]), SIMD4(t[4], t[5], t[6], t[7]), SIMD4(t[8], t[9], t[10], t[11]), SIMD4(t[12], t[13], t[14], t[15])))
    var turns = m.board.quarterTurns
    for step in 0..<3 {
        let pose = BoardPose(center: SIMD3(m.board.center[0], m.board.center[1], m.board.center[2]), yaw: m.board.yaw + Float(turns) * .pi / 2, side: m.board.side)
        let d = MoveDetector()
        var last: MoveDetector.Event = .busy
        for _ in 0..<4 {
            let sem = DispatchSemaphore(value: 0)
            _ = d.process(.init(luma: LumaPlane(width: img.width, height: img.height, bytes: bytes), intrinsics: K, camera: C, board: pose.transform, side: pose.side),
                          position: .start, awaitingStart: true, findOrientation: true) { e, _ in last = e; sem.signal() }
            sem.wait()
        }
        print(dir.suffix(19), "turns", turns, "->", last)
        if case .oriented(let q) = last { turns = (turns + q) % 4 } else { break }
        _ = step
    }
}
