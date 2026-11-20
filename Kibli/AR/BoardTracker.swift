import ARKit
import Observation
import RealityKit
import UIKit

/// Owns the AR session and walks through finding the board: wait for a table
/// plane, look straight down at it through the camera, find a stable 8x8
/// checker grid, then lock an anchor there.
@MainActor
@Observable
final class BoardTracker {
    enum Phase: Equatable {
        case findingTable
        case findingBoard(progress: Double)
        case tappingCorners(remaining: Int)
        case locked
    }

    private(set) var phase: Phase = .findingTable
    private(set) var trackingNote: String?
    private(set) var selected: Square?
    private(set) var lastTapped: Square?

    private(set) var debugImage: CGImage?
    private(set) var lastChecker = 0
    /// Playing surface height above the table plane, in meters.
    private(set) var surfaceHeight: Float?
    private(set) var parallax: Float = 0

    /// Whether the camera can currently see the board's grid.
    enum Visibility: Equatable {
        case seeing
        case glimpsing
        case notSeen(seconds: Int)
    }

    private(set) var visibility: Visibility = .notSeen(seconds: 0)
    /// Sightings currently feeding the fused pose.
    private(set) var sightings = 0
    /// Bumped on every lock, so the view can play a haptic.
    private(set) var lockCount = 0
    /// Locked from corner taps, so there are no grid sightings to follow.
    private(set) var isManualLock = false
    /// Bumped on every saved capture.
    private(set) var savedCount = 0

    /// 0 to 1, how much viewpoint variety backs the surface height.
    var calibration: Double { min(Double(parallax) / 0.1, 1) }

    private(set) var captureCount = FrameCapture.count
    private(set) var captureNote: String?

    var quarterTurns = 0 { didSet { refreshOverlay() } }
    var showsDebug = false

    @ObservationIgnored private weak var arView: ARView?
    @ObservationIgnored private let overlay = BoardOverlay()
    @ObservationIgnored private let overlayAnchor = AnchorEntity(world: .zero)
    @ObservationIgnored private let locator = BoardLocator()
    @ObservationIgnored private let delegate = SessionDelegate()
    @ObservationIgnored private let focus = CameraFocus()

    @ObservationIgnored private var pose: BoardPose?
    @ObservationIgnored private var recentPoses: [(time: TimeInterval, pose: BoardPose)] = []
    @ObservationIgnored private var estimator = BoardEstimator()
    @ObservationIgnored private var referenceYaw: Float?
    @ObservationIgnored private var lastDetection: TimeInterval = 0
    @ObservationIgnored private var lastAccepted: TimeInterval?
    @ObservationIgnored private var lastGlimpse: TimeInterval?
    @ObservationIgnored private var cornerTaps: [SIMD3<Float>] = []
    /// Corner-tap locks have no grid sightings, so keep them still.
    @ObservationIgnored private var refinesWhileLocked = true

    private let detectionInterval: TimeInterval = 0.1
    private let lockedDetectionInterval: TimeInterval = 0.25
    private let samplesToLock = 6
    private let stabilityWindow: TimeInterval = 2.5
    private let stabilityTolerance: Float = 0.012

    func attach(to view: ARView) {
        arView = view
        overlayAnchor.addChild(overlay.root)
        overlay.root.isEnabled = false
        view.scene.addAnchor(overlayAnchor)

        delegate.tracker = self
        view.session.delegate = delegate
        start()
    }

    func start() {
        guard let session = arView?.session else { return }
        let configuration = ARWorldTrackingConfiguration()
        configuration.planeDetection = [.horizontal]
        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        focus.prepare()
        resetState()
    }

    func reset() {
        resetState()
    }

    func beginCornerTaps() {
        reset()
        phase = .tappingCorners(remaining: 2)
    }

    func capture() {
        guard let frame = arView?.session.currentFrame else { return }
        let board = phase == .locked ? pose : nil
        let table = estimator.observations.last?.planeY
        Task {
            do {
                _ = try await FrameCapture.save(frame: frame, board: board, quarterTurns: quarterTurns, tablePlaneY: table)
                captureCount = FrameCapture.count
                savedCount += 1
                captureNote = board == nil ? "Saved (no board locked)" : "Saved frame \(captureCount)"
            } catch {
                captureNote = "Save failed: \(error.localizedDescription)"
            }
            try? await Task.sleep(for: .seconds(2))
            captureNote = nil
        }
    }

