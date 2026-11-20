import Foundation
import simd

/// Finds the 8x8 playing area in a top-down view of the table.
///
/// 1. The dominant edge direction gives the grid's rotation.
/// 2. Autocorrelating edge projections gives the square size.
/// 3. Every grid phase is scored by how many neighbouring cells alternate
///    light/dark; the best 8x8 window wins. A rim, a hand or a few pieces only
///    cost a handful of pairs, so the real board still comes out on top.
/// 4. The four corners are nudged to maximise signed edge contrast along the
///    interior grid lines, which snaps the grid onto the square boundaries.
struct GridFinder: Sendable {
    struct Result: Sendable {
        /// Corners of the playing area in top-down pixels, ordered as the
        /// grid's (0,0), (8,0), (8,8), (0,8).
        let corners: [SIMD2<Float>]
        /// Neighbouring pairs that alternate correctly, out of 112.
        let checker: Int
        /// Mean signed contrast across interior grid lines, in luma units.
        let edge: Float
    }

    var minSquareMeters: Float = 0.022
    var maxSquareMeters: Float = 0.072
    var contrastThreshold: Float = 12
    /// Cells smoother than this (luma variance) count as featureless.
    var flatVariance: Float = 30
    var phaseStep: Float = 1
    var angleSpan: Float = 4

    func find(in image: TopDownImage) -> Result? {
        let fine = Self.filled(image)
        let coarse = Self.downsample(fine, valid: image.valid, size: image.size)
        let n = image.size / 2
        let metersPerCoarse = image.metersPerPixel * 2

        let theta0 = Self.dominantAngle(coarse.pixels, valid: coarse.valid, size: n)
        let lags = Int(minSquareMeters / metersPerCoarse)...Int((maxSquareMeters / metersPerCoarse).rounded(.up))

        // Coarse pass over angle, square size and grid phase, then a fine
        // pass around the winner. The corner refinement at the end absorbs
        // whatever error is left.
        var best: Candidate?
        var integrals: [Float: (integral: Integral, period: Float)] = [:]
        for degrees in stride(from: -angleSpan, through: angleSpan, by: 2) {
            let theta = theta0 + degrees * .pi / 180
            let rotated = Self.rotate(coarse.pixels, valid: coarse.valid, size: n, theta: theta)
            guard let period0 = Self.period(rotated.pixels, valid: rotated.valid, size: n, lags: lags) else { continue }
            let integral = Integral(rotated.pixels, valid: rotated.valid, size: n)
            integrals[theta] = (integral, period0)

            for period in [period0 - 0.5, period0, period0 + 0.5] where period > 3 {
                for oy in stride(from: Float(0), to: period, by: phaseStep) {
                    for ox in stride(from: Float(0), to: period, by: phaseStep) {
                        consider(integral, theta: theta, period: period, ox: ox, oy: oy, into: &best)
                    }
                }
            }
        }
        if let coarseBest = best {
            // Keep the window's center fixed while the square size changes;
            // holding the phase at the image origin instead would slide the
            // window by half a square once it is a dozen squares out.
            let period0 = coarseBest.period
            let centerX = coarseBest.ox + 4 * period0, centerY = coarseBest.oy + 4 * period0
            for degrees: Float in [-1, 0, 1] {
                let theta = coarseBest.theta + degrees * .pi / 180
                let integral = integrals[theta]?.integral ?? Integral(
                    Self.rotate(coarse.pixels, valid: coarse.valid, size: n, theta: theta), size: n
                )
                for period in stride(from: period0 - 0.5, through: period0 + 0.5, by: 0.25) {
                    let ox0 = (centerX - 4 * period).truncatingRemainder(dividingBy: period)
                    let oy0 = (centerY - 4 * period).truncatingRemainder(dividingBy: period)
                    for oy in stride(from: oy0 - 1.5, through: oy0 + 1.5, by: 0.5) {
                        for ox in stride(from: ox0 - 1.5, through: ox0 + 1.5, by: 0.5) {
                            consider(integral, theta: theta, period: period,
                                     ox: ox < 0 ? ox + period : ox, oy: oy < 0 ? oy + period : oy, into: &best)
                        }
                    }
                }
            }
        }
        guard let best else { return nil }

        let center = SIMD2<Float>(repeating: Float(n) / 2)
        let rotation = simd_float2x2(rows: [
            SIMD2(cos(best.theta), -sin(best.theta)),
            SIMD2(sin(best.theta), cos(best.theta)),
        ])
        let p = best.period
        let coarseCorners = [
            SIMD2(best.ox, best.oy), SIMD2(best.ox + 8 * p, best.oy),
            SIMD2(best.ox + 8 * p, best.oy + 8 * p), SIMD2(best.ox, best.oy + 8 * p),
        ]
        let fineCorners = coarseCorners.map { (center + rotation * ($0 - center)) * 2 + 0.5 }

        let refined = Self.refine(fine, size: image.size, corners: fineCorners)
        return resolveSlide(fine, valid: image.valid, size: image.size, corners: refined.corners)
    }

