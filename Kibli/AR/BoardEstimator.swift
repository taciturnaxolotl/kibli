import Foundation
import simd

/// One sighting of the grid: its corners where the camera rays hit the table
/// plane, plus where the camera was.
struct BoardObservation: Sendable {
    let corners: [SIMD3<Float>]
    let planeY: Float
    let camera: SIMD3<Float>
    var time: TimeInterval = 0

    /// How far each corner slides, in xz, per meter the true surface sits
    /// above `planeY`. Raising the surface pulls every point back along its
    /// camera ray, so this is the ray's horizontal run over its drop.
    var slopes: [SIMD3<Float>] {
        corners.map { corner in
            var d = (corner - camera) / (planeY - camera.y)
            d.y = 0
            return d
        }
    }

    func corners(atHeight y: Float) -> [SIMD3<Float>] {
        zip(corners, slopes).map { corner, slope in
            var moved = corner + slope * (y - planeY)
            moved.y = y
            return moved
        }
    }
}

/// Fuses sightings from different viewpoints.
///
/// The playing surface of a board with a rim sits a few centimeters above the
/// table plane ARKit finds. Projecting onto the table therefore lands every
/// sighting too far from the camera, by an amount that depends on where the
/// camera stood, which is why the overlay used to slide when you walked
/// around. Sightings only agree on one board position at the true height, so
/// the height falls out of a one-variable least squares fit.
struct BoardEstimator {
    private(set) var observations: [BoardObservation] = []

    /// ARKit's map drifts by a centimeter or two over half a minute, so old
    /// sightings go stale.
    var window: TimeInterval = 8
    var maxObservations = 60
    /// Assumed surface height above the table before there is parallax to
    /// measure, and how strongly to lean on that guess.
    var priorHeight: Float = 0.015
    var priorWeight: Float = 0.1
    var heightRange: ClosedRange<Float> = -0.01...0.10

    mutating func reset() { observations.removeAll() }

    mutating func add(_ observation: BoardObservation) {
        observations.append(observation)
        observations.removeAll { observation.time - $0.time > window }
        if observations.count > maxObservations {
            observations.removeFirst(observations.count - maxObservations)
        }
    }

    /// How varied the viewpoints are, in the same units as the fit. Below
    /// about 0.05 the height is mostly the prior.
    var parallax: Float {
        let centers = observations.map { avg($0.slopes) }
        guard centers.count > 1 else { return 0 }
        let mean = avg(centers)
        return centers.reduce(0) { $0 + simd_length_squared($1 - mean) } / Float(centers.count)
    }

    /// Height of the playing surface in world y.
    func height() -> Float? {
        guard let reference = observations.last?.planeY else { return nil }
        let used = inliers()
        guard !used.isEmpty else { return nil }

        // Each sighting's center moves as q + Y * d with Y the absolute height.
        let d = used.map { avg($0.slopes) }
        let q = zip(used, d).map { avg($0.corners) - $0.planeY * $1 }
        let qMean = avg(q), dMean = avg(d)
        var numerator: Float = 0, denominator: Float = 0
        for (qi, di) in zip(q, d) {
            numerator += simd_dot(qi - qMean, di - dMean)
            denominator += simd_length_squared(di - dMean)
        }
        let prior = reference + priorHeight
        let n = Float(used.count)
        let y = (priorWeight * n * prior - numerator) / (priorWeight * n + denominator)
        return min(max(y, reference + heightRange.lowerBound), reference + heightRange.upperBound)
    }

    /// The fused pose, keeping `yaw` within a quarter turn of `referenceYaw`
    /// since the grid alone can't tell which side is which.
    func pose(referenceYaw: Float) -> BoardPose? {
        guard let y = height() else { return nil }
        let poses = inliers().compactMap { observation in
            BoardPose.fromCorners(observation.corners(atHeight: y), camera: observation.camera)
        }
        guard !poses.isEmpty else { return nil }

        var yawOffset: Float = 0
        for pose in poses { yawOffset += BoardPose.wrapQuarter(pose.yaw - referenceYaw) }
        let sides = poses.map(\.side).sorted()
        return BoardPose(
            center: avg(poses.map(\.center)),
            yaw: referenceYaw + yawOffset / Float(poses.count),
            side: sides[sides.count / 2]
        )
    }

    /// Drops sightings whose center is far from the median, such as a frame
    /// where a hand hid a row and the grid slid over by a square.
    private func inliers() -> [BoardObservation] {
        guard observations.count >= 3 else { return observations }
        let centers = observations.map { avg($0.corners(atHeight: $0.planeY + priorHeight)) }
        let median = SIMD3(
            centers.map(\.x).sorted()[centers.count / 2],
            centers.map(\.y).sorted()[centers.count / 2],
            centers.map(\.z).sorted()[centers.count / 2]
        )
        let kept = zip(observations, centers).filter { simd_distance($1, median) < 0.06 }.map(\.0)
        return kept.isEmpty ? observations : kept
    }
}

private func avg(_ points: [SIMD3<Float>]) -> SIMD3<Float> {
    points.reduce(.zero, +) / Float(max(points.count, 1))
}
