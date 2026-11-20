import Foundation
import simd

/// Watches the board for moves without classifying pieces. For each still
/// moment it asks which position, the current one or one a legal move away,
/// best explains which squares look like bare board from where the camera
/// is right now. Because the comparison is against a prediction rather than
/// an earlier frame, the phone is free to move between moves.
final class MoveDetector: @unchecked Sendable {
    enum Event: Sendable {
        /// Something is moving over the board, probably a hand.
        case busy
        /// Still, and the current position still fits.
        case settled(fit: Float)
        case moved([Move], bareness: [Float])
        /// Still, but neither the current position nor any nearby one fits.
        case unclear(bareness: [Float])
        /// The board looks like a starting position; turning the board view
        /// by this many quarter turns puts white at the bottom.
        case oriented(quarterTurns: Int)
        /// The game the app is following doesn't match the board, and the
        /// board looks empty or set up for a new game instead.
        case cleared
        case newGame
        /// Still, but something resting on the board (a hand or sleeve)
        /// covers squares no move explains. Treated like `busy`.
        case obstructed
        /// Waiting for the starting position to appear.
        case awaitingStart(fit: Float)
        /// Something moved, but from this angle two or more legal moves look
        /// the same (usually because the square the piece left is hidden
        /// behind other pieces). Best first.
        case ambiguous([Move])
    }

    /// Fit (0 to about 1, see `Occupancy.fit`) above which a position counts
    /// as what's on the board.
    var matchFit: Float = 0.55
    /// Below this the tracked position plainly isn't on the board.
    var mismatchFit: Float = 0.35
    /// How clearly the empty board or the start has to fit to reset the game.
    var resetFit: Float = 0.75

    /// What the detector saw at its last check, for the debug view.
    struct Insight: Sendable {
        /// 0 to 1: how far through the "board has been still" wait it is.
        var settle: Double = 0
        /// Typical change on bare squares since the previous frame.
        var motion: Float = 0
        /// Fit of the position being followed, if checked.
        var current: Float?
        /// Best fitting legal moves from that position, best first.
        var ranked: [(san: String, from: Square, to: Square, fit: Float)] = []
        /// Per square, how much it looked like bare board, 0 to 1.
        var bareness: [Float]?
        /// Per square, -1 black piece to +1 white piece.
        var colors: [Float]?
        /// Per square, whether the followed position expects bare board.
        var expectedBare: [Bool]?
        /// Covered squares left unexplained by the best move.
        var leftover: Int?
        /// Per square, how much of it a hand or arm hides.
        var hands: [Float]?
    }

    struct Frame: Sendable {
        let luma: LumaPlane
        let intrinsics: simd_float3x3
        let camera: simd_float4x4
        let board: simd_float4x4
        let side: Float
        var mask: PersonMask?
    }

    /// Change in bare squares between frames, in normalized luma units, that
    /// counts as something moving over the board.
    var motionThreshold: Float = 7
    var framesToSettle = 3
    /// How much better than the current position a move has to fit. A
    /// typical move changes two squares, about 0.03 of a full match.
    var margin: Float = 0.02
    /// Moves within this of the best are treated as indistinguishable. On
    /// real recordings the true move and its look-alike land within 0.005 of
    /// each other, while a genuinely different square costs about 0.03.
    var tieMargin: Float = 0.015

    private let queue = DispatchQueue(label: "sh.dunkirk.kibli.moves", qos: .userInitiated)
    private let lock = NSLock()
    private var busy = false

    private var previous: BoardSnapshot?
    private var still: [BoardSnapshot] = []
    /// A move has to win two still checks in a row before it's accepted.
    private var candidate: [Move]?
    private var mismatches = 0
    private var insight = Insight()

    func reset() {
        queue.async { [self] in
            previous = nil
            still = []
            candidate = nil
            mismatches = 0
        }
    }

    /// Returns false without doing anything if the last frame is still being
    /// processed.
    func process(_ frame: Frame, position: Position, awaitingStart: Bool, findOrientation: Bool, completion: @escaping @Sendable (Event, Insight) -> Void) -> Bool {
        lock.lock()
        if busy {
            lock.unlock()
            return false
        }
        busy = true
        lock.unlock()

        queue.async { [self] in
            var event = Event.busy
            insight = Insight()
            if let snapshot = BoardSnapshot(
                luma: frame.luma, intrinsics: frame.intrinsics, cameraTransform: frame.camera,
                board: frame.board, side: frame.side, mask: frame.mask
            ) {
                event = handle(snapshot, position: position, awaitingStart: awaitingStart)
                insight.settle = min(Double(still.count) / Double(framesToSettle), 1)
                let bare = Occupancy.expectedBare(position, camera: snapshot.camera)
                insight.expectedBare = bare
                insight.bareness = Occupancy.bareness(snapshot, reference: bare)
                insight.colors = Occupancy.pieceColor(snapshot, reference: bare)
                if findOrientation, case .settled = event, let turns = snapshot.startOrientation() {
                    event = .oriented(quarterTurns: turns)
                }
            }
            lock.lock()
            busy = false
            lock.unlock()
            completion(event, insight)
        }
        return true
    }

