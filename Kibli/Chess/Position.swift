import Foundation

enum PieceColor: Sendable, Hashable {
    case white, black
    var opponent: PieceColor { self == .white ? .black : .white }
}

enum PieceKind: Sendable, Hashable, CaseIterable {
    case pawn, knight, bishop, rook, queen, king

    var letter: String {
        switch self {
        case .pawn: ""
        case .knight: "N"
        case .bishop: "B"
        case .rook: "R"
        case .queen: "Q"
        case .king: "K"
        }
    }
}

struct Piece: Sendable, Hashable {
    let color: PieceColor
    let kind: PieceKind

    var symbol: String {
        switch (color, kind) {
        case (.white, .king): "♔"
        case (.white, .queen): "♕"
        case (.white, .rook): "♖"
        case (.white, .bishop): "♗"
        case (.white, .knight): "♘"
        case (.white, .pawn): "♙"
        case (.black, .king): "♚"
        case (.black, .queen): "♛"
        case (.black, .rook): "♜"
        case (.black, .bishop): "♝"
        case (.black, .knight): "♞"
        case (.black, .pawn): "♟"
        }
    }
}

struct Move: Sendable, Hashable {
    let from: Square
    let to: Square
    var promotion: PieceKind?
    var isCastle = false
    var isEnPassant = false

    /// Squares whose contents change when the move is played.
    var touched: [Square] {
        var squares = [from, to]
        if isCastle {
            let kingside = to.file > from.file
            squares.append(Square(file: kingside ? 7 : 0, rank: from.rank)!)
            squares.append(Square(file: kingside ? 5 : 3, rank: from.rank)!)
        }
        if isEnPassant {
            squares.append(Square(file: to.file, rank: from.rank)!)
        }
        return squares
    }
}

/// A chess position with full legal move generation.
struct Position: Sendable, Hashable {
    private(set) var board: [Piece?]
    private(set) var sideToMove: PieceColor = .white
    private(set) var castling: Set<CastleRight> = [.whiteKing, .whiteQueen, .blackKing, .blackQueen]
    private(set) var enPassant: Square?

    enum CastleRight: Sendable, Hashable { case whiteKing, whiteQueen, blackKing, blackQueen }

    static let start: Position = {
        var board = [Piece?](repeating: nil, count: 64)
        let back: [PieceKind] = [.rook, .knight, .bishop, .queen, .king, .bishop, .knight, .rook]
        for file in 0..<8 {
            board[file] = Piece(color: .white, kind: back[file])
            board[8 + file] = Piece(color: .white, kind: .pawn)
            board[48 + file] = Piece(color: .black, kind: .pawn)
            board[56 + file] = Piece(color: .black, kind: back[file])
        }
        return Position(board: board)
    }()

    init(board: [Piece?]) {
        self.board = board
    }

    init?(fen: String) {
        let fields = fen.split(separator: " ")
        guard fields.count >= 4 else { return nil }
        var board = [Piece?](repeating: nil, count: 64)
        let kinds: [Character: PieceKind] = ["p": .pawn, "n": .knight, "b": .bishop, "r": .rook, "q": .queen, "k": .king]
        for (row, text) in fields[0].split(separator: "/").enumerated() {
            var file = 0
            for char in text {
                if let skip = char.wholeNumberValue { file += skip; continue }
                guard let kind = kinds[Character(char.lowercased())], file < 8 else { return nil }
                board[(7 - row) * 8 + file] = Piece(color: char.isUppercase ? .white : .black, kind: kind)
                file += 1
            }
        }
        self.board = board
        sideToMove = fields[1] == "b" ? .black : .white
        castling = []
        for char in fields[2] {
            switch char {
            case "K": castling.insert(.whiteKing)
            case "Q": castling.insert(.whiteQueen)
            case "k": castling.insert(.blackKing)
            case "q": castling.insert(.blackQueen)
            default: break
            }
        }
        if fields[3] != "-", let f = fields[3].first?.asciiValue, let r = fields[3].last?.wholeNumberValue {
            enPassant = Square(file: Int(f) - 97, rank: r - 1)
        }
    }

    subscript(square: Square) -> Piece? { board[square.rank * 8 + square.file] }

    /// Piece placement plus side to move, for spotting repeats in a search.
    var boardKey: [Piece?] { board + [Piece(color: sideToMove, kind: .pawn)] }

    var occupied: Set<Square> { Set(Square.all.filter { self[$0] != nil }) }

