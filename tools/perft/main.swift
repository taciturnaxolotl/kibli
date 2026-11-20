// Counts leaf nodes from the start position; known values are
// 20, 400, 8902, 197281.
func perft(_ position: Position, _ depth: Int) -> Int {
    if depth == 0 { return 1 }
    return position.legalMoves().reduce(0) { $0 + perft(position.playing($1), depth - 1) }
}
let expected = [20, 400, 8902, 197281]
for depth in 1...4 {
    let n = perft(.start, depth)
    print("depth \(depth): \(n) \(n == expected[depth - 1] ? "ok" : "WRONG")")
}
var p = Position.start
var line: [String] = []
for uci in [("e2","e4"),("e7","e5"),("g1","f3"),("b8","c6"),("f1","b5"),("a7","a6"),("e1","g1")] {
    let move = p.legalMoves().first { $0.from.description == uci.0 && $0.to.description == uci.1 }!
    line.append(p.san(move)); p = p.playing(move)
}
print(line.joined(separator: " "))
let kiwipete = Position(fen: "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1")!
for (depth, want) in [(1, 48), (2, 2039), (3, 97862)] {
    let n = perft(kiwipete, depth)
    print("kiwipete \(depth): \(n) \(n == want ? "ok" : "WRONG")")
}
let pos3 = Position(fen: "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1")!
for (depth, want) in [(1, 14), (2, 191), (3, 2812), (4, 43238)] {
    let n = perft(pos3, depth)
    print("pos3 \(depth): \(n) \(n == want ? "ok" : "WRONG")")
}
