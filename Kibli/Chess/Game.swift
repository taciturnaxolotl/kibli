import Foundation

/// The game as the app has followed it so far.
struct Game: Sendable {
    struct Record: Sendable, Identifiable {
        let id = UUID()
        let move: Move
        let san: String
        let before: Position
    }

    private(set) var position = Position.start
    private(set) var records: [Record] = []

    var lastMove: Move? { records.last?.move }

    mutating func play(_ move: Move) {
        records.append(Record(move: move, san: position.san(move), before: position))
        position = position.playing(move)
    }

    mutating func undo() {
        guard let last = records.popLast() else { return }
        position = last.before
    }

    /// Moves grouped into numbered pairs, for a move list.
    var numbered: [(number: Int, white: String, black: String?)] {
        stride(from: 0, to: records.count, by: 2).map { i in
            (i / 2 + 1, records[i].san, i + 1 < records.count ? records[i + 1].san : nil)
        }
    }

    var status: String? {
        let moves = position.legalMoves()
        if moves.isEmpty { return position.isInCheck ? "Checkmate" : "Stalemate" }
        return position.isInCheck ? "Check" : nil
    }
}