    /// The window search can land a square or two off when pieces hide whole
    /// rows; the starting position is the worst case, since only the middle
    /// four ranks show any squares. This scores the grid and its neighbours
    /// shifted by up to two squares, at full resolution, and keeps the best.
    private func resolveSlide(_ pixels: [Float], valid: [Bool], size: Int, corners: [SIMD2<Float>]) -> Result {
        let h = Homography(unitSquareTo: corners, scale: 8)
        var candidates: [(score: Float, corners: [SIMD2<Float>])] = []
        for dy in -2...2 {
            for dx in -2...2 {
                let shift = SIMD2(Float(dx), Float(dy))
                let shifted = [SIMD2<Float>(0, 0), SIMD2(8, 0), SIMD2(8, 8), SIMD2(0, 8)].map { h.apply($0 + shift) }
                let score = Self.boardScore(pixels, valid: valid, size: size, corners: shifted, threshold: contrastThreshold, flatVariance: flatVariance)
                candidates.append((score.score, shifted))
            }
        }
        candidates.sort { $0.score > $1.score }

        var best: (score: Float, checker: Int, corners: [SIMD2<Float>], edge: Float)?
        for candidate in candidates.prefix(3) {
            let refined = Self.refine(pixels, size: size, corners: candidate.corners)
            let score = Self.boardScore(pixels, valid: valid, size: size, corners: refined.corners, threshold: contrastThreshold, flatVariance: flatVariance)
            if best == nil || score.score > best!.score {
                best = (score.score, score.checker, refined.corners, refined.edge)
            }
        }
        return Result(corners: best!.corners, checker: best!.checker, edge: best!.edge)
    }

