import simd

/// The playing area resampled straight from the camera into board squares:
/// `squarePixels` per square, row 0 at rank 8 and column 0 at the a-file, the
/// way a diagram is drawn. Because it is built from the tracked pose, the same
/// pixel always covers the same spot on the board, so two snapshots can be
/// compared square by square.
struct BoardSnapshot: Sendable {
    static let squarePixels = 24
    static let size = squarePixels * 8

    let pixels: [Float]
    /// Mean brightness, spread and edge energy of the middle of each square,
    /// indexed rank * 8 + file.
    private(set) var stats: [(mean: Float, deviation: Float, edges: Float)] = []
    /// Fraction of each square that was inside the camera image.
    private(set) var visible: [Float] = []
    private let valid: [Bool]
    /// Camera position in board units (a1 corner at the origin, one unit per
    /// square, +x toward the h-file, +y toward rank 8, +z up).
    let camera: SIMD3<Float>

    init?(luma: LumaPlane, intrinsics: simd_float3x3, cameraTransform: simd_float4x4, board: simd_float4x4, side: Float) {
        let n = Self.size
        let fx = intrinsics.columns.0.x, fy = intrinsics.columns.1.y
        let cx = intrinsics.columns.2.x, cy = intrinsics.columns.2.y
        let toCamera = cameraTransform.inverse * board
        let step = side / Float(n)
        let half = side / 2

        var pixels = [Float](repeating: 0, count: n * n)
        var valid = [Bool](repeating: false, count: n * n)
        var missing = 0
        let width = luma.width, height = luma.height
        let maxX = Float(width - 2), maxY = Float(height - 2)
        luma.bytes.withUnsafeBufferPointer { bytes in
            for row in 0..<n {
                let z = -half + (Float(row) + 0.5) * step
                for col in 0..<n {
                    let x = -half + (Float(col) + 0.5) * step
                    let p = toCamera * SIMD4(x, 0, z, 1)
                    let depth = -p.z
                    guard depth > 0.05 else { missing += 1; continue }
                    let u = cx + fx * p.x / depth
                    let v = cy - fy * p.y / depth
                    guard u >= 0, v >= 0, u < maxX, v < maxY else { missing += 1; continue }
                    let x0 = Int(u), y0 = Int(v)
                    let ax = u - Float(x0), ay = v - Float(y0)
                    let i = y0 * width + x0
                    let top = Float(bytes[i]) * (1 - ax) + Float(bytes[i + 1]) * ax
                    let bottom = Float(bytes[i + width]) * (1 - ax) + Float(bytes[i + width + 1]) * ax
                    pixels[row * n + col] = top * (1 - ay) + bottom * ay
                    valid[row * n + col] = true
                }
            }
        }
        guard missing < n * n / 2 else { return nil }
        self.valid = valid

        // Divide out overall brightness so auto exposure doesn't look like
        // every square changing at once.
        let sorted = zip(pixels, valid).filter(\.1).map(\.0).sorted()
        let median = max(sorted[sorted.count / 2], 1)
        self.pixels = pixels.map { $0 / median * 128 }

        let local = board.inverse * cameraTransform.columns.3
        camera = SIMD3((local.x + half) / side * 8, (half - local.z) / side * 8, local.y / side * 8)
        stats = computeStats()
        let k = Self.squarePixels
        visible = (0..<64).map { index in
            let rank = index / 8, file = index % 8
            var count = 0
            for row in ((7 - rank) * k)..<((8 - rank) * k) {
                for col in (file * k)..<((file + 1) * k) where valid[row * n + col] { count += 1 }
            }
            return Float(count) / Float(k * k)
        }
    }

    /// Mean brightness and spread of the middle of each square, indexed
    /// rank * 8 + file.
    func squareStats() -> [(mean: Float, deviation: Float, edges: Float)] { stats }

    private func computeStats() -> [(mean: Float, deviation: Float, edges: Float)] {
        let n = Self.size, k = Self.squarePixels
        let inset = k / 4
        return (0..<64).map { index in
            let rank = index / 8, file = index % 8
            let row0 = (7 - rank) * k, col0 = file * k
            var sum: Float = 0, squares: Float = 0
            for row in (row0 + inset)..<(row0 + k - inset) {
                for col in (col0 + inset)..<(col0 + k - inset) {
                    let v = pixels[row * n + col]
                    sum += v
                    squares += v * v
                }
            }
            let count = Float((k - 2 * inset) * (k - 2 * inset))
            let mean = sum / count
            // Sharp edges: wood grain is soft and runs one way, pieces have
            // outlines and highlights.
            var edges: Float = 0
            for row in (row0 + inset)..<(row0 + k - inset) {
                for col in (col0 + inset)..<(col0 + k - inset) {
                    let gx = pixels[row * n + col + 1] - pixels[row * n + col - 1]
                    let gy = pixels[(row + 1) * n + col] - pixels[(row - 1) * n + col]
                    edges += (gx * gx + gy * gy).squareRoot()
                }
            }
            return (mean, max(squares / count - mean * mean, 0).squareRoot(), edges / count)
        }
    }

