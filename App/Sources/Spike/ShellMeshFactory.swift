import CampusGeo
import CampusModel
import RealityKit
import UIKit

/// Builds Tier 0 building shells: a floor slab plus a low perimeter wall per level,
/// one entity per building level (the draw-call shape Phase 2 will have). For
/// Spike S2 it can add filler "rooms" to approximate Tier 2 geometry.
struct ShellMeshFactory {
    enum Complexity: String, CaseIterable, Identifiable {
        case shells, tier2, stress
        var id: Self { self }

        /// Filler boxes per 100 m² of floor.
        var fillerDensity: Double {
            switch self {
            case .shells: 0
            case .tier2: 0.8
            case .stress: 3
            }
        }
    }

    let plane: MapPlane
    var slabThickness = 0.3
    var wallHeight = 1.2

    // Flat, unlit colors with baked-in "sun" shading keep the look stylized and
    // independent of lighting setup. Material slots: 0 slab, 1–4 wall shades, 5 filler top.
    private static let lightDirection = SIMD2<Double>(-0.6, 0.8)
    private static let wallShades = [0.42, 0.52, 0.62, 0.72]

    func makeEntities(for campus: CampusBundle, complexity: Complexity, highlight: String) throws -> (entities: [Entity], triangles: Int) {
        var entities: [Entity] = []
        var triangles = 0
        var random = SplitMix64(seed: 0x5EED)
        for building in campus.buildings {
            let materials = Self.materials(highlighted: building.code == highlight)
            let levels = building.parts.map(\.levels).max() ?? 1
            for level in 0..<levels {
                var mesh = MeshBuilder()
                for part in building.parts where level < part.levels {
                    let ring = counterClockwiseRing(part.outline)
                    let base = building.groundElevation + Double(level) * building.levelHeight
                    addSlab(ring, base: base, to: &mesh)
                    addWalls(ring, bottom: base, height: wallHeight, to: &mesh)
                    addFiller(in: ring, base: base + slabThickness, density: complexity.fillerDensity, random: &random, to: &mesh)
                }
                guard mesh.triangleCount > 0 else { continue }
                let entity = ModelEntity(mesh: try MeshResource.generate(from: [mesh.descriptor(name: "\(building.code)-L\(level)")]), materials: materials)
                entity.name = "\(building.code)-L\(level)"
                entities.append(entity)
                triangles += mesh.triangleCount
            }
        }
        return (entities, triangles)
    }

    private static func materials(highlighted: Bool) -> [any Material] {
        let slab = highlighted ? UIColor(red: 1, green: 0.62, blue: 0.2, alpha: 1) : UIColor(white: 0.86, alpha: 1)
        let tint = highlighted ? UIColor(red: 0.9, green: 0.45, blue: 0.1, alpha: 1) : UIColor(red: 0.45, green: 0.55, blue: 0.75, alpha: 1)
        var colors = [slab]
        colors += wallShades.map { shade in tint.withBrightness(shade) }
        colors.append(UIColor(white: 0.64, alpha: 1))
        return colors.map { UnlitMaterial(color: $0) }
    }

    private func counterClockwiseRing(_ outline: [GeoCoordinate]) -> [SIMD2<Double>] {
        var ring = outline.map(plane.planar)
        if ring.count > 1, ring.first == ring.last { ring.removeLast() }
        return Triangulation.signedArea(ring) < 0 ? ring.reversed() : ring
    }

    private func addSlab(_ ring: [SIMD2<Double>], base: Double, to mesh: inout MeshBuilder) {
        let top = base + slabThickness
        let indices = Triangulation.triangulate(ring)
        for i in stride(from: 0, to: indices.count, by: 3) {
            mesh.addTriangle(
                SIMD3(ring[indices[i]], top), SIMD3(ring[indices[i + 1]], top), SIMD3(ring[indices[i + 2]], top),
                normal: SIMD3(0, 0, 1), material: 0
            )
        }
    }

    /// Outward-facing walls along a counter-clockwise ring.
    private func addWalls(_ ring: [SIMD2<Double>], bottom: Double, height: Double, to mesh: inout MeshBuilder) {
        for i in ring.indices {
            let a = ring[i], b = ring[(i + 1) % ring.count]
            let edge = b - a
            let edgeLength = (edge * edge).sum().squareRoot()
            guard edgeLength > 1e-6 else { continue }
            let outward = SIMD2(edge.y, -edge.x) / edgeLength
            let light = max(0, (outward * Self.lightDirection).sum())
            let shade = UInt32(1 + min(3, Int(light * 4)))
            mesh.addQuad(
                SIMD3(a, bottom), SIMD3(b, bottom), SIMD3(b, bottom + height), SIMD3(a, bottom + height),
                normal: SIMD3(outward, 0), material: shade
            )
        }
    }