    /// Full-resolution score for an 8x8 board at `corners`: alternating pairs
    /// inside, minus pattern that spills past the edge, minus blank cells,
    /// minus how far the evidence sits from the window's middle.
    static func boardScore(
        _ pixels: [Float], valid: [Bool], size: Int, corners: [SIMD2<Float>],
        threshold: Float, flatVariance: Float
    ) -> (score: Float, checker: Int) {
        let h = Homography(unitSquareTo: corners, scale: 8)
        let offsets: [Float] = [-0.25, 0, 0.25]
        // Cells -1...8 in both directions, so the ring outside is included.
        var means = [Float](repeating: .nan, count: 100)
        var flat = [Bool](repeating: false, count: 100)
        for row in 0..<10 {
            for col in 0..<10 {
                var sum: Float = 0, squares: Float = 0
                var count = 0
                for dy in offsets {
                    for dx in offsets {
                        let p = h.apply(SIMD2(Float(col - 1) + 0.5 + dx, Float(row - 1) + 0.5 + dy))
                        let x = Int(p.x), y = Int(p.y)
                        guard x >= 0, y >= 0, x < size, y < size, valid[y * size + x] else { continue }
                        let value = bilinear(pixels, size: size, p)
                        sum += value
                        squares += value * value
                        count += 1
                    }
                }
                guard count >= 5 else { continue }
                let mean = sum / Float(count)
                means[row * 10 + col] = mean
                flat[row * 10 + col] = squares / Float(count) - mean * mean < flatVariance
            }
        }

        func inside(_ r: Int, _ c: Int) -> Bool { (1...8).contains(r) && (1...8).contains(c) }

        // Learn this board's light and dark square brightness from the cells
        // inside, then only let cells that look like one or the other vote.
        // A rim the same wood as the dark squares sits half on the bevel or
        // table, so it lands in between and stops counting as a column of
        // squares; pieces mostly land in between too.
        var even: [Float] = [], odd: [Float] = []
        for r in 1...8 {
            for c in 1...8 where !means[r * 10 + c].isNaN {
                if (r + c) % 2 == 0 { even.append(means[r * 10 + c]) } else { odd.append(means[r * 10 + c]) }
            }
        }
        var isSquare = [Bool](repeating: true, count: 100)
        if even.count >= 6, odd.count >= 6 {
            let a = even.sorted()[even.count / 2], b = odd.sorted()[odd.count / 2]
            let light = max(a, b), dark = min(a, b)
            let tolerance = max(0.35 * (light - dark), threshold)
            for i in 0..<100 where !means[i].isNaN {
                isSquare[i] = abs(means[i] - light) < tolerance || abs(means[i] - dark) < tolerance
            }
        }

        func vote(_ r: Int, _ c: Int, _ r2: Int, _ c2: Int) -> Int {
            guard isSquare[r * 10 + c], isSquare[r2 * 10 + c2] else { return 0 }
            let d = means[r2 * 10 + c2] - means[r * 10 + c]
            guard !d.isNaN, abs(d) > threshold else { return 0 }
            return ((d < 0) == ((r + c) % 2 == 0)) ? 1 : -1
        }

        var inVotes = 0, outVotes = 0
        var evidence = SIMD2<Float>(0, 0), evidenceVotes: [(SIMD2<Float>, Int)] = []
        for r in 0..<10 {
            for c in 0..<10 {
                for (dr, dc) in [(0, 1), (1, 0)] where r + dr < 10 && c + dc < 10 {
                    let a = inside(r, c), b = inside(r + dr, c + dc)
                    guard a || b else {
                        // Pairs inside the ring itself, alongside the board.
                        let alongside = (r == 0 || r == 9) ? (1...8).contains(c) && (1...8).contains(c + dc)
                                                           : (1...8).contains(r) && (1...8).contains(r + dr)
                        if alongside { outVotes += vote(r, c, r + dr, c + dc) }
                        continue
                    }
                    let v = vote(r, c, r + dr, c + dc)
                    if a && b {
                        inVotes += v
                        evidenceVotes.append((SIMD2(Float(c) + Float(dc) / 2, Float(r) + Float(dr) / 2), v))
                    } else {
                        outVotes += v
                    }
                }
            }
        }

        let polarity = inVotes >= 0 ? 1 : -1
        let spill = max(0, outVotes * polarity)
        var weight: Float = 0
        for (point, v) in evidenceVotes where v * polarity > 0 {
            evidence += point
            weight += 1
        }
        let offCenter = weight > 0 ? simd_reduce_add(abs(evidence / weight - SIMD2(4.5, 4.5))) : 0

        var blanks = 0
        for r in 1...8 {
            for c in 1...8 where flat[r * 10 + c] && !means[r * 10 + c].isNaN {
                var contrasted = false
                for (dr, dc) in [(0, 1), (0, -1), (1, 0), (-1, 0)] {
                    let other = means[(r + dr) * 10 + c + dc]
                    if !other.isNaN, abs(other - means[r * 10 + c]) > threshold { contrasted = true }
                }
                if !contrasted { blanks += 1 }
            }
        }

        let checker = abs(inVotes)
        let rim = rimScore(pixels, valid: valid, size: size, homography: h)
        let score = Float(2 * checker - 2 * spill - 3 * blanks) - 6 * offCenter + rimWeight * rim
        return (score, checker)
    }

    static let rimWeight: Float = 2