    /// Mean absolute difference per square, using the middle of each square
    /// so a slightly shifted pose doesn't light up every border. Indexed
    /// rank * 8 + file.
    func difference(from other: BoardSnapshot) -> [Float] {
        let n = Self.size, k = Self.squarePixels
        let inset = k / 6
        var result = [Float](repeating: 0, count: 64)
        for rank in 0..<8 {
            for file in 0..<8 {
                let row0 = (7 - rank) * k, col0 = file * k
                var sum: Float = 0
                for row in (row0 + inset)..<(row0 + k - inset) {
                    for col in (col0 + inset)..<(col0 + k - inset) {
                        sum += abs(pixels[row * n + col] - other.pixels[row * n + col])
                    }
                }
                result[rank * 8 + file] = sum / Float((k - 2 * inset) * (k - 2 * inset))
            }
        }
        return result
    }

    /// Quarter turns that bring white's pieces to the bottom, if this looks
    /// like the starting position: two textured bands on opposite edges and
    /// a smooth middle. Nil if it doesn't.
    func startOrientation() -> Int? {
        let n = Self.size, k = Self.squarePixels
        var texture = [Float](repeating: 0, count: 64)
        var brightness = [Float](repeating: 0, count: 64)
        for row in 0..<8 {
            for col in 0..<8 {
                var sum: Float = 0, squares: Float = 0
                let inset = k / 6
                for y in (row * k + inset)..<((row + 1) * k - inset) {
                    for x in (col * k + inset)..<((col + 1) * k - inset) {
                        let v = pixels[y * n + x]
                        sum += v
                        squares += v * v
                    }
                }
                let count = Float((k - 2 * inset) * (k - 2 * inset))
                let mean = sum / count
                texture[row * 8 + col] = (squares / count - mean * mean).squareRoot()
                brightness[row * 8 + col] = mean
            }
        }
        func band(_ cells: [(Int, Int)], _ values: [Float]) -> Float {
            cells.reduce(0) { $0 + values[$1.0 * 8 + $1.1] } / Float(cells.count)
        }
        let all = (0..<8).flatMap { a in (0..<8).map { (a, $0) } }
        let top = all.filter { $0.0 < 2 }, bottom = all.filter { $0.0 > 5 }
        let left = all.filter { $0.1 < 2 }, right = all.filter { $0.1 > 5 }
        let middle = all.filter { (2...5).contains($0.0) && (2...5).contains($0.1) }

        let calm = band(middle, texture)
        let ranksBusy = min(band(top, texture), band(bottom, texture))
        let filesBusy = min(band(left, texture), band(right, texture))
        let busiest = max(ranksBusy, filesBusy)
        guard busiest > 1.4 * calm else { return nil }

        if ranksBusy >= filesBusy {
            return band(bottom, brightness) >= band(top, brightness) ? 0 : 2
        }
        return band(right, brightness) >= band(left, brightness) ? 1 : 3
    }

    /// Mean brightness of whole ranks, used to tell which end white is on.
    func rankBrightness(_ ranks: ClosedRange<Int>) -> Float {
        let n = Self.size, k = Self.squarePixels
        var sum: Float = 0
        var count = 0
        for rank in ranks {
            for row in ((7 - rank) * k)..<((8 - rank) * k) {
                for col in 0..<n {
                    sum += pixels[row * n + col]
                    count += 1
                }
            }
        }
        return sum / Float(max(count, 1))
    }

    /// The square one step farther from the camera, where a piece standing on
    /// `square` shows up in this view because it sticks up out of the board.
    func shadowSquare(of square: Square) -> Square? {
        let center = SIMD2(Float(square.file) + 0.5, Float(square.rank) + 0.5)
        let away = center - SIMD2(camera.x, camera.y)
        guard simd_length(away) > 0.01 else { return nil }
        let direction = simd_normalize(away)
        return Square(file: square.file + Int(direction.x.rounded()), rank: square.rank + Int(direction.y.rounded()))
    }
}
