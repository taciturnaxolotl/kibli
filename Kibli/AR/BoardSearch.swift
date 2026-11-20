import CoreVideo
import simd

/// Builds the top-down view and runs the grid finder, either searching
/// fresh or following a board that is already known.
enum BoardSearch {
    static let fineSize = 500
    static let fineMetersPerPixel: Float = 0.002

    static func locate(
        luma: LumaPlane,
        intrinsics: simd_float3x3,
        camera: simd_float4x4,
        planeY: Float,
        center: SIMD2<Float>,
        finder: GridFinder
    ) -> (image: TopDownImage, grid: GridFinder.Result?)? {
        guard let image = TopDownImage.rectify(
            luma: luma, intrinsics: intrinsics, cameraTransform: camera, planeY: planeY,
            center: center, size: fineSize, metersPerPixel: fineMetersPerPixel
        ) else { return nil }
        let grid = finder.find(in: image)

        // A board near the edge of the window gets cut off and scores badly.
        // Look again, centered on whatever was found.
        if let grid {
            let margin = Float(fineSize) * 0.08
            let clipped = grid.corners.contains {
                $0.x < margin || $0.y < margin || $0.x > Float(fineSize) - margin || $0.y > Float(fineSize) - margin
            }
            if clipped {
                let middle = image.world(grid.corners.reduce(.zero, +) / 4)
                if let second = TopDownImage.rectify(
                    luma: luma, intrinsics: intrinsics, cameraTransform: camera, planeY: planeY,
                    center: SIMD2(middle.x, middle.z), size: fineSize, metersPerPixel: fineMetersPerPixel
                ), let regrid = finder.find(in: second), regrid.checker > grid.checker {
                    return (second, regrid)
                }
            }
        }
        return (image, grid)
    }

    /// Follows a known board by refining predicted corners, given on the
    /// table plane in world space.
    static func track(
        luma: LumaPlane,
        intrinsics: simd_float3x3,
        camera: simd_float4x4,
        planeY: Float,
        predicted: [SIMD3<Float>],
        finder: GridFinder
    ) -> (image: TopDownImage, grid: GridFinder.Result?)? {
        let middle = predicted.reduce(.zero, +) / 4
        guard let image = TopDownImage.rectify(
            luma: luma, intrinsics: intrinsics, cameraTransform: camera, planeY: planeY,
            center: SIMD2(middle.x, middle.z), size: fineSize, metersPerPixel: fineMetersPerPixel
        ) else { return nil }
        return (image, finder.track(in: image, predicted: predicted.map(image.pixel)))
    }
}