    /// A board's playing area is ringed by a frame that looks the same all
    /// the way along, while the outer files and ranks never do: they alternate
    /// light and dark, or hold pieces. So along each edge, the strip just
    /// outside should be smooth and the strip just inside busy. This is what
    /// pins down the starting position, where the four covered ranks leave
    /// the checker pattern free to slide two squares either way.
    static func rimScore(_ pixels: [Float], valid: [Bool], size: Int, homography h: Homography) -> Float {
        func roughness(side: Int, outside: Bool) -> Float? {
            var segments: [Float] = []
            for segment in 0..<16 {
                var sum: Float = 0
                var count = 0
                for step in 0..<4 {
                    let along = (Float(segment) + (Float(step) + 0.5) / 4) / 2
                    for depth: Float in [0.2, 0.3, 0.4] {
                        let d = outside ? -depth : depth
                        let unit: SIMD2<Float>
                        switch side {
                        case 0: unit = SIMD2(along, d)
                        case 1: unit = SIMD2(8 - d, along)
                        case 2: unit = SIMD2(along, 8 - d)
                        default: unit = SIMD2(d, along)
                        }
                        let p = h.apply(unit)
                        let x = Int(p.x), y = Int(p.y)
                        guard x >= 0, y >= 0, x < size, y < size, valid[y * size + x] else { continue }
                        sum += bilinear(pixels, size: size, p)
                        count += 1
                    }
                }
                if count >= 6 { segments.append(sum / Float(count)) }
            }
            guard segments.count >= 10 else { return nil }
            let mean = segments.reduce(0, +) / Float(segments.count)
            let variance = segments.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Float(segments.count)
            return variance.squareRoot()
        }

        var total: Float = 0
        for side in 0..<4 {
            guard let inside = roughness(side: side, outside: false),
                  let outside = roughness(side: side, outside: true)
            else { continue }
            total += max(min(inside - outside, 40), -40)
        }
        return total
    }

    /// Follows a board that is already known: starts from the predicted
    /// corners and only refines locally, so it is cheap and cannot slide over
    /// by a whole square the way a fresh search can when pieces hide rows.
    func track(in image: TopDownImage, predicted: [SIMD2<Float>]) -> Result? {
        let fine = Self.filled(image)
        let refined = Self.refine(fine, size: image.size, corners: predicted)
        let drift = zip(refined.corners, predicted).map { simd_distance($0, $1) }.max() ?? 0
        guard drift * image.metersPerPixel < 0.03 else { return nil }
        let checker = Self.boardScore(
            fine, valid: image.valid, size: image.size, corners: refined.corners,
            threshold: contrastThreshold, flatVariance: flatVariance
        ).checker
        return Result(corners: refined.corners, checker: checker, edge: refined.edge)
    }

    private struct Candidate {
        let score: Int
        let checker: Int
        let theta: Float
        let period: Float
        let phaseX: Float
        let phaseY: Float
        let ox: Float
        let oy: Float
    }

    private func consider(_ integral: Integral, theta: Float, period: Float, ox: Float, oy: Float, into best: inout Candidate?) {
        guard let window = bestWindow(integral, period: period, ox: ox, oy: oy) else { return }
        if best == nil || window.score > best!.score {
            best = Candidate(
                score: window.score, checker: window.checker, theta: theta, period: period,
                phaseX: ox, phaseY: oy,
                ox: ox + Float(window.col) * period, oy: oy + Float(window.row) * period
            )
        }
    }

    // MARK: Checker scoring

