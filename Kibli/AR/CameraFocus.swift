import ARKit
import AVFoundation
import simd

/// Points the camera's autofocus and exposure at the board. Left alone, the
/// camera tends to settle on whatever is high contrast near the edges, like
/// a sleeve or a laptop, and the board goes soft.
@MainActor
final class CameraFocus {
    private var device: AVCaptureDevice? { ARWorldTrackingConfiguration.configurableCaptureDeviceForPrimaryCamera }
    private var lastPoint: CGPoint?
    private var lastChange: TimeInterval = 0

    /// Call after the session starts running.
    func prepare() {
        lastPoint = nil
        configure { device in
            if device.isAutoFocusRangeRestrictionSupported {
                device.autoFocusRangeRestriction = .near
            }
            device.isSubjectAreaChangeMonitoringEnabled = true
        }
        aim(at: CGPoint(x: 0.5, y: 0.5), now: 0, force: true)
    }

    /// Aims at a world point if it is in view. Throttled, since every change
    /// restarts the focus hunt.
    func aim(at world: SIMD3<Float>, frame: ARFrame) {
        let size = frame.camera.imageResolution
        let projected = frame.camera.projectPoint(world, orientation: .landscapeRight, viewportSize: size)
        let point = CGPoint(x: projected.x / size.width, y: projected.y / size.height)
        guard (0.05...0.95).contains(point.x), (0.05...0.95).contains(point.y) else { return }
        aim(at: point, now: frame.timestamp, force: false)
    }

    private func aim(at point: CGPoint, now: TimeInterval, force: Bool) {
        if !force, let lastPoint {
            let moved = hypot(point.x - lastPoint.x, point.y - lastPoint.y)
            guard moved > 0.06, now - lastChange > 0.75 else { return }
        }
        lastPoint = point
        lastChange = now
        configure { device in
            if device.isFocusPointOfInterestSupported, device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusPointOfInterest = point
                device.focusMode = .continuousAutoFocus
            }
            if device.isExposurePointOfInterestSupported, device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposurePointOfInterest = point
                device.exposureMode = .continuousAutoExposure
            }
        }
    }

    private func configure(_ change: (AVCaptureDevice) -> Void) {
        guard let device else { return }
        do {
            try device.lockForConfiguration()
            change(device)
            device.unlockForConfiguration()
        } catch {}
    }
}
