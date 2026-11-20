import CoreVideo
import simd

/// A private copy of a camera frame's luma plane. Copying costs well under a
/// millisecond and hands the frame straight back to ARKit, which only has a
/// handful of buffers and stalls the camera if the app holds onto them while
/// it searches.
struct LumaPlane: Sendable {
    let width: Int
    let height: Int
    let bytes: [UInt8]

    init(width: Int, height: Int, bytes: [UInt8]) {
        self.width = width
        self.height = height
        self.bytes = bytes
    }

    init?(_ pixelBuffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard CVPixelBufferGetPlaneCount(pixelBuffer) >= 1,
              let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)
        else { return nil }
        let w = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let h = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let source = base.assumingMemoryBound(to: UInt8.self)
        var bytes = [UInt8](repeating: 0, count: w * h)
        bytes.withUnsafeMutableBufferPointer { out in
            for row in 0..<h {
                (out.baseAddress! + row * w).update(from: source + row * stride, count: w)
            }
        }
        width = w
        height = h
        self.bytes = bytes
    }
}

/// A grayscale view of the table seen from straight above. Pixel (col, row)
/// sits at world (x, z) = origin + (col, row) * metersPerPixel on the plane
/// y = planeY. Because ARKit already knows the table plane, perspective is
/// gone: a board shows up as a square grid that only differs by rotation,
/// scale and offset.
struct TopDownImage: Sendable {
    let size: Int
    let metersPerPixel: Float
    let origin: SIMD2<Float>
    let planeY: Float
    var pixels: [Float]
    var valid: [Bool]

    func world(_ pixel: SIMD2<Float>) -> SIMD3<Float> {
        let xz = origin + pixel * metersPerPixel
        return SIMD3(xz.x, planeY, xz.y)
    }

    func pixel(_ world: SIMD3<Float>) -> SIMD2<Float> {
        (SIMD2(world.x, world.z) - origin) / metersPerPixel
    }

    /// Mean brightness of valid pixels in a disc, or nil if none are valid.
    func mean(around center: SIMD2<Float>, radius: Float) -> Float? {
        let r = Int(radius.rounded(.up))
        let cx = Int(center.x.rounded()), cy = Int(center.y.rounded())
        var sum: Float = 0
        var count = 0
        for y in max(cy - r, 0)...min(cy + r, size - 1) {
            for x in max(cx - r, 0)...min(cx + r, size - 1) {
                let dx = Float(x - cx), dy = Float(y - cy)
                guard dx * dx + dy * dy <= radius * radius, valid[y * size + x] else { continue }
                sum += pixels[y * size + x]
                count += 1
            }
        }
        return count > 0 ? sum / Float(count) : nil
    }

    /// Projects the camera's luma plane onto the table.
    static func rectify(
        luma plane: LumaPlane,
        intrinsics: simd_float3x3,
        cameraTransform: simd_float4x4,
        planeY: Float,
        center: SIMD2<Float>,
        size: Int,
        metersPerPixel: Float
    ) -> TopDownImage? {
        let width = plane.width, height = plane.height, stride = plane.width

        let fx = intrinsics.columns.0.x, fy = intrinsics.columns.1.y
        let cx = intrinsics.columns.2.x, cy = intrinsics.columns.2.y

        let origin = center - Float(size) / 2 * metersPerPixel
        let toCamera = cameraTransform.inverse
        let start = toCamera * SIMD4(origin.x, planeY, origin.y, 1)
        let stepX = toCamera * SIMD4(metersPerPixel, 0, 0, 0)
        let stepZ = toCamera * SIMD4(0, 0, metersPerPixel, 0)

        var pixels = [Float](repeating: 0, count: size * size)
        var valid = [Bool](repeating: false, count: size * size)
        let maxX = Float(width - 2), maxY = Float(height - 2)

        plane.bytes.withUnsafeBufferPointer { luma in
        pixels.withUnsafeMutableBufferPointer { out in
            valid.withUnsafeMutableBufferPointer { ok in
                for row in 0..<size {
                    var p = start + stepZ * Float(row)
                    for col in 0..<size {
                        defer { p += stepX }
                        let depth = -p.z
                        guard depth > 0.05 else { continue }
                        let u = cx + fx * p.x / depth
                        let v = cy - fy * p.y / depth
                        guard u >= 0, v >= 0, u < maxX, v < maxY else { continue }
                        let x0 = Int(u), y0 = Int(v)
                        let ax = u - Float(x0), ay = v - Float(y0)
                        let i = y0 * stride + x0
                        let top = Float(luma[i]) * (1 - ax) + Float(luma[i + 1]) * ax
                        let bottom = Float(luma[i + stride]) * (1 - ax) + Float(luma[i + stride + 1]) * ax
                        out[row * size + col] = top * (1 - ay) + bottom * ay
                        ok[row * size + col] = true
                    }
                }
            }
        }
        }

        return TopDownImage(
            size: size,
            metersPerPixel: metersPerPixel,
            origin: origin,
            planeY: planeY,
            pixels: pixels,
            valid: valid
        )
    }
}