    private func bestWindow(_ integral: Integral, period p: Float, ox: Float, oy: Float) -> (score: Int, checker: Int, col: Int, row: Int)? {
        let n = integral.size
        let cols = Int((Float(n) - ox) / p)
        let rows = Int((Float(n) - oy) / p)
        guard cols >= 8, rows >= 8 else { return nil }

        let inset = 0.2 * p
        var means = [Float](repeating: .nan, count: cols * rows)
        var flat = [Bool](repeating: false, count: cols * rows)
        for r in 0..<rows {
            let y0 = Int((oy + Float(r) * p + inset).rounded())
            let y1 = Int((oy + Float(r + 1) * p - inset).rounded())
            for c in 0..<cols {
                let x0 = Int((ox + Float(c) * p + inset).rounded())
                let x1 = Int((ox + Float(c + 1) * p - inset).rounded())
                let area = (x1 - x0) * (y1 - y0)
                guard area > 0 else { continue }
                let count = integral.count(x0, y0, x1, y1)
                if count > 0.7 * Float(area) {
                    let mean = integral.sum(x0, y0, x1, y1) / count
                    means[r * cols + c] = mean
                    let variance = integral.sumOfSquares(x0, y0, x1, y1) / count - mean * mean
                    flat[r * cols + c] = variance < flatVariance
                }
            }
        }

        // +1 where a neighbouring pair alternates the way a checkerboard
        // starting light at (0,0) would, -1 where it alternates the other way.
        let threshold = contrastThreshold
        func vote(_ a: Float, _ b: Float, parity: Int) -> Int {
            let d = b - a
            guard !d.isNaN, abs(d) > threshold else { return 0 }
            let sign = d < 0 ? 1 : -1
            return parity % 2 == 0 ? sign : -sign
        }

        // Prefix sums over horizontal and vertical pair votes.
        var h = [Int](repeating: 0, count: (rows + 1) * cols)
        var v = [Int](repeating: 0, count: rows * (cols + 1))
        let hw = cols, vw = cols + 1
        for r in 0..<rows {
            for c in 0..<(cols - 1) {
                let value = vote(means[r * cols + c], means[r * cols + c + 1], parity: r + c)
                h[(r + 1) * hw + c + 1] = value + h[r * hw + c + 1] + h[(r + 1) * hw + c] - h[r * hw + c]
            }
        }
        for r in 0..<(rows - 1) {
            for c in 0..<cols {
                let value = vote(means[r * cols + c], means[(r + 1) * cols + c], parity: r + c)
                v[(r + 1) * vw + c + 1] = value + v[r * vw + c + 1] + v[(r + 1) * vw + c] - v[r * vw + c]
            }
        }

        // A blank cell is smooth inside and matches its neighbours: table or
        // rim. Real squares always contrast with something and occupied ones
        // are textured, so blanks inside a window mean it hangs off the board.
        // Without this, a starting position (four rows covered by pieces) lets
        // the window slide a couple of squares onto the table for free.
        var blank = [Int](repeating: 0, count: (rows + 1) * (cols + 1))
        for r in 0..<rows {
            for c in 0..<cols {
                var value = 0
                let here = means[r * cols + c]
                if flat[r * cols + c], !here.isNaN {
                    value = 1
                    for (dr, dc) in [(0, 1), (0, -1), (1, 0), (-1, 0)] {
                        let rr = r + dr, cc = c + dc
                        guard rr >= 0, cc >= 0, rr < rows, cc < cols else { continue }
                        let there = means[rr * cols + cc]
                        if !there.isNaN, abs(there - here) > threshold { value = 0 }
                    }
                }
                blank[(r + 1) * vw + c + 1] = value + blank[r * vw + c + 1] + blank[(r + 1) * vw + c] - blank[r * vw + c]
            }
        }

        // Sums of pair votes over [r0, r1) x [c0, c1), clamped to the grid.
        func hSum(_ r0: Int, _ r1: Int, _ c0: Int, _ c1: Int) -> Int {
            let r0 = max(r0, 0), r1 = min(r1, rows), c0 = max(c0, 0), c1 = min(c1, cols - 1)
            guard r1 > r0, c1 > c0 else { return 0 }
            return h[r1 * hw + c1] - h[r0 * hw + c1] - h[r1 * hw + c0] + h[r0 * hw + c0]
        }
        func vSum(_ r0: Int, _ r1: Int, _ c0: Int, _ c1: Int) -> Int {
            let r0 = max(r0, 0), r1 = min(r1, rows - 1), c0 = max(c0, 0), c1 = min(c1, cols)
            guard r1 > r0, c1 > c0 else { return 0 }
            return v[r1 * vw + c1] - v[r0 * vw + c1] - v[r1 * vw + c0] + v[r0 * vw + c0]
        }

        var best: (score: Int, checker: Int, col: Int, row: Int)?
        for r0 in 0...(rows - 8) {
            for c0 in 0...(cols - 8) {
                let inside = hSum(r0, r0 + 8, c0, c0 + 7) + vSum(r0, r0 + 7, c0, c0 + 8)
                // The pattern has to stop at the window's edge, since a board
                // has exactly eight rows and columns. Squares that keep
                // alternating just outside mean the window is a square off.
                let outside = hSum(r0, r0 + 8, c0 - 1, c0) + hSum(r0, r0 + 8, c0 + 7, c0 + 8)
                    + hSum(r0 - 1, r0, c0, c0 + 7) + hSum(r0 + 8, r0 + 9, c0, c0 + 7)
                    + vSum(r0 - 1, r0, c0, c0 + 8) + vSum(r0 + 7, r0 + 8, c0, c0 + 8)
                    + vSum(r0, r0 + 7, c0 - 1, c0) + vSum(r0, r0 + 7, c0 + 8, c0 + 9)
                let blanks = blank[(r0 + 8) * vw + c0 + 8] - blank[r0 * vw + c0 + 8] - blank[(r0 + 8) * vw + c0] + blank[r0 * vw + c0]
                let checker = abs(inside)
                let spill = max(0, inside >= 0 ? outside : -outside)
                let score = 2 * checker - 2 * spill - 3 * blanks
                if best == nil || score > best!.score { best = (score, checker, c0, r0) }
            }
        }
        return best
    }

