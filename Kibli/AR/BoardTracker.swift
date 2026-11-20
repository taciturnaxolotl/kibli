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

    /// What's standing between the app and a lock, most pressing first.
    enum SearchHint: Equatable {
        case mapTable
        case aimAtTable
        case tooFar
        case tooFlat
        case partlyOutOfView
        case unclearSquares
        case holdSteady
    }

    private(set) var searchHint: SearchHint = .mapTable
    /// Sightings currently feeding the fused pose.
    private(set) var sightings = 0
    /// Bumped on every lock, so the view can play a haptic.
    private(set) var lockCount = 0
    /// Bumped on every saved capture.
    private(set) var savedCount = 0

    /// 0 to 1, how much viewpoint variety backs the surface height.
    var calibration: Double { min(Double(parallax) / 0.1, 1) }

    private(set) var captureCount = FrameCapture.count
    private(set) var captureNote: String?

    var quarterTurns = 0 { didSet { refreshOverlay() } }
    var showsDebug = false

    // MARK: Game state

    enum Watch: Equatable {
        /// Board not locked yet.
        case idle
        /// Waiting for a still view of the starting position.
        case findingStart
        case watching
        case handInView
        case unclear
    }

    private(set) var game = Game()
    private(set) var watch: Watch = .idle
    /// How bare each square looked at the last still moment, for the debug
    /// panel.
    private(set) var lastChanges: [Float]?
    /// How well the tracked position explains the board, around 30 when
    /// everything matches.
    private(set) var fit: Float?
    /// Bumped whenever a move is recognized.
    private(set) var moveCount = 0
    /// Bumped whenever the locked board jumps to follow the real one.
    private(set) var relockCount = 0
    private(set) var hasDepth = false
    /// LiDAR occupancy per square at the last still moment, for the debug panel.
    private(set) var lastDepthOccupancy: [Float?]?
    var watchesMoves = true

    @ObservationIgnored private weak var arView: ARView?
    @ObservationIgnored private let overlay = BoardOverlay()
    @ObservationIgnored private let overlayAnchor = AnchorEntity(world: .zero)
    @ObservationIgnored private let locator = BoardLocator()
    @ObservationIgnored private let delegate = SessionDelegate()
    @ObservationIgnored private let focus = CameraFocus()
    @ObservationIgnored private let moveDetector = MoveDetector()
    @ObservationIgnored let recorder = Recorder()
    private(set) var isRecording = false
    private(set) var recordingStarted: Date?
    @ObservationIgnored private var lastMoveCheck: TimeInterval = 0
    @ObservationIgnored private var needsOrientation = true
    /// Locked-mode refinements in a row that couldn't find the board where
    /// it was expected. After a few, search the whole view again.
    @ObservationIgnored private var trackingMisses = 0
    /// Camera distance and viewing angle (degrees above the table) for the
    /// last search, used to explain why it failed.
    @ObservationIgnored private var lastSearchGeometry: (distance: Float, elevation: Float)?
    /// Recent search outcomes, so a single bad frame doesn't flip the hint.
    @ObservationIgnored private var recentHints: [SearchHint] = []
    /// Fresh sightings that disagree with the locked pose. If several agree
    /// with each other, the board (or ARKit's map) has moved and we follow.
    @ObservationIgnored private var relockCandidates: [(time: TimeInterval, pose: BoardPose, observation: BoardObservation)] = []

    @ObservationIgnored private var pose: BoardPose?
    @ObservationIgnored private var recentPoses: [(time: TimeInterval, pose: BoardPose, observation: BoardObservation)] = []
    @ObservationIgnored private var estimator = BoardEstimator()
    @ObservationIgnored private var referenceYaw: Float?
    @ObservationIgnored private var lastDetection: TimeInterval = 0
    @ObservationIgnored private var lastAccepted: TimeInterval?
    @ObservationIgnored private var lastGlimpse: TimeInterval?

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
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            configuration.frameSemantics.insert(.smoothedSceneDepth)
        }
        hasDepth = ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth)
        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        focus.prepare()
        resetState()
    }

    func reset() {
        recorder.log("user", ["action": "reset"])
        resetState()
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
                let total = captureCount == 1 ? "1 capture" : "\(captureCount) captures"
                captureNote = board == nil ? "Saved without a board, \(total)" : "Saved, \(total)"
            } catch {
                captureNote = "Save failed: \(error.localizedDescription)"
            }
            try? await Task.sleep(for: .seconds(2))
            captureNote = nil
        }
    }

    func toggleRecording() {
        if recorder.isRecording {
            recorder.stop()
        } else {
            recorder.start()
            recorder.log("state", [
                "phase": "\(phase)", "quarterTurns": quarterTurns,
                "pose": pose.map { ["center": $0.center.array, "yaw": $0.yaw, "side": $0.side] } ?? NSNull(),
                "moves": game.records.map(\.san),
            ])
        }
        isRecording = recorder.isRecording
        recordingStarted = recorder.startedAt
    }

    func newGame() {
        recorder.log("user", ["action": "newGame"])
        game = Game()
        needsOrientation = true
        lastChanges = nil
        moveDetector.reset()
        overlay.showLastMove([])
        watch = phase == .locked ? .findingStart : .idle
    }

    func undoMove() {
        recorder.log("user", ["action": "undo"])
        game.undo()
        moveDetector.reset()
        overlay.showLastMove(game.lastMove?.touched.prefix(2).map { $0 } ?? [])
    }

    /// Swaps which end is white's.
    func flip() {
        recorder.log("user", ["action": "flip"])
        quarterTurns = (quarterTurns + 2) % 4
        needsOrientation = false
        moveDetector.reset()
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
        lastAccepted = nil
        lastGlimpse = nil
        moveDetector.reset()
        watch = .idle
        trackingMisses = 0
        relockCandidates.removeAll()
        sightings = 0
        visibility = .notSeen(seconds: 0)
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
        recorder.frame(frame, luma: { LumaPlane(frame.capturedImage) }, depth: { DepthPlane(frame) })

        switch phase {
        case .findingTable:
            searchHint = .mapTable
            if hasTablePlane { phase = .findingBoard(progress: 0) }
        case .findingBoard:
            runDetectionIfDue(frame, interval: detectionInterval)
        case .locked:
            runDetectionIfDue(frame, interval: lockedDetectionInterval)
            if watchesMoves { watchForMoves(frame) }
        }
    }

    private var hasTablePlane: Bool {
        guard let anchors = arView?.session.currentFrame?.anchors else { return false }
        return anchors.contains { ($0 as? ARPlaneAnchor)?.alignment == .horizontal }
    }

    // MARK: Detection

    /// The board as the user sees it: the tracked pose turned so white is at
    /// the bottom.
    private var effectivePose: BoardPose? {
        pose.map { BoardPose(center: $0.center, yaw: $0.yaw + Float(quarterTurns) * .pi / 2, side: $0.side) }
    }

    private func watchForMoves(_ frame: ARFrame) {
        guard frame.timestamp - lastMoveCheck >= 0.2,
              case .normal = frame.camera.trackingState,
              let board = effectivePose,
              let luma = LumaPlane(frame.capturedImage)
        else { return }

        let request = MoveDetector.Frame(
            luma: luma, intrinsics: frame.camera.intrinsics, camera: frame.camera.transform,
            board: board.transform, side: board.side, depth: DepthPlane(frame)
        )
        let started = moveDetector.process(
            request, position: game.position, findOrientation: needsOrientation && game.records.isEmpty
        ) { [weak self] event, depth in
            Task { @MainActor in
                if let depth { self?.lastDepthOccupancy = depth }
                self?.handle(event)
            }
        }
        if started { lastMoveCheck = frame.timestamp }
    }

    private func handle(_ event: MoveDetector.Event) {
        guard phase == .locked else { return }
        if recorder.isRecording {
            switch event {
            case .busy: recorder.log("moves", ["event": "busy"])
            case .settled(let fit): recorder.log("moves", ["event": "settled", "fit": fit])
            case .oriented(let turns): recorder.log("moves", ["event": "oriented", "turns": turns])
            case .unclear(let bareness): recorder.log("moves", ["event": "unclear", "bareness": bareness])
            case .moved(let moves, let bareness):
                var position = game.position
                let san = moves.map { move -> String in
                    defer { position = position.playing(move) }
                    return position.san(move)
                }
                recorder.log("moves", ["event": "moved", "san": san, "bareness": bareness])
            }
        }
        let waiting = needsOrientation && game.records.isEmpty
        switch event {
        case .busy:
            setWatch(.handInView)
        case .settled(let fit):
            self.fit = fit
            setWatch(waiting ? .findingStart : .watching)
        case .oriented(let turns):
            needsOrientation = false
            if turns != 0 {
                quarterTurns = (quarterTurns + turns) % 4
                moveDetector.reset()
            }
            setWatch(.watching)
        case .unclear(let bareness):
            lastChanges = bareness
            setWatch(.unclear)
        case .moved(let moves, let bareness):
            lastChanges = bareness
            needsOrientation = false
            for move in moves { game.play(move) }
            moveCount += 1
            if let last = moves.last { overlay.showLastMove([last.from, last.to]) }
            setWatch(.watching)
        }
    }

    private func setWatch(_ value: Watch) {
        if watch != value { watch = value }
    }

    private func runDetectionIfDue(_ frame: ARFrame, interval: TimeInterval) {
        guard frame.timestamp - lastDetection >= interval,
              case .normal = frame.camera.trackingState
        else { return }
        guard let target = searchTarget(frame) else {
            if phase != .locked { setHint(hasTablePlane ? .aimAtTable : .mapTable, immediate: true) }
            return
        }
        let eye = frame.camera.transform.translation
        let spot = SIMD3(target.center.x, target.planeY, target.center.y)
        let distance = simd_distance(eye, spot)
        lastSearchGeometry = (distance, asin(min(max((eye.y - target.planeY) / max(distance, 0.01), -1), 1)) * 180 / .pi)

        guard let luma = LumaPlane(frame.capturedImage) else { return }
        let request = BoardLocator.Request(
            luma: luma,
            intrinsics: frame.camera.intrinsics,
            camera: frame.camera.transform,
            planeY: target.planeY,
            center: target.center,
            predicted: phase == .locked && trackingMisses < 4
                ? predictedCorners(planeY: target.planeY, camera: frame.camera.transform.translation) : nil,
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
        if recorder.isRecording {
            var fields: [String: Any] = [
                "phase": "\(phase)",
                "found": detection?.observation != nil,
                "tracked": detection?.tracked ?? false,
                "checker": detection?.checker ?? 0,
                "edge": detection?.edge ?? 0,
                "trackingMisses": trackingMisses,
            ]
            if let observation = detection?.observation {
                fields["corners"] = observation.corners.map(\.array)
                fields["planeY"] = observation.planeY
            }
            if let candidate = detection?.pose {
                fields["candidate"] = ["center": candidate.center.array, "yaw": candidate.yaw, "side": candidate.side]
            }
            recorder.log("detection", fields, time: timestamp)
        }
        defer {
            if recorder.isRecording, let pose {
                recorder.log("pose", [
                    "center": pose.center.array, "yaw": pose.yaw, "side": pose.side,
                    "surface": surfaceHeight ?? NSNull(), "parallax": parallax, "sightings": sightings,
                    "quarterTurns": quarterTurns,
                ], time: timestamp)
            }
        }
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
        setHint(hint(for: detection), immediate: false)
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
        recentPoses.append((timestamp, candidate, observation))
        recentPoses.removeAll { timestamp - $0.time > stabilityWindow }

        overlay.root.isEnabled = true
        refreshOverlay()
        updateProgress()

        if let agreeing = stableRun() {
            // Lock from only the sightings that agreed, so an earlier frame
            // where the grid slid a square doesn't drag the result.
            estimator.reset()
            for sample in agreeing { estimator.add(sample.observation) }
            if let fused = fusedPose() {
                pose = fused
                lock(fused)
            }
        }
    }

    /// Keeps folding in sightings after locking, so the height estimate
    /// improves as you walk around and tracking drift gets corrected.
    private func consumeWhileLocked(_ detection: BoardLocator.Detection?, timestamp: TimeInterval) {
        guard let current = pose else { return }
        guard let detection, var observation = detection.observation, let candidate = detection.pose else {
            if detection?.tracked != false { trackingMisses += 1 }
            return
        }
        observation.time = timestamp
        let rough = avg(observation.corners(atHeight: current.center.y))

        if simd_distance(rough, current.center) < 0.03 {
            trackingMisses = 0
            relockCandidates.removeAll()
            estimator.add(observation)
            lastAccepted = timestamp
            sightings = estimator.observations.count
            guard let fused = fusedPose() else { return }
            pose = current.blended(toward: fused, amount: 0.3)
            refreshOverlay()
            return
        }

        // A fresh search found the board somewhere else. Follow it once a few
        // sightings in a row agree, keeping the game and orientation.
        if detection.tracked { trackingMisses += 1; return }
        relockCandidates.removeAll { timestamp - $0.time > 3 }
        if let last = relockCandidates.last, simd_distance(last.pose.center, candidate.center) > 0.02 {
            relockCandidates.removeAll()
        }
        relockCandidates.append((timestamp, candidate, observation))
        guard relockCandidates.count >= 3 else { return }

        estimator.reset()
        for sighting in relockCandidates { estimator.add(sighting.observation) }
        referenceYaw = current.yaw
        relockCandidates.removeAll()
        trackingMisses = 0
        lastAccepted = timestamp
        if let fused = fusedPose() {
            pose = fused
            refreshOverlay()
            moveDetector.reset()
            relockCount += 1
            recorder.log("relock", ["center": fused.center.array, "yaw": fused.yaw])
        }
    }

    private func fusedPose() -> BoardPose? {
        guard let referenceYaw, let fused = estimator.pose(referenceYaw: referenceYaw) else { return nil }
        if let height = estimator.height(), let table = estimator.observations.last?.planeY {
            surfaceHeight = height - table
        }
        parallax = estimator.parallax
        return fused
    }

    /// Explains a search result in terms of something the user can change.
    private func hint(for detection: BoardLocator.Detection?) -> SearchHint {
        if detection?.pose != nil { return .holdSteady }
        let checker = detection?.checker ?? 0
        let corners = detection?.cornersInView ?? 0
        if checker >= 30, corners < 4 { return .partlyOutOfView }
        if let geometry = lastSearchGeometry {
            if geometry.elevation < 25 { return .tooFlat }
            if geometry.distance > 1.4 { return .tooFar }
        }
        if checker >= 30 { return .unclearSquares }
        return corners < 4 && checker > 0 ? .partlyOutOfView : .unclearSquares
    }

    private func setHint(_ hint: SearchHint, immediate: Bool) {
        if immediate {
            recentHints = [hint]
        } else {
            recentHints.append(hint)
            if recentHints.count > 5 { recentHints.removeFirst() }
        }
        // The most common hint over the last half second or so.
        let counts = Dictionary(grouping: recentHints, by: { $0 }).mapValues(\.count)
        let winner = counts.max { $0.value < $1.value }?.key ?? hint
        if winner != searchHint { searchHint = winner }
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

    /// The latest sightings, if enough of them in a row agree with each
    /// other. Compared on the table plane, before any height correction,
    /// since that is what each sighting measured directly.
    private func stableRun() -> [(time: TimeInterval, pose: BoardPose, observation: BoardObservation)]? {
        let run = consistentRun()
        return run.count >= samplesToLock ? run : nil
    }

    private func consistentRun() -> [(time: TimeInterval, pose: BoardPose, observation: BoardObservation)] {
        guard let newest = recentPoses.last else { return [] }
        var run = [newest]
        for sample in recentPoses.dropLast().reversed() {
            var offset = sample.pose.center - newest.pose.center
            offset.y = 0
            guard simd_length(offset) < stabilityTolerance,
                  abs(sample.pose.side - newest.pose.side) < stabilityTolerance
            else { break }
            run.append(sample)
        }
        return run
    }

    private func updateProgress() {
        guard case .findingBoard = phase else { return }
        phase = .findingBoard(progress: min(Double(consistentRun().count) / Double(samplesToLock), 1))
    }

    private func lock(_ pose: BoardPose) {
        self.pose = pose
        if referenceYaw == nil { referenceYaw = pose.yaw }
        overlay.setStyle(.locked)
        overlay.root.isEnabled = true
        refreshOverlay()
        phase = .locked
        lockCount += 1
        recorder.log("lock", ["center": pose.center.array, "yaw": pose.yaw, "side": pose.side])
        moveDetector.reset()
        watch = needsOrientation && game.records.isEmpty ? .findingStart : .watching
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
