// Replays a blackbox recording through the occupancy scoring: for every saved
// frame, scores the empty board, the starting position and any FENs given on
// the command line, using the board pose the app believed at that moment.
// usage: movereplay <recording dir> [fen ...]
import CoreGraphics
import Foundation
import ImageIO
import simd

let args = CommandLine.arguments
let root = URL(fileURLWithPath: args[1])
var candidates: [(String, Position)] = [("empty", Position(fen: "8/8/8/8/8/8/8/8 w - - 0 1")!), ("start", .start)]
for (i, fen) in args.dropFirst(2).enumerated() { if let p = Position(fen: fen) { candidates.append(("fen\(i)", p)) } }

func luma(_ url: URL) -> LumaPlane? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
    var bytes = [UInt8](repeating: 0, count: img.width * img.height)
    let ctx = CGContext(data: &bytes, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width,
                        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0)!
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
    return LumaPlane(width: img.width, height: img.height, bytes: bytes)
}

func depth(_ url: URL) -> DepthPlane? {
    guard let d = try? Data(contentsOf: url), d.count > 4 else { return nil }
    let b = [UInt8](d)
    let w = Int(b[0]) | Int(b[1]) << 8, h = Int(b[2]) | Int(b[3]) << 8
    var dep = [Float](repeating: 0, count: w * h)
    for i in 0..<(w * h) { dep[i] = Float(Int(b[4 + 2 * i]) | Int(b[5 + 2 * i]) << 8) / 1000 }
    return DepthPlane(width: w, height: h, depth: dep, confidence: Array(b[(4 + 2 * w * h)...]))
}

// SIM=1 runs the real MoveDetector over the frames, starting from the game
// the app had when recording began, and prints every decision.
if let v = ProcessInfo.processInfo.environment["SHADOW"].flatMap(Float.init) { Occupancy.shadowScale = v }
if let v = ProcessInfo.processInfo.environment["WIDTH"].flatMap(Float.init) { Occupancy.shadowWidth = v }
if let v = ProcessInfo.processInfo.environment["COLOR"].flatMap(Float.init) { Occupancy.colorWeight = v }
Occupancy.useDepth = ProcessInfo.processInfo.environment["DEPTH"] != nil
let simulate = ProcessInfo.processInfo.environment["SIM"] != nil
let detector = MoveDetector()
var game = Game()
var startConfirmed = false