    // MARK: Refinement

    private static let edgeSamples: [(point: SIMD2<Float>, normal: SIMD2<Float>, sign: Float)] = {
        var samples: [(SIMD2<Float>, SIMD2<Float>, Float)] = []
        let ts: [Float] = [0.15, 0.29, 0.43, 0.57, 0.71, 0.85]
        for i in 1..<8 {
            for j in 0..<8 {
                let sign: Float = (i + j) % 2 == 1 ? 1 : -1
                for t in ts {
                    samples.append((SIMD2(Float(i), Float(j) + t), SIMD2(1, 0), sign))
                    samples.append((SIMD2(Float(j) + t, Float(i)), SIMD2(0, 1), sign))
                }
            }
        }
        return samples
    }()

    static func refine(_ pixels: [Float], size: Int, corners start: [SIMD2<Float>]) -> (corners: [SIMD2<Float>], edge: Float) {
        func score(_ corners: [SIMD2<Float>]) -> Float {
            let h = Homography(unitSquareTo: corners.map { $0 }, scale: 8)
            var total: Float = 0
            for sample in edgeSamples {
                let a = h.apply(sample.point + sample.normal * 0.08)
                let b = h.apply(sample.point - sample.normal * 0.08)
                let d = bilinear(pixels, size: size, a) - bilinear(pixels, size: size, b)
                total += max(min(d, 40), -40) * sample.sign
            }
            return total
        }

        // Corners may only move a fraction of a square. Without the leash the
        // climb can walk the whole grid a square over when pieces happen to
        // line up better that way.
        let square = (0..<4).map { simd_distance(start[$0], start[($0 + 1) % 4]) }.reduce(0, +) / 32
        let leash = 0.6 * square

        var corners = start
        let polarity: Float = score(corners) >= 0 ? 1 : -1
        var best = score(corners) * polarity
        for step: Float in [4, 2, 1, 0.5, 0.25] {
            var improved = true
            while improved {
                improved = false
                for k in 0..<4 {
                    for axis in 0..<2 {
                        for direction: Float in [1, -1] {
                            var trial = corners
                            trial[k][axis] += direction * step
                            guard simd_distance(trial[k], start[k]) <= leash else { continue }
                            let s = score(trial) * polarity
                            if s > best {
                                best = s
                                corners = trial
                                improved = true
                            }
                        }
                    }
                }
            }
        }
        return (corners, best / Float(edgeSamples.count))
    }

    // MARK: Image helpers

    private static func filled(_ image: TopDownImage) -> [Float] {
        var sum: Float = 0
        var count = 0
        for i in 0..<image.pixels.count where image.valid[i] {
            sum += image.pixels[i]
            count += 1
        }
        let mean = count > 0 ? sum / Float(count) : 128
        return zip(image.pixels, image.valid).map { $1 ? $0 : mean }
    }

    private static func downsample(_ pixels: [Float], valid: [Bool], size: Int) -> (pixels: [Float], valid: [Bool]) {
        let n = size / 2
        var out = [Float](repeating: 0, count: n * n)
        var ok = [Bool](repeating: false, count: n * n)
        for y in 0..<n {
            for x in 0..<n {
                let i = 2 * y * size + 2 * x
                out[y * n + x] = (pixels[i] + pixels[i + 1] + pixels[i + size] + pixels[i + size + 1]) / 4
                ok[y * n + x] = valid[i] && valid[i + 1] && valid[i + size] && valid[i + size + 1]
            }
        }
        return (out, ok)
    }

