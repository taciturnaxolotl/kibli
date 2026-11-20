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
    }

    struct Frame: Sendable {
        let luma: LumaPlane
        let intrinsics: simd_float3x3
        let camera: simd_float4x4
        let board: simd_float4x4
        let side: Float
    }

    /// Change in bare squares between frames, in normalized luma units, that
    /// counts as something moving over the board.
    var motionThreshold: Float = 7
    var framesToSettle = 3
    /// How much better than the current position a move has to fit, in
    /// squares of evidence.
    var margin: Float = 0.9

    private let queue = DispatchQueue(label: "sh.dunkirk.kibli.moves", qos: .userInitiated)
    private let lock = NSLock()
    private var busy = false

    private var previous: BoardSnapshot?
    private var still: [BoardSnapshot] = []
    /// A move has to win two still checks in a row before it's accepted.
    private var candidate: [Move]?

    func reset() {
        queue.async { [self] in
            previous = nil
            still = []
            candidate = nil
        }
    }

    /// Returns false without doing anything if the last frame is still being
    /// processed.
    func process(_ frame: Frame, position: Position, findOrientation: Bool, completion: @escaping @Sendable (Event) -> Void) -> Bool {
        lock.lock()
        if busy {
            lock.unlock()
            return false
        }
        busy = true
        lock.unlock()

        queue.async { [self] in
            var event = Event.busy
            if let snapshot = BoardSnapshot(
                luma: frame.luma, intrinsics: frame.intrinsics, cameraTransform: frame.camera,
                board: frame.board, side: frame.side
            ) {
                event = handle(snapshot, position: position)
                if findOrientation, case .settled = event, let turns = snapshot.startOrientation() {
                    event = .oriented(quarterTurns: turns)
                }
            }
            lock.lock()
            busy = false
            lock.unlock()
            completion(event)
        }
        return true
    }

    private func handle(_ snapshot: BoardSnapshot, position: Position) -> Event {
        defer { previous = snapshot }

        // Bare squares look the same from anywhere, so they show motion even
        // while the phone itself is moving.
        if let previous {
            let bare = Occupancy.expectedBare(position, camera: snapshot.camera)
            let now = snapshot.squareStats(), then = previous.squareStats()
            let changes = (0..<64).filter { bare[$0] && snapshot.visible[$0] > 0.95 && previous.visible[$0] > 0.95 }.map { abs(now[$0].mean - then[$0].mean) }.sorted()
            let typical = changes.isEmpty ? 0 : changes[changes.count * 3 / 4]
            if typical > motionThreshold {
                still = []
                candidate = nil
                return .busy
            }
        }
        still.append(snapshot)
        if still.count > framesToSettle { still.removeFirst() }
        guard still.count >= framesToSettle else { return .busy }

        let current = averageScore(position)
        var best: (moves: [Move], score: Float)?
        var second: Float = -.infinity
        for move in position.legalMoves() where move.promotion == nil || move.promotion == .queen {
            let score = averageScore(position.playing(move))
            if best == nil || score > best!.score {
                second = best?.score ?? second
                best = ([move], score)
            } else if score > second {
                second = score
            }
        }

        let observed = averageBareness(position) ?? []
        guard let best else { return .settled(fit: current) }

        if best.score > current + margin, best.score > second + margin / 2 {
            if candidate == best.moves {
                candidate = nil
                still = []
                return .moved(best.moves, bareness: observed)
            }
            candidate = best.moves
            return .busy
        }
        candidate = nil

        // Nothing one move away fits better. If the current position fits
        // badly too, a move was probably missed; look two moves ahead.
        if current < expectedFit {
            let found = Occupancy.search(from: position, plies: 2, beam: 12, snapshot: still.last!)
            if let line = found.first, line.moves.count == 2, line.score > current + 2 * margin {
                still = []
                return .moved(line.moves, bareness: observed)
            }
            return .unclear(bareness: observed)
        }
        return .settled(fit: current)
    }

    /// A fit well below this means the position on the board isn't the one
    /// the app thinks it is. A clean match scores around 30.
    private let expectedFit: Float = 12

    private func averageScore(_ position: Position) -> Float {
        let scores = still.compactMap { Occupancy.score(position, $0) }
        return scores.isEmpty ? -.infinity : scores.reduce(0, +) / Float(scores.count)
    }

    private func averageBareness(_ position: Position) -> [Float]? {
        guard let last = still.last else { return nil }
        return Occupancy.bareness(last, reference: Occupancy.expectedBare(position, camera: last.camera))
    }
}