    // MARK: Making moves

    func playing(_ moves: [Move]) -> Position {
        moves.reduce(self) { $0.playing($1) }
    }

    func playing(_ move: Move) -> Position {
        var next = self
        let piece = self[move.from]!
        next.set(move.from, nil)
        next.set(move.to, move.promotion.map { Piece(color: piece.color, kind: $0) } ?? piece)
        if move.isEnPassant {
            next.set(Square(file: move.to.file, rank: move.from.rank)!, nil)
        }
        if move.isCastle {
            let kingside = move.to.file > move.from.file
            let rookFrom = Square(file: kingside ? 7 : 0, rank: move.from.rank)!
            let rookTo = Square(file: kingside ? 5 : 3, rank: move.from.rank)!
            next.set(rookTo, next[rookFrom])
            next.set(rookFrom, nil)
        }

        next.enPassant = nil
        if piece.kind == .pawn, abs(move.to.rank - move.from.rank) == 2 {
            next.enPassant = Square(file: move.from.file, rank: (move.from.rank + move.to.rank) / 2)
        }
        for square in [move.from, move.to] {
            switch (square.file, square.rank) {
            case (4, 0): next.castling.subtract([.whiteKing, .whiteQueen])
            case (4, 7): next.castling.subtract([.blackKing, .blackQueen])
            case (0, 0): next.castling.remove(.whiteQueen)
            case (7, 0): next.castling.remove(.whiteKing)
            case (0, 7): next.castling.remove(.blackQueen)
            case (7, 7): next.castling.remove(.blackKing)
            default: break
            }
        }
        next.sideToMove = sideToMove.opponent
        return next
    }

    private mutating func set(_ square: Square, _ piece: Piece?) {
        board[square.rank * 8 + square.file] = piece
    }

    // MARK: Move generation

    func legalMoves() -> [Move] {
        pseudoLegalMoves().filter { !playing($0).isKingAttacked(sideToMove) }
    }

    var isInCheck: Bool { isKingAttacked(sideToMove) }

    private func isKingAttacked(_ color: PieceColor) -> Bool {
        guard let king = Square.all.first(where: { self[$0] == Piece(color: color, kind: .king) }) else { return false }
        return isAttacked(king, by: color.opponent)
    }

    func isAttacked(_ square: Square, by color: PieceColor) -> Bool {
        let pawnRank = color == .white ? -1 : 1
        for df in [-1, 1] {
            if let s = Square(file: square.file + df, rank: square.rank + pawnRank),
               self[s] == Piece(color: color, kind: .pawn) { return true }
        }
        for (df, dr) in Self.knightSteps {
            if let s = Square(file: square.file + df, rank: square.rank + dr),
               self[s] == Piece(color: color, kind: .knight) { return true }
        }
        for (df, dr) in Self.kingSteps {
            if let s = Square(file: square.file + df, rank: square.rank + dr),
               self[s] == Piece(color: color, kind: .king) { return true }
        }
        for (directions, kinds) in [(Self.rookDirections, [PieceKind.rook, .queen]), (Self.bishopDirections, [.bishop, .queen])] {
            for (df, dr) in directions {
                var s = Square(file: square.file + df, rank: square.rank + dr)
                while let current = s {
                    if let piece = self[current] {
                        if piece.color == color, kinds.contains(piece.kind) { return true }
                        break
                    }
                    s = Square(file: current.file + df, rank: current.rank + dr)
                }
            }
        }
        return false
    }

    private func pseudoLegalMoves() -> [Move] {
        var moves: [Move] = []
        let us = sideToMove
        for from in Square.all {
            guard let piece = self[from], piece.color == us else { continue }
            switch piece.kind {
            case .pawn:
                let forward = us == .white ? 1 : -1
                let startRank = us == .white ? 1 : 6
                let lastRank = us == .white ? 7 : 0
                func add(_ to: Square, enPassant: Bool = false) {
                    if to.rank == lastRank {
                        for kind in [PieceKind.queen, .rook, .bishop, .knight] {
                            moves.append(Move(from: from, to: to, promotion: kind))
                        }
                    } else {
                        moves.append(Move(from: from, to: to, isEnPassant: enPassant))
                    }
                }
                if let one = Square(file: from.file, rank: from.rank + forward), self[one] == nil {
                    add(one)
                    if from.rank == startRank, let two = Square(file: from.file, rank: from.rank + 2 * forward), self[two] == nil {
                        add(two)
                    }
                }
                for df in [-1, 1] {
                    guard let to = Square(file: from.file + df, rank: from.rank + forward) else { continue }
                    if let target = self[to], target.color != us { add(to) }
                    if to == enPassant { add(to, enPassant: true) }
                }
            case .knight:
                for (df, dr) in Self.knightSteps { step(from, df, dr, into: &moves) }
            case .king:
                for (df, dr) in Self.kingSteps { step(from, df, dr, into: &moves) }
                addCastling(from, into: &moves)
            case .bishop:
                for (df, dr) in Self.bishopDirections { slide(from, df, dr, into: &moves) }
            case .rook:
                for (df, dr) in Self.rookDirections { slide(from, df, dr, into: &moves) }
            case .queen:
                for (df, dr) in Self.rookDirections + Self.bishopDirections { slide(from, df, dr, into: &moves) }
            }
        }
        return moves
    }