    private static func dominantAngle(_ pixels: [Float], valid: [Bool], size n: Int) -> Float {
        var re: Float = 0, im: Float = 0
        for y in 1..<(n - 1) {
            for x in 1..<(n - 1) where valid[y * n + x] {
                let gx = pixels[y * n + x + 1] - pixels[y * n + x - 1]
                let gy = pixels[(y + 1) * n + x] - pixels[(y - 1) * n + x]
                let magnitude = (gx * gx + gy * gy).squareRoot()
                guard magnitude > 1 else { continue }
                let angle = 4 * atan2(gy, gx)
                re += magnitude * cos(angle)
                im += magnitude * sin(angle)
            }
        }
        return atan2(im, re) / 4
    }

    private static func rotate(_ pixels: [Float], valid: [Bool], size n: Int, theta: Float) -> (pixels: [Float], valid: [Bool]) {
        var out = [Float](repeating: 0, count: n * n)
        var ok = [Bool](repeating: false, count: n * n)
        let c = cos(theta), s = sin(theta)
        let mid = Float(n) / 2
        for y in 0..<n {
            for x in 0..<n {
                let dx = Float(x) - mid, dy = Float(y) - mid
                let sx = mid + c * dx - s * dy
                let sy = mid + s * dx + c * dy
                guard sx >= 0, sy >= 0, sx < Float(n - 1), sy < Float(n - 1) else { continue }
                let x0 = Int(sx), y0 = Int(sy)
                let i = y0 * n + x0
                guard valid[i], valid[i + 1], valid[i + n], valid[i + n + 1] else { continue }
                let ax = sx - Float(x0), ay = sy - Float(y0)
                let top = pixels[i] * (1 - ax) + pixels[i + 1] * ax
                let bottom = pixels[i + n] * (1 - ax) + pixels[i + n + 1] * ax
                out[y * n + x] = top * (1 - ay) + bottom * ay
                ok[y * n + x] = true
            }
        }
        return (out, ok)
    }

    /// Square size in pixels from the autocorrelation of edge projections.
    private static func period(_ pixels: [Float], valid: [Bool], size n: Int, lags: ClosedRange<Int>) -> Float? {
        var px = [Float](repeating: 0, count: n)
        var py = [Float](repeating: 0, count: n)
        for y in 1..<(n - 1) {
            for x in 1..<(n - 1) {
                let i = y * n + x
                guard valid[i], valid[i - 1], valid[i + 1], valid[i - n], valid[i + n] else { continue }
                px[x] += abs(pixels[i + 1] - pixels[i - 1])
                py[y] += abs(pixels[i + n] - pixels[i - n])
            }
        }

        func autocorrelation(_ signal: [Float]) -> [Float] {
            let radius = 7
            var detrended = signal
            for i in 0..<n {
                let lo = max(0, i - radius), hi = min(n - 1, i + radius)
                var mean: Float = 0
                for j in lo...hi { mean += signal[j] }
                detrended[i] = signal[i] - mean / Float(hi - lo + 1)
            }
            var zero: Float = 0
            for value in detrended { zero += value * value }
            guard zero > 0 else { return [] }
            return (0...lags.upperBound).map { lag in
                var sum: Float = 0
                for i in 0..<(n - lag) { sum += detrended[i] * detrended[i + lag] }
                return sum / zero
            }
        }

        let ax = autocorrelation(px), ay = autocorrelation(py)
        guard !ax.isEmpty, !ay.isEmpty else { return nil }
        let bestLag = lags.max { ax[$0] + ay[$0] < ax[$1] + ay[$1] }!
        return Float(bestLag)
    }

    static func bilinear(_ pixels: [Float], size n: Int, _ point: SIMD2<Float>) -> Float {
        let x = min(max(point.x, 0), Float(n - 2))
        let y = min(max(point.y, 0), Float(n - 2))
        let x0 = Int(x), y0 = Int(y)
        let ax = x - Float(x0), ay = y - Float(y0)
        let i = y0 * n + x0
        let top = pixels[i] * (1 - ax) + pixels[i + 1] * ax
        let bottom = pixels[i + n] * (1 - ax) + pixels[i + n + 1] * ax
        return top * (1 - ay) + bottom * ay
    }
}