    func clearDrawings() {
        overlay.clearDrawings()
        selected = nil
    }

    private func resetState() {
        pose = nil
        recentPoses.removeAll()
        estimator.reset()
        referenceYaw = nil
        surfaceHeight = nil
        parallax = 0
        refinesWhileLocked = true
        isManualLock = false
        lastAccepted = nil
        lastGlimpse = nil
        sightings = 0
        visibility = .notSeen(seconds: 0)
        cornerTaps.removeAll()
        selected = nil
        lastTapped = nil
        overlay.clearDrawings()
        overlay.setStyle(.preview)
        overlay.root.isEnabled = false
        phase = hasTablePlane ? .findingBoard(progress: 0) : .findingTable
    }

    // MARK: Taps

    func handleTap(at point: CGPoint) {
        guard let arView else { return }
        switch phase {
        case .tappingCorners(let remaining):
            guard let hit = arView.raycast(from: point, allowing: .estimatedPlane, alignment: .horizontal).first else { return }
            cornerTaps.append(hit.worldTransform.translation)
            if remaining > 1 {
                phase = .tappingCorners(remaining: remaining - 1)
            } else if let pose = BoardPose.fromDiagonal(a1: cornerTaps[0], h8: cornerTaps[1]) {
                lock(pose)
                refinesWhileLocked = false
                isManualLock = true
            } else {
                beginCornerTaps()
            }
        case .locked:
            guard let pose, let ray = arView.ray(through: point),
                  let world = Self.intersect(origin: ray.origin, direction: ray.direction, planeY: pose.center.y),
                  let square = overlay.square(at: world)
            else { return }
            tapped(square)
        default:
            break
        }
    }

    private func tapped(_ square: Square) {
        lastTapped = square
        if let from = selected {
            overlay.clearHighlight(from)
            if from != square {
                overlay.addArrow(from: from, to: square)
            }
            selected = nil
        } else {
            selected = square
            overlay.highlight(square, color: .systemYellow)
        }
    }

    // MARK: Session callbacks

    fileprivate func didUpdate(frame: ARFrame) {
        let note = Self.describe(frame.camera.trackingState)
        if note != trackingNote { trackingNote = note }
        updateVisibility(now: frame.timestamp)
        if let pose { focus.aim(at: pose.center, frame: frame) }

        switch phase {
        case .findingTable:
            if hasTablePlane { phase = .findingBoard(progress: 0) }
        case .findingBoard:
            runDetectionIfDue(frame, interval: detectionInterval)
        case .locked where refinesWhileLocked:
            runDetectionIfDue(frame, interval: lockedDetectionInterval)
        default:
            break
        }
    }

    private var hasTablePlane: Bool {
        guard let anchors = arView?.session.currentFrame?.anchors else { return false }
        return anchors.contains { ($0 as? ARPlaneAnchor)?.alignment == .horizontal }
    }

    // MARK: Detection

    private func runDetectionIfDue(_ frame: ARFrame, interval: TimeInterval) {
        guard frame.timestamp - lastDetection >= interval,
              case .normal = frame.camera.trackingState,
              let target = searchTarget(frame)
        else { return }

        guard let luma = LumaPlane(frame.capturedImage) else { return }
        let request = BoardLocator.Request(
            luma: luma,
            intrinsics: frame.camera.intrinsics,
            camera: frame.camera.transform,
            planeY: target.planeY,
            center: target.center,
            predicted: phase == .locked ? predictedCorners(planeY: target.planeY, camera: frame.camera.transform.translation) : nil,
            wantsDebugImage: showsDebug
        )
        let timestamp = frame.timestamp
        let started = locator.locate(request) { [weak self] detection in
            Task { @MainActor in self?.consume(detection, timestamp: timestamp) }
        }
        if started { lastDetection = frame.timestamp }
    }

