import simd

/// Reads the board without needing a reference view: for a guessed position
/// and the current camera, predict which squares should show bare wood, then
/// check how bare each one actually looks.
///
/// Pieces stand up off the board, so from an angle each one also hides the
/// squares behind it. Modelling that is what makes this work from wherever
/// the phone happens to be, instead of only from the exact spot where an
/// earlier frame was taken.
enum Occupancy {
    /// Rough piece heights in squares, for a standard tournament-ish set.
    static func height(_ kind: PieceKind) -> Float {
        switch kind {
        case .pawn: 1.0
        case .rook: 1.15
        case .knight: 1.3
        case .bishop: 1.5
        case .queen: 1.8
        case .king: 2.0
        }
    }

    /// Per square, whether the middle of it should be visible bare board.
    static func expectedBare(_ position: Position, camera: SIMD3<Float>) -> [Bool] {
        var bare = [Bool](repeating: true, count: 64)
        for square in Square.all {
            guard let piece = position[square] else { continue }
            bare[square.rank * 8 + square.file] = false
            let base = SIMD2(Float(square.file) + 0.5, Float(square.rank) + 0.5)
            // Only the bulk of a piece hides much; the narrow top doesn't.
            let h = 0.85 * height(piece.kind)
            // Where the top of the piece lands on the board, seen from the camera.
            let lift = h / max(camera.z - h, 0.5)
            let top = base + (base - SIMD2(camera.x, camera.y)) * lift
            for other in Square.all where position[other] == nil {
                let center = SIMD2(Float(other.file) + 0.5, Float(other.rank) + 0.5)
                if distance(from: center, toSegment: base, top) < 0.4 {
                    bare[other.rank * 8 + other.file] = false
                }
            }
        }
        return bare
    }

    /// Per square, 0 to 1 for how much its middle looks like bare board of
    /// the right shade. Board shades are learned from the squares `reference`
    /// expects to be bare, so lighting and wood colour don't need tuning.
    static func bareness(_ snapshot: BoardSnapshot, reference: [Bool]) -> [Float]? {
        let stats = snapshot.squareStats()
        var light: [Float] = [], dark: [Float] = [], grain: [Float] = []
        for square in Square.all where reference[square.rank * 8 + square.file] && snapshot.visible[square.rank * 8 + square.file] > 0.95 {
            let s = stats[square.rank * 8 + square.file]
            if square.isLight { light.append(s.mean) } else { dark.append(s.mean) }
            grain.append(s.edges)
        }
        guard light.count >= 4, dark.count >= 4 else { return nil }
        let lightTone = median(light), darkTone = median(dark)
        let contrast = max(abs(lightTone - darkTone), 8)
        let typicalGrain = max(median(grain), 2)

        return Square.all.map { square in
            // Off the edge of the camera image: no evidence either way.
            guard snapshot.visible[square.rank * 8 + square.file] > 0.95 else { return 0.5 }
            let s = stats[square.rank * 8 + square.file]
            let tone = square.isLight ? lightTone : darkTone
            let toneError = abs(s.mean - tone) / contrast
            // Bare wood has soft grain; pieces bring outlines and highlights,
            // which shows up as several times the edge energy even when a
            // light piece sits on a light square.
            let extraTexture = max(s.edges / typicalGrain - 1, 0)
            let score = exp(-pow(toneError / 0.35, 2)) * exp(-pow(extraTexture / 1.1, 2))
            return score
        }
    }

    /// How well a position explains what the camera sees. Higher is better.
    static func agreement(_ bare: [Bool], _ observed: [Float]) -> Float {
        var total: Float = 0
        for i in 0..<64 {
            // A square that looks bare but should be covered is strong
            // evidence against; a covered square that should be bare is
            // weaker, since a hand or a stray shadow can do that too.
            total += bare[i] ? (observed[i] - 0.5) : (0.5 - observed[i]) * 1.4
        }
        return total
    }

    /// Scores a position against a snapshot.
    static func score(_ position: Position, _ snapshot: BoardSnapshot) -> Float? {
        let bare = expectedBare(position, camera: snapshot.camera)
        guard let looks = bareness(snapshot, reference: bare) else { return nil }
        var total = agreement(bare, looks)
        if let heights = snapshot.heights, let occupied = occupancy(fromHeights: heights, position: position) {
            total += depthAgreement(position, occupied)
        }
        return total
    }

    /// 0 to 1 per square for how much something stands on it, from LiDAR, or
    /// nil per square where there's no reading. The board surface level is
    /// taken from squares the position says are empty, which soaks up any
    /// error in the estimated board height.
    static func occupancy(fromHeights heights: [Float?], position: Position) -> [Float?]? {
        let emptyHeights = Square.all.compactMap { square -> Float? in
            position[square] == nil ? heights[square.rank * 8 + square.file] : nil
        }.sorted()
        guard emptyHeights.count >= 6 else { return nil }
        let surface = emptyHeights[emptyHeights.count / 2]
        return heights.map { height in
            height.map { 1 / (1 + exp(-(($0 - surface) - 0.35) / 0.08)) }
        }
    }

    /// Like `agreement`, but only a square's own piece counts, since LiDAR
    /// points sit where they really are instead of hiding squares behind.
    static func depthAgreement(_ position: Position, _ occupied: [Float?]) -> Float {
        var total: Float = 0
        for square in Square.all {
            guard let value = occupied[square.rank * 8 + square.file] else { continue }
            total += (position[square] != nil ? value - 0.5 : 0.5 - value) * 1.5
        }
        return total
    }

    /// Searches move sequences of up to `plies` from `start`, keeping the
    /// best `beam` positions at each depth. Lets the app catch up after
    /// missing a move or two, for example while the phone was moving.
    static func search(from start: Position, plies: Int, beam: Int, snapshot: BoardSnapshot) -> [(moves: [Move], score: Float)] {
        guard let base = score(start, snapshot) else { return [] }
        var frontier: [(position: Position, moves: [Move], score: Float)] = [(start, [], base)]
        var results: [(moves: [Move], score: Float)] = [([], base)]
        var seen: Set<[Piece?]> = [start.boardKey]
        for _ in 0..<plies {
            var next: [(position: Position, moves: [Move], score: Float)] = []
            for node in frontier {
                for move in node.position.legalMoves() where move.promotion == nil || move.promotion == .queen {
                    let position = node.position.playing(move)
                    guard seen.insert(position.boardKey).inserted, let s = score(position, snapshot) else { continue }
                    next.append((position, node.moves + [move], s))
                }
            }
            next.sort { $0.score > $1.score }
            frontier = Array(next.prefix(beam))
            results += frontier.map { ($0.moves, $0.score) }
        }
        return results.sorted { $0.score > $1.score }
    }

    private static func distance(from p: SIMD2<Float>, toSegment a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float {
        let ab = b - a
        let t = simd_clamp(simd_dot(p - a, ab) / max(simd_length_squared(ab), 1e-6), 0, 1)
        return simd_distance(p, a + ab * t)
    }

    private static func median(_ values: [Float]) -> Float {
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
}
