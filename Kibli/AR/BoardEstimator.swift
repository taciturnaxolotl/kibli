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
    var window: TimeInterval = 20
    var maxObservations = 90
    /// Assumed surface height above the table before there is parallax to
    /// measure, and how strongly to lean on that guess.
    var priorHeight: Float = 0.015
    var heightRange: ClosedRange<Float> = -0.01...0.12

    mutating func reset() { observations.removeAll() }

    /// Moves every sighting sideways, for when the board turns out to have
    /// been locked a square off.
    mutating func shift(by offset: SIMD3<Float>) {
        observations = observations.map { o in
            var moved = BoardObservation(corners: o.corners.map { $0 + offset }, planeY: o.planeY, camera: o.camera)
            moved.time = o.time
            return moved
        }
    }

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
    ///
    /// Tries every height in `heightRange` and keeps the one where the
    /// sightings agree best, measured by the median distance of each
    /// corrected center from their median. Medians shrug off sightings where
    /// the grid slid a square, so no outlier pass is needed first, and a
    /// starting guess that's far off (a board on its box sits 6 cm up) can't
    /// throw away the very sightings that would correct it. A small pull
    /// toward `priorHeight` decides when there's no viewpoint variety yet.
    func height() -> Float? { fit()?.y }

    private func fit() -> (y: Float, kept: [BoardObservation])? {
        guard let reference = observations.last?.planeY, !observations.isEmpty else { return nil }
        // Center and slope per sighting, measured from its own plane.
        let centers = observations.map { avg($0.corners) }
        let slopes = observations.map { avg($0.slopes) }
        let planes = observations.map(\.planeY)

        func spread(_ h: Float) -> (cost: Float, points: [SIMD2<Float>], median: SIMD2<Float>) {
            let points = (0..<centers.count).map { i -> SIMD2<Float> in
                let c = centers[i] + slopes[i] * (reference + h - planes[i])
                return SIMD2(c.x, c.z)
            }
            let median = SIMD2(points.map(\.x).sorted()[points.count / 2], points.map(\.y).sorted()[points.count / 2])
            let distances = points.map { simd_distance($0, median) }.sorted()
            return (distances[distances.count / 2], points, median)
        }

        var best: (h: Float, cost: Float)?
        for h in stride(from: heightRange.lowerBound, through: heightRange.upperBound, by: 0.0025) {
            // 1 cm of departure from the prior costs as much as 0.5 mm of spread.
            let cost = spread(h).cost + 0.05 * abs(h - priorHeight)
            if best == nil || cost < best!.cost { best = (h, cost) }
        }
        guard let best else { return nil }
        let chosen = spread(best.h)
        let kept = zip(observations, chosen.points).filter { simd_distance($1, chosen.median) < 0.025 }.map(\.0)
        return (reference + best.h, kept.isEmpty ? observations : kept)
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

    /// Sightings that agree with the others at the fitted height.
    private func inliers() -> [BoardObservation] {
        fit()?.kept ?? observations
    }
}

private func avg(_ points: [SIMD3<Float>]) -> SIMD3<Float> {
    points.reduce(.zero, +) / Float(max(points.count, 1))
}