var pose: [String: Any]?
var start: Double?
print("   t   " + candidates.map { $0.0.padding(toLength: 8, withPad: " ", startingAt: 0) }.joined() + " lidar(empty)")
for line in try String(contentsOf: root.appendingPathComponent("log.jsonl"), encoding: .utf8).split(separator: "\n") {
    guard let r = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], let kind = r["kind"] as? String else { continue }
    let wall = r["wall"] as! Double
    if start == nil { start = wall }
    if kind == "pose" { pose = r }
    if kind == "state", simulate, let moves = r["moves"] as? [String] {
        for san in moves {
            guard let m = game.position.legalMoves().first(where: { game.position.san($0).trimmingCharacters(in: CharacterSet(charactersIn: "+#")) == san.trimmingCharacters(in: CharacterSet(charactersIn: "+#")) }) else { break }
            game.play(m)
        }
        print("starting from \(game.records.count) moves")
    }
    guard kind == "frame", let image = r["image"] as? String, let pose,
          let plane = luma(root.appendingPathComponent(image)) else { continue }
    let scale = Float(r["imageScale"] as? Double ?? 1)
    let k = (r["intrinsics"] as! [Double]).map(Float.init)
    let intr = simd_float3x3(columns: (SIMD3(k[0] * scale, k[3], k[6]), SIMD3(k[1], k[4] * scale, k[7]), SIMD3(k[2] * scale, k[5] * scale, k[8])))
    let t = (r["camera"] as! [Double]).map(Float.init)
    let cam = simd_float4x4(columns: (SIMD4(t[0], t[1], t[2], t[3]), SIMD4(t[4], t[5], t[6], t[7]), SIMD4(t[8], t[9], t[10], t[11]), SIMD4(t[12], t[13], t[14], t[15])))
    let c = (pose["center"] as! [Double]).map(Float.init)
    let bp = BoardPose(center: SIMD3(c[0], c[1], c[2]),
                       yaw: Float(pose["yaw"] as! Double) + Float(pose["quarterTurns"] as? Int ?? 0) * .pi / 2,
                       side: Float(pose["side"] as! Double))
    guard var snap = BoardSnapshot(luma: plane, intrinsics: intr, cameraTransform: cam, board: bp.transform, side: bp.side) else { continue }
    var lidar = "-"
    if let dn = r["depth"] as? String, let dp = depth(root.appendingPathComponent(dn)) {
        snap.heights = dp.squareHeights(imageIntrinsics: intr, imageWidth: plane.width, cameraTransform: cam, board: bp.transform, side: bp.side)
        let seen = snap.heights!.compactMap { $0 }
        lidar = "\(seen.count) sq, max \(String(format: "%.2f", seen.max() ?? 0))"
    }
    if simulate {
        let done = DispatchSemaphore(value: 0)
        var result: MoveDetector.Event = .busy
        let frame = MoveDetector.Frame(luma: plane, intrinsics: intr, camera: cam, board: bp.transform, side: bp.side)
        var seen = MoveDetector.Insight()
        _ = detector.process(frame, position: game.position, awaitingStart: game.records.isEmpty && !startConfirmed, findOrientation: false) { event, ins in
            result = event; seen = ins; done.signal()
        }
        done.wait()
        let t = String(format: "%5.1f", wall - start!)
        switch result {
        case .busy: break
        case .obstructed: print(t, "obstructed")
        case .settled(let fit):
            if game.records.isEmpty { startConfirmed = true }
            var line = t + " settled " + String(format: "%.2f", fit)
            if ProcessInfo.processInfo.environment["TOP"] != nil, let sn = BoardSnapshot(luma: plane, intrinsics: intr, cameraTransform: cam, board: bp.transform, side: bp.side) {
                let ranked = game.position.legalMoves().compactMap { m -> (String, Float)? in
                    Occupancy.fit(game.position.playing(m), sn).map { (game.position.san(m), $0) }
                }.sorted { $0.1 > $1.1 }
                line += "  top: " + ranked.prefix(4).map { String(format: "%@ %.3f", $0.0, $0.1) }.joined(separator: ", ")
                line += String(format: "  now %.3f", Occupancy.fit(game.position, sn) ?? -9)
            }
            print(line)
        case .awaitingStart(let fit): print(t, "awaiting start", String(format: "%.2f", fit))
        case .moved(let moves, _):
            var p = game.position
            print(t, "leftover", seen.leftover ?? -1, "MOVED", moves.map { m -> String in defer { p = p.playing(m) }; return p.san(m) })
            for m in moves { game.play(m) }
        case .unclear: print(t, "unclear")
        case .ambiguous(let moves):
            // PICK=Nf6,e6 picks those when offered, like a user tapping.
            let picks = (ProcessInfo.processInfo.environment["PICK"] ?? "").split(separator: ",").map(String.init)
            let names = moves.map { game.position.san($0) }
            let i = names.firstIndex { picks.contains($0) } ?? 0
            print(t, "AMBIGUOUS", names, "-> picked", names[i])
            game.play(moves[i])
        case .cleared: print(t, "CLEARED"); game = Game(); startConfirmed = false
        case .newGame: print(t, "NEW GAME"); game = Game(); startConfirmed = true
        case .oriented(let q): print(t, "oriented", q)
        }
        continue
    }
    if ProcessInfo.processInfo.environment["UNEXPLAINED"] != nil {
        // Squares the start position (plus the game so far, when simulating)
        // expects bare that look covered: a resting hand shows up as many.
        let p = game.position
        let bare = Occupancy.expectedBare(p, camera: snap.camera)
        if let looks = Occupancy.bareness(snap, reference: bare) {
            let n = (0..<64).filter { bare[$0] && snap.visible[$0] > 0.95 && looks[$0] < 0.3 }.count
            print(String(format: "%6.1f unexplained %d", wall - start!, n))
        }
    }
    if let at = ProcessInfo.processInfo.environment["SEARCHAT"].flatMap(Double.init), abs(wall - start! - at) < 0.26 {
        let plies = Int(ProcessInfo.processInfo.environment["PLIES"] ?? "6")!
        let found = Occupancy.search(from: .start, plies: plies, beam: 80, snapshot: snap)
        for line in found.prefix(8) {
            var p = Position.start
            let san = line.moves.map { m -> String in defer { p = p.playing(m) }; return p.san(m) }
            print(String(format: "%6.3f ", Occupancy.fit(p, snap) ?? -9) + san.joined(separator: " "))
        }
    }
    if let dir = ProcessInfo.processInfo.environment["SNAPS"] {
        var pgm = Data("P5\n\(BoardSnapshot.size) \(BoardSnapshot.size)\n255\n".utf8)
        pgm.append(contentsOf: snap.pixels.map { UInt8(min(max($0, 0), 255)) })
        try pgm.write(to: URL(fileURLWithPath: dir + String(format: "/%06.1f.pgm", wall - start!)))
    }
    if let dumpAt = ProcessInfo.processInfo.environment["DUMP"].flatMap(Double.init), abs(wall - start! - dumpAt) < 0.26 {
        let bare = Occupancy.expectedBare(.start, camera: snap.camera)
        let looks = Occupancy.bareness(snap, reference: bare) ?? []
        print("camera (board units)", snap.camera, "pose turns", pose["quarterTurns"] ?? 0)
        if let pc = Occupancy.pieceColor(snap, reference: bare) {
            if let (l, d) = Occupancy.tones(snap, reference: bare) {
                print(String(format: "tones light %.0f dark %.0f; medians (low/mid/high):", l, d))
                for rank in (0..<8).reversed() { print("\(rank + 1) " + (0..<8).map { let e = snap.extremes[rank * 8 + $0]; return String(format: "%3.0f/%3.0f/%3.0f", e.low, e.mid, e.high) }.joined(separator: " ")) }
            }
            print("piece colour (+white / -black):")
            for rank in (0..<8).reversed() { print("\(rank + 1) " + (0..<8).map { String(format: "%+5.1f", pc[rank * 8 + $0]) }.joined(separator: " ")) }
        }
        for rank in (0..<8).reversed() {
            var row = "\(rank + 1) "
            for file in 0..<8 {
                let i = rank * 8 + file
                let h = snap.heights?[i].map { String(format: "%5.2f", $0) } ?? "  -  "
                row += (bare[i] ? "." : "#") + String(Int(min((looks.isEmpty ? 0 : looks[i]) * 9.99, 9))) + h + " "
            }
            print(row)
        }
        var pgm = Data("P5\n\(BoardSnapshot.size) \(BoardSnapshot.size)\n255\n".utf8)
        pgm.append(contentsOf: snap.pixels.map { UInt8(min(max($0, 0), 255)) })
        try pgm.write(to: URL(fileURLWithPath: "/tmp/dump_snap.pgm"))
    }
    let scores = candidates.map { Occupancy.fit($0.1, snap).map { String(format: "%7.2f ", $0) } ?? "    -   " }
    print(String(format: "%5.1f ", wall - start!) + scores.joined() + " " + lidar)
}