/// Summed-area tables of brightness and valid-pixel count.
private struct Integral {
    let size: Int

    init(_ rotated: (pixels: [Float], valid: [Bool]), size n: Int) {
        self.init(rotated.pixels, valid: rotated.valid, size: n)
    }
    private var sums: [Double]
    private var squares: [Double]
    private var counts: [Float]

    init(_ pixels: [Float], valid: [Bool], size n: Int) {
        size = n
        let w = n + 1
        sums = [Double](repeating: 0, count: w * w)
        squares = [Double](repeating: 0, count: w * w)
        counts = [Float](repeating: 0, count: w * w)
        for y in 0..<n {
            var rowSum: Double = 0
            var rowSquares: Double = 0
            var rowCount: Float = 0
            for x in 0..<n {
                if valid[y * n + x] {
                    let value = Double(pixels[y * n + x])
                    rowSum += value
                    rowSquares += value * value
                    rowCount += 1
                }
                sums[(y + 1) * w + x + 1] = sums[y * w + x + 1] + rowSum
                squares[(y + 1) * w + x + 1] = squares[y * w + x + 1] + rowSquares
                counts[(y + 1) * w + x + 1] = counts[y * w + x + 1] + rowCount
            }
        }
    }

    func sum(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) -> Float {
        let w = size + 1
        let x0 = clamp(x0), x1 = clamp(x1), y0 = clamp(y0), y1 = clamp(y1)
        return Float(sums[y1 * w + x1] - sums[y0 * w + x1] - sums[y1 * w + x0] + sums[y0 * w + x0])
    }

    func sumOfSquares(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) -> Float {
        let w = size + 1
        let x0 = clamp(x0), x1 = clamp(x1), y0 = clamp(y0), y1 = clamp(y1)
        return Float(squares[y1 * w + x1] - squares[y0 * w + x1] - squares[y1 * w + x0] + squares[y0 * w + x0])
    }

    func count(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) -> Float {
        let w = size + 1
        let x0 = clamp(x0), x1 = clamp(x1), y0 = clamp(y0), y1 = clamp(y1)
        return counts[y1 * w + x1] - counts[y0 * w + x1] - counts[y1 * w + x0] + counts[y0 * w + x0]
    }

    private func clamp(_ v: Int) -> Int { min(max(v, 0), size) }
}

/// Maps the square [0, scale]^2 onto an arbitrary quad.
struct Homography: Sendable {
    let a, b, c, d, e, f, g, h: Float
    let scale: Float

    init(unitSquareTo q: [SIMD2<Float>], scale: Float = 1) {
        self.scale = scale
        let sx = q[0].x - q[1].x + q[2].x - q[3].x
        let sy = q[0].y - q[1].y + q[2].y - q[3].y
        if abs(sx) < 1e-6, abs(sy) < 1e-6 {
            a = q[1].x - q[0].x; b = q[3].x - q[0].x; c = q[0].x
            d = q[1].y - q[0].y; e = q[3].y - q[0].y; f = q[0].y
            g = 0; h = 0
        } else {
            let dx1 = q[1].x - q[2].x, dx2 = q[3].x - q[2].x
            let dy1 = q[1].y - q[2].y, dy2 = q[3].y - q[2].y
            let den = dx1 * dy2 - dx2 * dy1
            let g = (sx * dy2 - dx2 * sy) / den
            let h = (dx1 * sy - sx * dy1) / den
            self.g = g; self.h = h
            a = q[1].x - q[0].x + g * q[1].x; b = q[3].x - q[0].x + h * q[3].x; c = q[0].x
            d = q[1].y - q[0].y + g * q[1].y; e = q[3].y - q[0].y + h * q[3].y; f = q[0].y
        }
    }

    func apply(_ p: SIMD2<Float>) -> SIMD2<Float> {
        let u = p.x / scale, v = p.y / scale
        let w = g * u + h * v + 1
        return SIMD2((a * u + b * v + c) / w, (d * u + e * v + f) / w)
    }
}