    private func step(_ from: Square, _ df: Int, _ dr: Int, into moves: inout [Move]) {
        guard let to = Square(file: from.file + df, rank: from.rank + dr) else { return }
        if let target = self[to], target.color == sideToMove { return }
        moves.append(Move(from: from, to: to))
    }

    private func slide(_ from: Square, _ df: Int, _ dr: Int, into moves: inout [Move]) {
        var s = Square(file: from.file + df, rank: from.rank + dr)
        while let to = s {
            if let target = self[to] {
                if target.color != sideToMove { moves.append(Move(from: from, to: to)) }
                return
            }
            moves.append(Move(from: from, to: to))
            s = Square(file: to.file + df, rank: to.rank + dr)
        }
    }

    private func addCastling(_ from: Square, into moves: inout [Move]) {
        let rank = sideToMove == .white ? 0 : 7
        guard from == Square(file: 4, rank: rank), !isInCheck else { return }
        let them = sideToMove.opponent
        let (kingRight, queenRight): (CastleRight, CastleRight) = sideToMove == .white
            ? (.whiteKing, .whiteQueen) : (.blackKing, .blackQueen)
        func empty(_ files: [Int]) -> Bool { files.allSatisfy { self[Square(file: $0, rank: rank)!] == nil } }
        func safe(_ files: [Int]) -> Bool { files.allSatisfy { !isAttacked(Square(file: $0, rank: rank)!, by: them) } }
        if castling.contains(kingRight), empty([5, 6]), safe([5, 6]) {
            moves.append(Move(from: from, to: Square(file: 6, rank: rank)!, isCastle: true))
        }
        if castling.contains(queenRight), empty([1, 2, 3]), safe([2, 3]) {
            moves.append(Move(from: from, to: Square(file: 2, rank: rank)!, isCastle: true))
        }
    }

    private static let knightSteps = [(1, 2), (2, 1), (2, -1), (1, -2), (-1, -2), (-2, -1), (-2, 1), (-1, 2)]
    private static let kingSteps = [(1, 0), (1, 1), (0, 1), (-1, 1), (-1, 0), (-1, -1), (0, -1), (1, -1)]
    private static let rookDirections = [(1, 0), (-1, 0), (0, 1), (0, -1)]
    private static let bishopDirections = [(1, 1), (1, -1), (-1, 1), (-1, -1)]

    // MARK: Notation

    func san(_ move: Move) -> String {
        guard let piece = self[move.from] else { return "?" }
        var text: String
        if move.isCastle {
            text = move.to.file > move.from.file ? "O-O" : "O-O-O"
        } else {
            let capture = self[move.to] != nil || move.isEnPassant
            if piece.kind == .pawn {
                text = capture ? "\(move.from.description.prefix(1))x\(move.to)" : move.to.description
                if let promotion = move.promotion { text += "=\(promotion.letter)" }
            } else {
                text = piece.kind.letter
                let rivals = legalMoves().filter {
                    $0.to == move.to && $0.from != move.from && self[$0.from]?.kind == piece.kind
                }
                if !rivals.isEmpty {
                    if !rivals.contains(where: { $0.from.file == move.from.file }) {
                        text += move.from.description.prefix(1)
                    } else if !rivals.contains(where: { $0.from.rank == move.from.rank }) {
                        text += "\(move.from.rank + 1)"
                    } else {
                        text += move.from.description
                    }
                }
                if capture { text += "x" }
                text += move.to.description
            }
        }
        let next = playing(move)
        if next.isInCheck { text += next.legalMoves().isEmpty ? "#" : "+" }
        return text
    }
}
