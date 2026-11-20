import simd

/// Where the board sits in world space. The board's local frame has +x running
/// from the a-file to the h-file, +y up out of the table, and -z running from
/// rank 1 to rank 8, so a white player standing at +z sees it the normal way.
struct BoardPose: Equatable, Sendable {
    var center: SIMD3<Float>
    /// Rotation about world +y. The file axis is (cos yaw, 0, -sin yaw).
    var yaw: Float
    /// Edge length of whatever was detected, in meters.
    var side: Float

    var rotation: simd_quatf { simd_quatf(angle: yaw, axis: [0, 1, 0]) }

    var transform: simd_float4x4 {
        var matrix = simd_float4x4(rotation)
        matrix.columns.3 = SIMD4(center, 1)
        return matrix
    }

    init(center: SIMD3<Float>, yaw: Float, side: Float) {
        self.center = center
        self.yaw = yaw
        self.side = side
    }

    init(transform: simd_float4x4, side: Float) {
        let x = SIMD3(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z)
        self.init(
            center: SIMD3(transform.columns.3.x, transform.columns.3.y, transform.columns.3.z),
            yaw: atan2(-x.z, x.x),
            side: side
        )
    }

    /// Builds a pose from four points on the table, in any order. The edge
    /// nearest the camera becomes rank 1, which matches someone filming from
    /// the white side.
    static func fromCorners(_ points: [SIMD3<Float>], camera: SIMD3<Float>) -> BoardPose? {
        guard points.count == 4 else { return nil }
        let centroid = points.reduce(.zero, +) / 4
        let sorted = points.sorted {
            atan2($0.z - centroid.z, $0.x - centroid.x) < atan2($1.z - centroid.z, $1.x - centroid.x)
        }

        var toCamera = camera - centroid
        toCamera.y = 0
        guard simd_length(toCamera) > 1e-4 else { return nil }
        toCamera = simd_normalize(toCamera)

        var nearIndex = 0
        var bestScore = -Float.infinity
        for i in 0..<4 {
            var mid = (sorted[i] + sorted[(i + 1) % 4]) / 2 - centroid
            mid.y = 0
            let score = simd_dot(simd_normalize(mid), toCamera)
            if score > bestScore {
                bestScore = score
                nearIndex = i
            }
        }

        let right = simd_cross(-toCamera, [0, 1, 0])
        var a1 = sorted[nearIndex]
        var h1 = sorted[(nearIndex + 1) % 4]
        var a8 = sorted[(nearIndex + 3) % 4]
        var h8 = sorted[(nearIndex + 2) % 4]
        if simd_dot(a1 - centroid, right) > simd_dot(h1 - centroid, right) {
            swap(&a1, &h1)
            swap(&a8, &h8)
        }

        var fileAxis = (h1 - a1) + (h8 - a8)
        fileAxis.y = 0
        guard simd_length(fileAxis) > 1e-4 else { return nil }

        let edges = [h1 - a1, h8 - h1, a8 - h8, a1 - a8].map(simd_length)
        return BoardPose(
            center: centroid,
            yaw: atan2(-fileAxis.z, fileAxis.x),
            side: edges.reduce(0, +) / 4
        )
    }

    /// Two taps on opposite corners: the outer corner of a1 and of h8.
    static func fromDiagonal(a1: SIMD3<Float>, h8: SIMD3<Float>) -> BoardPose? {
        var diagonal = h8 - a1
        diagonal.y = 0
        let length = simd_length(diagonal)
        guard length > 0.05 else { return nil }
        return BoardPose(
            center: (a1 + h8) / 2,
            yaw: atan2(-diagonal.z, diagonal.x) - .pi / 4,
            side: length / Float(2).squareRoot()
        )
    }

    /// Blends toward `other`, treating yaw as defined modulo a quarter turn
    /// since a square looks the same rotated by 90 degrees.
    func blended(toward other: BoardPose, amount: Float) -> BoardPose {
        let delta = Self.wrapQuarter(other.yaw - yaw)
        return BoardPose(
            center: simd_mix(center, other.center, SIMD3(repeating: amount)),
            yaw: yaw + delta * amount,
            side: side + (other.side - side) * amount
        )
    }

    static func wrapQuarter(_ angle: Float) -> Float {
        let quarter = Float.pi / 2
        var wrapped = angle.truncatingRemainder(dividingBy: quarter)
        if wrapped > quarter / 2 { wrapped -= quarter }
        if wrapped < -quarter / 2 { wrapped += quarter }
        return wrapped
    }
}
