// Feeds a recording's sightings, four a second, through BoardEstimator and
// prints the fitted surface height over time.
// usage: heightreplay <recording dir>
import Foundation
import simd
let root = URL(fileURLWithPath: CommandLine.arguments[1])
var est = BoardEstimator()
var cam: SIMD3<Float>?
var start: Double?, lastAdd = -1.0, lastPrint = -10.0
for line in try String(contentsOf: root.appendingPathComponent("log.jsonl"), encoding: .utf8).split(separator: "\n") {
    guard let r = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], let kind = r["kind"] as? String else { continue }
    let wall = r["wall"] as! Double
    if start == nil { start = wall }
    let t = wall - start!
    if kind == "frame" { let c = (r["camera"] as! [Double]).map(Float.init); cam = SIMD3(c[12], c[13], c[14]) }
    guard kind == "detection", let corners = r["corners"] as? [[Double]], let cam, t - lastAdd >= 0.25 else { continue }
    lastAdd = t
    let planeY = Float(r["planeY"] as! Double)
    var o = BoardObservation(corners: corners.map { SIMD3(Float($0[0]), Float($0[1]), Float($0[2])) }, planeY: planeY, camera: cam)
    o.time = t
    est.add(o)
    if t - lastPrint >= (ProcessInfo.processInfo.environment["EVERY"].flatMap(Double.init) ?? 2), let h = est.height() {
        lastPrint = t
        print(String(format: "%5.1fs  height %4.1f cm  (%d sightings, parallax %.2f)", t, (h - planeY) * 100, est.observations.count, est.parallax))
    }
}