    private func handle(_ snapshot: BoardSnapshot, position: Position, awaitingStart: Bool) -> Event {
        defer { previous = snapshot }

        // Bare squares look the same from anywhere, so they show motion even
        // while the phone itself is moving.
        if let previous {
            let bare = Occupancy.expectedBare(position, camera: snapshot.camera)
            let now = snapshot.squareStats(), then = previous.squareStats()
            let changes = (0..<64).filter { bare[$0] && snapshot.visible[$0] > 0.95 && previous.visible[$0] > 0.95 }.map { abs(now[$0].mean - then[$0].mean) }.sorted()
            let typical = changes.isEmpty ? 0 : changes[changes.count * 3 / 4]
            insight.motion = typical
            if typical > motionThreshold {
                still = []
                candidate = nil
                return .busy
            }
        }
        insight.hands = snapshot.hands
        // A hand over the board, even holding still, means a move is under
        // way or someone is pointing; don't read anything until it's gone.
        if let hands = snapshot.hands, hands.contains(where: { $0 > handCoverage }) {
            still = []
            candidate = nil
            return .obstructed
        }
        still.append(snapshot)
        if still.count > framesToSettle { still.removeFirst() }
        guard still.count >= framesToSettle else { return .busy }

        let current = averageFit(position)
        insight.current = current
        let observed = averageBareness(position) ?? []

        // First make sure the game being followed is what's on the board.
        if awaitingStart {
            // Occupancy says whether this is a starting position at all (the
            // start looks the same turned half way, so only two layouts need
            // checking). Which end is white comes from piece brightness.
            let upright = current, sideways = averageFit(Self.sidewaysStart)
            guard max(upright, sideways) >= matchFit else { return .awaitingStart(fit: max(upright, sideways)) }
            let turns = still.last!.startOrientation() ?? (upright >= sideways ? 0 : 1)
            // Brightness has to agree with occupancy about the layout.
            let turnsLooksSideways = turns % 2 == 1
            guard turnsLooksSideways == (sideways > upright) else { return .awaitingStart(fit: max(upright, sideways)) }
            return turns == 0 ? .settled(fit: upright) : .oriented(quarterTurns: turns)
        }
        if current < mismatchFit {
            if unexplained(position) > handSquares + 2 {
                mismatches = 0
                return .obstructed
            }
            mismatches += 1
            guard mismatches >= 2 else { return .busy }
            if averageFit(Occupancy.empty) >= resetFit { mismatches = 0; return .cleared }
            if averageFit(.start) >= resetFit { mismatches = 0; return .newGame }
            // Maybe a move or two were missed while the phone was away.
            let found = Occupancy.search(from: position, plies: 2, beam: 12, snapshot: still.last!)
            if let line = found.first, !line.moves.isEmpty,
               let fit = Occupancy.fit(position.playing(line.moves), still.last!), fit >= matchFit {
                mismatches = 0
                still = []
                return .moved(line.moves, bareness: observed)
            }
            return .unclear(bareness: observed)
        }
        mismatches = 0

        // Then ask whether a legal move explains the board better.
        let ranked = position.legalMoves()
            .filter { $0.promotion == nil || $0.promotion == .queen }
            .map { (move: $0, fit: averageFit(position.playing($0))) }
            .sorted { $0.fit > $1.fit }
        insight.ranked = ranked.prefix(5).map { (position.san($0.move), $0.move.from, $0.move.to, $0.fit) }
        guard let best = ranked.first, best.fit >= matchFit, best.fit > current + margin else {
            candidate = nil
            return .settled(fit: current)
        }
        let tied = ranked.prefix { best.fit - $0.fit < tieMargin && $0.fit > current + margin }.map(\.move)
        let leftover = unexplained(position.playing(best.move))
        insight.leftover = leftover
        if leftover > handSquares {
            candidate = nil
            return .obstructed
        }
        // Either way, the same answer has to come up twice in a row.
        guard candidate == tied else {
            candidate = tied
            return .busy
        }
        candidate = nil
        if tied.count == 1 {
            still = []
            return .moved(tied, bareness: observed)
        }
        return .ambiguous(Array(tied.prefix(3)))
    }

    /// The starting position turned a quarter, for noticing a board that
    /// locked sideways. Only occupancy matters, so it needn't be legal.
    private static let sidewaysStart: Position = {
        var board = [Piece?](repeating: nil, count: 64)
        for square in Square.all {
            if let piece = Position.start[square] {
                board[square.file * 8 + (7 - square.rank)] = piece
            }
        }
        return Position(board: board)
    }()

    /// Squares `position` says should be bare that look covered in every
    /// still frame. A real move leaves none once it's played; a hand or
    /// sleeve resting on the board covers several bare squares that no move
    /// explains.
    private func unexplained(_ position: Position) -> Int {
        guard !still.isEmpty else { return 0 }
        var covered = [Bool](repeating: true, count: 64)
        for snapshot in still {
            let bare = Occupancy.expectedBare(position, camera: snapshot.camera)
            guard let looks = Occupancy.bareness(snapshot, reference: bare) else { return 0 }
            for i in 0..<64 where !(bare[i] && snapshot.visible[i] > 0.95 && looks[i] < 0.3) { covered[i] = false }
        }
        return covered.filter { $0 }.count
    }

    /// More unexplained squares than this means something is in the way.
    var handSquares = 2
    /// Share of a square a hand must hide to count as being over the board.
    var handCoverage: Float = 0.15

    private func averageFit(_ position: Position) -> Float {
        let fits = still.compactMap { Occupancy.fit(position, $0) }
        return fits.isEmpty ? -.infinity : fits.reduce(0, +) / Float(fits.count)
    }

    private func averageBareness(_ position: Position) -> [Float]? {
        guard let last = still.last else { return nil }
        return Occupancy.bareness(last, reference: Occupancy.expectedBare(position, camera: last.camera))
    }
}
