import Foundation
var p = Position.start
func fen(_ p: Position) -> String {
    var rows: [String] = []
    for rank in (0..<8).reversed() {
        var row = "", gap = 0
        for file in 0..<8 {
            if let pc = p[Square(file: file, rank: rank)!] {
                if gap > 0 { row += "\(gap)"; gap = 0 }
                let l = pc.kind == .pawn ? "P" : pc.kind.letter
                row += pc.color == .white ? l : l.lowercased()
            } else { gap += 1 }
        }
        if gap > 0 { row += "\(gap)" }
        rows.append(row)
    }
    return rows.joined(separator: "/") + (p.sideToMove == .white ? " w" : " b") + " - - 0 1"
}
for san in CommandLine.arguments.dropFirst() {
    let clean = { (s: String) in s.trimmingCharacters(in: CharacterSet(charactersIn: "+#")) }
    guard let m = p.legalMoves().first(where: { clean(p.san($0)) == clean(san) }) else { print("illegal \(san)"); exit(1) }
    p = p.playing(m)
}
print(fen(p))
