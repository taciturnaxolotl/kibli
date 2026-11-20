import Foundation

/// A square on the board. `file` 0...7 is a...h, `rank` 0...7 is 1...8.
struct Square: Hashable, Sendable, CustomStringConvertible {
    let file: Int
    let rank: Int

    init?(file: Int, rank: Int) {
        guard (0..<8).contains(file), (0..<8).contains(rank) else { return nil }
        self.file = file
        self.rank = rank
    }

    var isLight: Bool { (file + rank) % 2 == 1 }

    var description: String {
        let letter = Character(UnicodeScalar(UInt8(ascii: "a") + UInt8(file)))
        return "\(letter)\(rank + 1)"
    }

    static let all: [Square] = (0..<8).flatMap { rank in
        (0..<8).compactMap { file in Square(file: file, rank: rank) }
    }
}