    /// The locked board's corners pushed along the camera rays down to the
    /// table plane, which is where the top-down search image lives.
    private func predictedCorners(planeY: Float, camera: SIMD3<Float>) -> [SIMD3<Float>]? {
        guard let pose else { return nil }
        let half = pose.side / 2
        let local: [SIMD4<Float>] = [[-half, 0, -half, 1], [half, 0, -half, 1], [half, 0, half, 1], [-half, 0, half, 1]]
        return local.map { corner in
            let world = pose.transform * corner
            let point = SIMD3(world.x, world.y, world.z)
            let drop = point.y - camera.y
            guard abs(drop) > 1e-3 else { return point }
            return camera + (point - camera) * ((planeY - camera.y) / drop)
        }
    }

    /// The table plane under the middle of the screen, and where on it to look.
    private func searchTarget(_ frame: ARFrame) -> (planeY: Float, center: SIMD2<Float>)? {
        if phase == .locked, let pose, let table = estimator.observations.last?.planeY {
            return (table, SIMD2(pose.center.x, pose.center.z))
        }
        let camera = frame.camera.transform
        let origin = camera.translation
        let forward = -SIMD3(camera.columns.2.x, camera.columns.2.y, camera.columns.2.z)
        let planes = frame.anchors.compactMap { $0 as? ARPlaneAnchor }
            .filter { $0.alignment == .horizontal }
            .map(PlaneSnapshot.init)

        let hits = planes.compactMap { plane -> (Float, SIMD3<Float>)? in
            let height = plane.transform.translation.y
            guard height < origin.y - 0.1,
                  let hit = Self.intersect(origin: origin, direction: forward, planeY: height),
                  plane.contains(hit, slack: 0.4)
            else { return nil }
            return (simd_distance(hit, origin), hit)
        }
        guard let hit = hits.min(by: { $0.0 < $1.0 })?.1 else { return nil }
        let center = pose?.center ?? hit
        return (hit.y, SIMD2(center.x, center.z))
    }

    private func consume(_ detection: BoardLocator.Detection?, timestamp: TimeInterval) {
        if let image = detection?.debugImage { debugImage = image }
        lastChecker = detection?.checker ?? 0
        if (detection?.checker ?? 0) >= 40 { lastGlimpse = timestamp }

        switch phase {
        case .findingBoard: consumeWhileSearching(detection, timestamp: timestamp)
        case .locked: consumeWhileLocked(detection, timestamp: timestamp)
        default: break
        }
    }

    private func consumeWhileSearching(_ detection: BoardLocator.Detection?, timestamp: TimeInterval) {
        guard let candidate = detection?.pose, var observation = detection?.observation,
              (0.15...0.8).contains(candidate.side)
        else {
            recentPoses.removeAll { timestamp - $0.time > stabilityWindow }
            updateProgress()
            return
        }

        if let current = pose, simd_distance(current.center, candidate.center) > 0.1 {
            recentPoses.removeAll()
            estimator.reset()
            referenceYaw = nil
        }
        if referenceYaw == nil { referenceYaw = candidate.yaw }
        observation.time = timestamp
        estimator.add(observation)
        lastAccepted = timestamp
        sightings = estimator.observations.count

        pose = fusedPose() ?? candidate
        recentPoses.append((timestamp, candidate))
        recentPoses.removeAll { timestamp - $0.time > stabilityWindow }

        overlay.root.isEnabled = true
        refreshOverlay()
        updateProgress()

        if isStable, let pose {
            lock(pose)
        }
    }

    /// Keeps folding in sightings after locking, so the height estimate
    /// improves as you walk around and tracking drift gets corrected.
    private func consumeWhileLocked(_ detection: BoardLocator.Detection?, timestamp: TimeInterval) {
        guard let current = pose, var observation = detection?.observation else { return }
        let rough = avg(observation.corners(atHeight: current.center.y))
        guard simd_distance(rough, current.center) < 0.06 else { return }

        observation.time = timestamp
        estimator.add(observation)
        lastAccepted = timestamp
        sightings = estimator.observations.count
        guard let fused = fusedPose() else { return }
        pose = current.blended(toward: fused, amount: 0.3)
        refreshOverlay()
    }