    /// Box "rooms" scattered inside the outline, a stand-in for Tier 2 detail.
    private func addFiller(in ring: [SIMD2<Double>], base: Double, density: Double, random: inout SplitMix64, to mesh: inout MeshBuilder) {
        guard density > 0 else { return }
        let area = abs(Triangulation.signedArea(ring))
        let count = Int(area / 100 * density)
        let minimum = ring.reduce(SIMD2(Double.infinity, .infinity)) { pointwiseMin($0, $1) }
        let maximum = ring.reduce(SIMD2(-Double.infinity, -.infinity)) { pointwiseMax($0, $1) }
        var placed = 0, attempts = 0
        while placed < count, attempts < count * 10 {
            attempts += 1
            let center = SIMD2(random.next(in: minimum.x...maximum.x), random.next(in: minimum.y...maximum.y))
            guard contains(ring, center) else { continue }
            let half = SIMD2(random.next(in: 2...4), random.next(in: 2.5...5))
            let box = [center - half, SIMD2(center.x + half.x, center.y - half.y), center + half, SIMD2(center.x - half.x, center.y + half.y)]
            addWalls(box, bottom: base, height: 1, to: &mesh)
            let top = base + 1
            mesh.addQuad(SIMD3(box[0], top), SIMD3(box[1], top), SIMD3(box[2], top), SIMD3(box[3], top), normal: SIMD3(0, 0, 1), material: 5)
            placed += 1
        }
    }

    private func contains(_ ring: [SIMD2<Double>], _ point: SIMD2<Double>) -> Bool {
        var inside = false
        var j = ring.count - 1
        for i in ring.indices {
            let a = ring[i], b = ring[j]
            if (a.y > point.y) != (b.y > point.y), point.x < a.x + (point.y - a.y) * (b.x - a.x) / (b.y - a.y) {
                inside.toggle()
            }
            j = i
        }
        return inside
    }
}

/// Accumulates flat-shaded triangles in ENU coordinates and emits a RealityKit mesh.
private struct MeshBuilder {
    private var positions: [SIMD3<Float>] = []
    private var normals: [SIMD3<Float>] = []
    private var faceMaterials: [UInt32] = []

    var triangleCount: Int { faceMaterials.count }

    /// Vertices counter-clockwise as seen from the side `normal` points to.
    mutating func addTriangle(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ c: SIMD3<Double>, normal: SIMD3<Double>, material: UInt32) {
        positions += [a, b, c].map(RenderSpace.point)
        normals += Array(repeating: RenderSpace.point(normal), count: 3)
        faceMaterials.append(material)
    }

    mutating func addQuad(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ c: SIMD3<Double>, _ d: SIMD3<Double>, normal: SIMD3<Double>, material: UInt32) {
        addTriangle(a, b, c, normal: normal, material: material)
        addTriangle(a, c, d, normal: normal, material: material)
    }

    func descriptor(name: String) -> MeshDescriptor {
        var descriptor = MeshDescriptor(name: name)
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.normals = MeshBuffers.Normals(normals)
        descriptor.primitives = .triangles(Array(0..<UInt32(positions.count)))
        descriptor.materials = .perFace(faceMaterials)
        return descriptor
    }
}

/// Small deterministic RNG so filler layouts (and perf numbers) are repeatable.
struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func next(in range: ClosedRange<Double>) -> Double {
        range.lowerBound + Double(next() >> 11) / Double(1 << 53) * (range.upperBound - range.lowerBound)
    }
}

private extension SIMD3 where Scalar == Double {
    init(_ xy: SIMD2<Double>, _ z: Double) { self.init(xy.x, xy.y, z) }
}

private extension UIColor {
    func withBrightness(_ brightness: Double) -> UIColor {
        var hue: CGFloat = 0, saturation: CGFloat = 0, oldBrightness: CGFloat = 0, alpha: CGFloat = 0
        getHue(&hue, saturation: &saturation, brightness: &oldBrightness, alpha: &alpha)
        return UIColor(hue: hue, saturation: saturation, brightness: CGFloat(brightness) + 0.2, alpha: alpha)
    }
}
