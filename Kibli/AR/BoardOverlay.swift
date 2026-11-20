import RealityKit
import UIKit

/// The virtual board drawn on top of the real one. It is built as a unit
/// square (side 1) centered on its origin and scaled to the real board's size,
/// using the axes described on `BoardPose`.
@MainActor
final class BoardOverlay {
    let root = Entity()

    private let content = Entity()
    private var gridMaterial = UnlitMaterial(color: .cyan)
    private var gridLines: [ModelEntity] = []
    private var highlights: [Square: ModelEntity] = [:]
    private var arrows: [Entity] = []

    enum Style {
        case preview
        case locked
    }

    init() {
        root.addChild(content)
        buildGrid()
        buildLabels()
        setStyle(.preview)
    }

    func apply(pose: BoardPose, quarterTurns: Int) {
        let playingSide = pose.side
        let yaw = pose.yaw + Float(quarterTurns) * .pi / 2
        root.transform = Transform(
            scale: SIMD3(repeating: playingSide),
            rotation: simd_quatf(angle: yaw, axis: [0, 1, 0]),
            translation: pose.center
        )
    }

    func setStyle(_ style: Style) {
        let color: UIColor = style == .locked
            ? UIColor.systemCyan.withAlphaComponent(0.9)
            : UIColor.systemOrange.withAlphaComponent(0.7)
        var material = UnlitMaterial(color: color)
        material.blending = .transparent(opacity: .init(floatLiteral: Float(color.cgColor.alpha)))
        gridMaterial = material
        for line in gridLines {
            line.model?.materials = [material]
        }
    }

    // MARK: Drawing

    /// Maps a world-space point on the table to the square under it.
    func square(at worldPoint: SIMD3<Float>) -> Square? {
        let local = root.convert(position: worldPoint, from: nil)
        let file = Int(floor((local.x + 0.5) * 8))
        let rank = Int(floor((-local.z + 0.5) * 8))
        return Square(file: file, rank: rank)
    }

    func highlight(_ square: Square, color: UIColor) {
        clearHighlight(square)
        let size: Float = 1.0 / 8
        let tile = ModelEntity(
            mesh: .generatePlane(width: size * 0.92, depth: size * 0.92),
            materials: [Self.translucent(color, opacity: 0.55)]
        )
        tile.position = Self.center(of: square) + [0, 0.002, 0]
        content.addChild(tile)
        highlights[square] = tile
    }

    func clearHighlight(_ square: Square) {
        highlights.removeValue(forKey: square)?.removeFromParent()
    }

    func addArrow(from: Square, to: Square, color: UIColor = .systemGreen) {
        let start = Self.center(of: from)
        let end = Self.center(of: to)
        let delta = end - start
        let length = simd_length(delta)
        guard length > 0 else { return }

        let material = Self.translucent(color, opacity: 0.85)
        let headLength: Float = 0.045
        let shaftLength = max(length - headLength, 0.001)

        let arrow = Entity()
        let shaft = ModelEntity(mesh: .generateBox(width: 0.018, height: 0.004, depth: shaftLength), materials: [material])
        shaft.position = [0, 0, -shaftLength / 2]
        let head = ModelEntity(mesh: .generateCone(height: headLength, radius: 0.03), materials: [material])
        head.orientation = simd_quatf(angle: -.pi / 2, axis: [1, 0, 0])
        head.position = [0, 0, -shaftLength - headLength / 2]
        head.scale = [1, 1, 0.15]
        arrow.addChild(shaft)
        arrow.addChild(head)

        arrow.position = start + [0, 0.01, 0]
        arrow.orientation = simd_quatf(angle: atan2(-delta.x, -delta.z), axis: [0, 1, 0])
        content.addChild(arrow)
        arrows.append(arrow)
    }

    func clearDrawings() {
        highlights.values.forEach { $0.removeFromParent() }
        highlights.removeAll()
        arrows.forEach { $0.removeFromParent() }
        arrows.removeAll()
    }

    // MARK: Building

    static func center(of square: Square) -> SIMD3<Float> {
        let size: Float = 1.0 / 8
        return [
            -0.5 + (Float(square.file) + 0.5) * size,
            0,
            0.5 - (Float(square.rank) + 0.5) * size,
        ]
    }

    private func buildGrid() {
        let thickness: Float = 0.006
        for i in 0...8 {
            let offset = -0.5 + Float(i) / 8
            let along = ModelEntity(mesh: .generatePlane(width: 1 + thickness, depth: thickness), materials: [gridMaterial])
            along.position = [0, 0.001, offset]
            let across = ModelEntity(mesh: .generatePlane(width: thickness, depth: 1 + thickness), materials: [gridMaterial])
            across.position = [offset, 0.001, 0]
            content.addChild(along)
            content.addChild(across)
            gridLines.append(contentsOf: [along, across])
        }
    }

    private func buildLabels() {
        let material = UnlitMaterial(color: .white)
        let files = "abcdefgh"
        for (index, letter) in files.enumerated() {
            let label = Self.textEntity(String(letter), material: material)
            label.position = [-0.5 + (Float(index) + 0.5) / 8, 0.002, 0.56]
            content.addChild(label)
        }
        for rank in 0..<8 {
            let label = Self.textEntity("\(rank + 1)", material: material)
            label.position = [-0.56, 0.002, 0.5 - (Float(rank) + 0.5) / 8]
            content.addChild(label)
        }
    }

    private static func textEntity(_ string: String, material: UnlitMaterial) -> Entity {
        let mesh = MeshResource.generateText(
            string,
            extrusionDepth: 0.001,
            font: .systemFont(ofSize: 0.05, weight: .semibold),
            alignment: .center
        )
        let model = ModelEntity(mesh: mesh, materials: [material])
        let bounds = mesh.bounds
        model.position = -bounds.center
        let holder = Entity()
        holder.orientation = simd_quatf(angle: -.pi / 2, axis: [1, 0, 0])
        holder.addChild(model)
        return holder
    }

    private static func translucent(_ color: UIColor, opacity: Float) -> UnlitMaterial {
        var material = UnlitMaterial(color: color)
        material.blending = .transparent(opacity: .init(floatLiteral: opacity))
        return material
    }
}