    private func fusedPose() -> BoardPose? {
        guard let referenceYaw, let fused = estimator.pose(referenceYaw: referenceYaw) else { return nil }
        if let height = estimator.height(), let table = estimator.observations.last?.planeY {
            surfaceHeight = height - table
        }
        parallax = estimator.parallax
        return fused
    }

    private func updateVisibility(now: TimeInterval) {
        let next: Visibility
        if let lastAccepted, now - lastAccepted < 0.8 {
            next = .seeing
        } else if let lastGlimpse, now - lastGlimpse < 0.8 {
            next = .glimpsing
        } else {
            let since = lastAccepted ?? lastGlimpse
            next = .notSeen(seconds: since.map { Int(now - $0) } ?? 0)
        }
        if next != visibility { visibility = next }
    }

    private var isStable: Bool {
        guard recentPoses.count >= samplesToLock, let pose else { return false }
        return recentPoses.allSatisfy {
            simd_distance($0.pose.center, pose.center) < stabilityTolerance
                && abs($0.pose.side - pose.side) < stabilityTolerance
        }
    }

    private func updateProgress() {
        guard case .findingBoard = phase else { return }
        let consistent = recentPoses.filter { sample in
            guard let pose else { return false }
            return simd_distance(sample.pose.center, pose.center) < stabilityTolerance
        }.count
        phase = .findingBoard(progress: min(Double(consistent) / Double(samplesToLock), 1))
    }

    private func lock(_ pose: BoardPose) {
        self.pose = pose
        if referenceYaw == nil { referenceYaw = pose.yaw }
        overlay.setStyle(.locked)
        overlay.root.isEnabled = true
        refreshOverlay()
        phase = .locked
        lockCount += 1
    }

    private func refreshOverlay() {
        guard let pose else { return }
        overlay.apply(pose: pose, quarterTurns: quarterTurns)
    }

    // MARK: Geometry

    struct PlaneSnapshot: Sendable {
        let transform: simd_float4x4
        let center: SIMD3<Float>
        let width: Float
        let depth: Float

        init(_ anchor: ARPlaneAnchor) {
            transform = anchor.transform
            center = anchor.center
            width = anchor.planeExtent.width
            depth = anchor.planeExtent.height
        }

        /// Whether a world point lands on (or near) this plane's extent.
        func contains(_ world: SIMD3<Float>, slack: Float) -> Bool {
            let local = (transform.inverse * SIMD4(world, 1))
            return abs(local.x - center.x) <= width / 2 + slack
                && abs(local.z - center.z) <= depth / 2 + slack
        }
    }

    static func intersect(origin: SIMD3<Float>, direction: SIMD3<Float>, planeY: Float) -> SIMD3<Float>? {
        guard abs(direction.y) > 1e-5 else { return nil }
        let t = (planeY - origin.y) / direction.y
        guard t > 0 else { return nil }
        return origin + direction * t
    }

    private static func describe(_ state: ARCamera.TrackingState) -> String? {
        switch state {
        case .normal: nil
        case .notAvailable: "Tracking unavailable"
        case .limited(.initializing): "Warming up, move the phone slowly"
        case .limited(.excessiveMotion): "Slow down"
        case .limited(.insufficientFeatures): "Need more light or texture"
        case .limited(.relocalizing): "Relocalizing"
        case .limited: "Tracking limited"
        }
    }
}

/// ARKit delivers callbacks on the main queue by default, so we hop straight
/// back into the main actor.
@MainActor
private final class SessionDelegate: NSObject, ARSessionDelegate {
    weak var tracker: BoardTracker?

    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        MainActor.assumeIsolated { tracker?.didUpdate(frame: frame) }
    }

}

private func avg(_ points: [SIMD3<Float>]) -> SIMD3<Float> {
    points.reduce(.zero, +) / Float(max(points.count, 1))
}

extension simd_float4x4 {
    var translation: SIMD3<Float> { SIMD3(columns.3.x, columns.3.y, columns.3.z) }
}
