// Runs GridFinder on fake top-down views dumped by tools/grid_proto.py and
// writes PGM overlays so the Swift port can be checked against the prototype.
import Foundation
import simd

let dir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/kibli_td"
let n = 500
let files = try FileManager.default.contentsOfDirectory(atPath: dir).filter { $0.hasSuffix(".f32") }.sorted()
for file in files {
    let data = try Data(contentsOf: URL(fileURLWithPath: "\(dir)/\(file)"))
    let raw = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    let image = TopDownImage(
        size: n, metersPerPixel: 0.002, origin: .zero, planeY: 0,
        pixels: raw.map { max($0, 0) }, valid: raw.map { $0 >= 0 }
    )
    let start = Date()
    guard let result = GridFinder().find(in: image) else {
        print("\(file): nothing")
        continue
    }
    let ms = Date().timeIntervalSince(start) * 1000
    let sides = (0..<4).map { simd_distance(result.corners[$0], result.corners[($0 + 1) % 4]) * 2 }
    let centre = result.corners.reduce(.zero, +) / 4
    print(String(format: "%@ checker=%3d/112 edge=%5.1f side=%5.1fmm centre=(%5.1f,%5.1f) %.0fms",
                 file, result.checker, result.edge, sides.reduce(0, +) / 4, centre.x, centre.y, ms))

    var pixels = image.pixels.map { UInt8(min(max($0, 0), 255)) }
    let h = Homography(unitSquareTo: result.corners, scale: 8)
    for i in 0...8 {
        for t in stride(from: Float(0), through: 8, by: 0.01) {
            for p in [h.apply(SIMD2(Float(i), t)), h.apply(SIMD2(t, Float(i)))] {
                let x = Int(p.x), y = Int(p.y)
                if x >= 0, y >= 0, x < n, y < n { pixels[y * n + x] = 255 }
            }
        }
    }
    var pgm = Data("P5\n\(n) \(n)\n255\n".utf8)
    pgm.append(contentsOf: pixels)
    try pgm.write(to: URL(fileURLWithPath: "\(dir)/\(file).pgm"))
}
