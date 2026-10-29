import CampusGeo
import CampusModel
import RealityKit
import UIKit

/// Everything the Path Map draws. Each Path Map floor is its own entity, so the
/// map can show one floor per building and highlight buildings.
struct CampusScene {
    /// Building code → an entity per floor the Path Map shows, by index into `Building.floors`.
    var buildingFloors: [String: [Int: ModelEntity]]
    /// Buildings no bridge, tunnel or link reaches: only their footprint, always shown.
    var footprints: [String: ModelEntity]
    var connections: [ModelEntity]
    var triangles: Int

    var entities: [ModelEntity] { buildingFloors.values.flatMap(\.values) + footprints.values + connections }

    func entities(of code: String) -> [ModelEntity] {
        (buildingFloors[code].map { Array($0.values) } ?? []) + [footprints[code]].compactMap { $0 }
    }
}

/// Builds the Tier 0 scene: per Path Map floor (one a bridge, tunnel or link meets),
/// a floor slab and a low perimeter wall at that floor's height, with its corridors;
/// per building with no such floor, a flat footprint at ground level; per connection,
/// a walkway with low side walls, blue for bridges and red for tunnels.
/// For Spike S2 it can add filler "rooms" to approximate Tier 2 geometry.
struct CampusSceneBuilder {
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
    /// Corridor walls stand a little lower than the outside walls, so the outline still reads first.
    var corridorWallHeight = 1.0
    /// Thick enough that, from straight above, each wall is a dark line along the corridor.
    var corridorWallThickness = 0.4
    /// Corridor floors sit just above the slab so they never fight it for depth.
    var corridorLift = 0.05
    var walkwayWidth = 3.0

    // Flat, unlit colors with baked-in "sun" shading keep the look stylized and
    // independent of lighting. Material slots: 0 floor, 1–4 wall shades, 5 filler
    // top, 6 corridor floor, 7–10 corridor wall shades.
    private static let lightDirection = SIMD2<Double>(-0.6, 0.8)
    private static let wallShades = [0.42, 0.52, 0.62, 0.72]

    func build(_ campus: CampusBundle, complexity: Complexity = .shells) throws -> CampusScene {
        var scene = CampusScene(buildingFloors: [:], footprints: [:], connections: [], triangles: 0)
        var random = SplitMix64(seed: 0x5EED)
        let materials = Self.buildingMaterials(highlighted: false)
        let footprints = campus.buildings.map { building in
            (code: building.code, heights: Self.drawnHeights(of: building), rings: building.parts.map { counterClockwiseRing($0.outline) })
        }
        for building in campus.buildings {
            guard !building.mappedFloorIndices.isEmpty else {
                var mesh = MeshBuilder()
                let base = building.groundFloor?.elevation ?? 0
                for part in building.parts { addSlab(counterClockwiseRing(part.outline), base: base, to: &mesh) }
                scene.footprints[building.code] = try mesh.entity(name: "\(building.code)-footprint", materials: materials)
                scene.triangles += mesh.triangleCount
                continue
            }
            var floors: [Int: ModelEntity] = [:]
            // Floors a connection proves exist can be above what OSM says; the tallest part reaches them.
            let tallest = building.parts.map(\.levels).max() ?? 1
            for index in building.mappedFloorIndices {
                let floor = building.floors[index]
                var mesh = MeshBuilder()
                // Where outlines overlap (EV3 was built over part of EV2), a wall that runs
                // inside another building with a floor at this height isn't an outside wall.
                // Leaving it out also keeps a selected building solid orange across the overlap.
                let others = footprints
                    .filter { $0.code != building.code && $0.heights.contains { abs($0 - floor.elevation) < 0.5 } }
                    .map(\.rings)
                // Basements span the whole footprint; above ground, shorter parts stop.
                for part in building.parts where floor.isBelowGround || part.levels == tallest || (Int(floor.name) ?? 1) <= part.levels {
                    let ring = counterClockwiseRing(part.outline)
                    addSlab(ring, base: floor.elevation, to: &mesh)
                    addWalls(ring, bottom: floor.elevation, height: wallHeight, outside: others, to: &mesh)
                    addFiller(in: ring, base: floor.elevation + slabThickness, density: complexity.fillerDensity, random: &random, to: &mesh)
                }
                if let corridor = floor.corridor {
                    addCorridor(corridor, base: floor.elevation + slabThickness, to: &mesh)
                }
                floors[index] = try mesh.entity(name: "\(building.code)-\(floor.name)", materials: materials)
                scene.triangles += mesh.triangleCount
            }
            scene.buildingFloors[building.code] = floors
        }
        for connection in campus.connections {
            var mesh = MeshBuilder()
            // One walkway per storey; each rises or falls between the floors its ends meet.
            for deck in 0..<connection.deckCount {
                for path in connection.paths {
                    let from = campus.elevation(of: connection, end: path.from, deck: deck)
                    let to = campus.elevation(of: connection, end: path.to, deck: deck)
                    addWalkway(path.points.map(plane.planar), from: from, to: to, to: &mesh)
                }
            }
            guard mesh.triangleCount > 0 else { continue }
            scene.connections.append(try mesh.entity(name: connection.id, materials: Self.walkwayMaterials(connection.kind)))
            scene.triangles += mesh.triangleCount
        }
        return scene
    }

    /// Heights at which the building can be drawn: its Path Map floors, or its footprint.
    private static func drawnHeights(of building: Building) -> [Double] {
        let mapped = building.mappedFloorIndices.map { building.floors[$0].elevation }
        return mapped.isEmpty ? [building.groundFloor?.elevation ?? 0] : mapped
    }

    static func buildingMaterials(highlighted: Bool) -> [any Material] {
        let floor = highlighted ? UIColor(red: 1, green: 0.62, blue: 0.2, alpha: 1) : UIColor(white: 0.86, alpha: 1)
        let tint = highlighted ? UIColor(red: 0.9, green: 0.45, blue: 0.1, alpha: 1) : UIColor(red: 0.55, green: 0.57, blue: 0.62, alpha: 1)
        // Corridors: a pale floor between darker walls, so the way through reads like a floor plan.
        let corridorFloor = highlighted ? UIColor(red: 1, green: 0.84, blue: 0.62, alpha: 1) : UIColor(white: 0.98, alpha: 1)
        let corridorTint = highlighted ? UIColor(red: 0.62, green: 0.3, blue: 0.06, alpha: 1) : UIColor(red: 0.3, green: 0.32, blue: 0.38, alpha: 1)
        let corridorWalls = corridorWallShades.map { corridorTint.withBrightness($0, offset: 0) }
        return materials(floor: floor, wallTint: tint) + ([corridorFloor] + corridorWalls).map { UnlitMaterial(color: $0) }
    }

    private static let corridorWallShades = [0.3, 0.36, 0.42, 0.48]

    /// Walkways are the "path" itself, so they're the most saturated thing in the scene.
    static func walkwayMaterials(_ kind: Connection.Kind) -> [any Material] {
        materials(floor: kind.color, wallTint: kind.wallColor)
    }

    private static func materials(floor: UIColor, wallTint: UIColor) -> [any Material] {
        var colors = [floor]
        colors += wallShades.map { wallTint.withBrightness($0) }
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
    private func addWalls(_ ring: [SIMD2<Double>], bottom: Double, height: Double, outside others: [[[SIMD2<Double>]]] = [], to mesh: inout MeshBuilder) {
        for i in ring.indices {
            let a = ring[i], b = ring[(i + 1) % ring.count]
            for (start, end) in Self.pieces(from: a, to: b, outside: others) {
                addWall(from: start, to: end, bottom: bottom, height: height, to: &mesh)
            }
        }
    }

    /// The parts of the segment a → b not well inside any of `others` (each a
    /// building's rings). Walls on a shared boundary stay: only points more than
    /// `wallClipMargin` inside count, so adjoining buildings keep both their walls.
    static func pieces(from a: SIMD2<Double>, to b: SIMD2<Double>, outside others: [[[SIMD2<Double>]]]) -> [(SIMD2<Double>, SIMD2<Double>)] {
        let minimum = pointwiseMin(a, b), maximum = pointwiseMax(a, b)
        let nearby = others.filter { rings in
            let points = rings.flatMap { $0 }
            let low = points.reduce(SIMD2(Double.infinity, .infinity)) { pointwiseMin($0, $1) }
            let high = points.reduce(SIMD2(-Double.infinity, -.infinity)) { pointwiseMax($0, $1) }
            return all(low .<= maximum) && all(minimum .<= high)
        }
        guard !nearby.isEmpty else { return [(a, b)] }
        // Split where the segment crosses any nearby edge, then keep each piece whose middle is outside.
        var cuts: [Double] = [0, 1]
        for rings in nearby {
            for ring in rings {
                for i in ring.indices {
                    if let t = crossing(a, b, ring[i], ring[(i + 1) % ring.count]) { cuts.append(t) }
                }
            }
        }
        cuts.sort()
        var kept: [(SIMD2<Double>, SIMD2<Double>)] = []
        for (t0, t1) in zip(cuts, cuts.dropFirst()) where t1 - t0 > 1e-9 {
            let middle = a + (b - a) * ((t0 + t1) / 2)
            let isInside = nearby.contains { PolygonGeometry.contains($0, middle) && PolygonGeometry.distanceToEdges($0, middle) > wallClipMargin }
            guard !isInside else { continue }
            let start = a + (b - a) * t0, end = a + (b - a) * t1
            if let last = kept.last, last.1 == start { kept[kept.count - 1].1 = end } else { kept.append((start, end)) }
        }
        return kept
    }

    private static let wallClipMargin = 0.3

    /// Where along a → b (0…1) it crosses c → d, if it does.
    private static func crossing(_ a: SIMD2<Double>, _ b: SIMD2<Double>, _ c: SIMD2<Double>, _ d: SIMD2<Double>) -> Double? {
        let r = b - a, s = d - c
        let denominator = r.x * s.y - r.y * s.x
        guard abs(denominator) > 1e-12 else { return nil }
        let q = c - a
        let t = (q.x * s.y - q.y * s.x) / denominator
        let u = (q.x * r.y - q.y * r.x) / denominator
        return (0...1).contains(t) && (0...1).contains(u) ? t : nil
    }

    /// A wall facing right of the direction a → b, seen from outside as counter-clockwise.
    /// Its bottom runs from `bottom` at a to `bottomAtB` (default: level) at b.
    private func addWall(from a: SIMD2<Double>, to b: SIMD2<Double>, bottom: Double, bottomAtB: Double? = nil, height: Double, materialBase: UInt32 = 1, to mesh: inout MeshBuilder) {
        let edge = b - a
        let edgeLength = (edge * edge).sum().squareRoot()
        guard edgeLength > 1e-6 else { return }
        let outward = SIMD2(edge.y, -edge.x) / edgeLength
        let light = max(0, (outward * Self.lightDirection).sum())
        let bottomB = bottomAtB ?? bottom
        mesh.addQuad(
            SIMD3(a, bottom), SIMD3(b, bottomB), SIMD3(b, bottomB + height), SIMD3(a, bottom + height),
            normal: SIMD3(outward, 0), material: materialBase + UInt32(min(3, Int(light * 4)))
        )
    }

    /// A walkway ribbon with low walls on both sides, following `path` and sloping
    /// evenly from height `from` to `to` (they differ only if floor data disagrees).
    private func addWalkway(_ path: [SIMD2<Double>], from: Double, to: Double, to mesh: inout MeshBuilder) {
        let lengths = zip(path, path.dropFirst()).map { a, b in ((b - a) * (b - a)).sum().squareRoot() }
        let total = max(lengths.reduce(0, +), 1e-6)
        var walked = 0.0
        for ((a, b), edgeLength) in zip(zip(path, path.dropFirst()), lengths) {
            let baseA = from + (to - from) * walked / total
            walked += edgeLength
            let baseB = from + (to - from) * walked / total
            guard edgeLength > 1e-6 else { continue }
            let edge = b - a
            let right = SIMD2(edge.y, -edge.x) / edgeLength * (walkwayWidth / 2)
            let topA = baseA + slabThickness, topB = baseB + slabThickness
            mesh.addQuad(SIMD3(a + right, topA), SIMD3(b + right, topB), SIMD3(b - right, topB), SIMD3(a - right, topA), normal: SIMD3(0, 0, 1), material: 0)
            addWall(from: a + right, to: b + right, bottom: baseA, bottomAtB: baseB, height: wallHeight, to: &mesh)
            addWall(from: b - right, to: a - right, bottom: baseB, bottomAtB: baseA, height: wallHeight, to: &mesh)
        }
    }

    /// A floor's corridors: the walkable area just above the slab, and walls along
    /// both sides, drawn as thin boxes so they show from above as well as from the side.
    private func addCorridor(_ corridor: Corridor, base: Double, to mesh: inout MeshBuilder) {
        let top = base + corridorLift
        for triangle in corridor.triangles {
            var points = triangle.map(plane.planar)
            if Triangulation.signedArea(points) < 0 { points.reverse() }  // face up
            mesh.addTriangle(SIMD3(points[0], top), SIMD3(points[1], top), SIMD3(points[2], top), normal: SIMD3(0, 0, 1), material: 6)
        }
        let wallTop = base + corridorWallHeight
        for wall in corridor.walls {
            let points = wall.map(plane.planar)
            for (a, b) in zip(points, points.dropFirst()) {
                let edge = b - a
                let edgeLength = (edge * edge).sum().squareRoot()
                guard edgeLength > 1e-6 else { continue }
                let side = SIMD2(edge.y, -edge.x) / edgeLength * (corridorWallThickness / 2)
                addWall(from: a + side, to: b + side, bottom: base, height: corridorWallHeight, materialBase: 7, to: &mesh)
                addWall(from: b - side, to: a - side, bottom: base, height: corridorWallHeight, materialBase: 7, to: &mesh)
                mesh.addQuad(SIMD3(a + side, wallTop), SIMD3(b + side, wallTop), SIMD3(b - side, wallTop), SIMD3(a - side, wallTop), normal: SIMD3(0, 0, 1), material: 7)
            }
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
            guard PolygonGeometry.contains([ring], center) else { continue }
            let half = SIMD2(random.next(in: 2...4), random.next(in: 2.5...5))
            let box = [center - half, SIMD2(center.x + half.x, center.y - half.y), center + half, SIMD2(center.x - half.x, center.y + half.y)]
            addWalls(box, bottom: base, height: 1, to: &mesh)
            let top = base + 1
            mesh.addQuad(SIMD3(box[0], top), SIMD3(box[1], top), SIMD3(box[2], top), SIMD3(box[3], top), normal: SIMD3(0, 0, 1), material: 5)
            placed += 1
        }
    }
}

/// Accumulates flat-shaded triangles in map-plane coordinates and emits a RealityKit entity.
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

    func entity(name: String, materials: [any Material]) throws -> ModelEntity {
        guard !positions.isEmpty else {
            // RealityKit can't make an empty mesh; an entity with no model draws nothing.
            let entity = ModelEntity()
            entity.name = name
            return entity
        }
        var descriptor = MeshDescriptor(name: name)
        descriptor.positions = MeshBuffers.Positions(positions)
        descriptor.normals = MeshBuffers.Normals(normals)
        descriptor.primitives = .triangles(Array(0..<UInt32(positions.count)))
        descriptor.materials = .perFace(faceMaterials)
        let entity = ModelEntity(mesh: try MeshResource.generate(from: [descriptor]), materials: materials)
        entity.name = name
        return entity
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

extension Connection.Kind {
    /// Blue bridges, red tunnels. Links between adjoining
    /// buildings aren't on it, so they stay neutral.
    var color: UIColor {
        switch self {
        case .bridge: UIColor(red: 0.16, green: 0.45, blue: 1, alpha: 1)
        case .tunnel: UIColor(red: 0.96, green: 0.26, blue: 0.22, alpha: 1)
        case .link: UIColor(white: 0.72, alpha: 1)
        }
    }

    var wallColor: UIColor {
        switch self {
        case .bridge: UIColor(red: 0.1, green: 0.32, blue: 0.85, alpha: 1)
        case .tunnel: UIColor(red: 0.8, green: 0.16, blue: 0.14, alpha: 1)
        case .link: UIColor(red: 0.55, green: 0.57, blue: 0.62, alpha: 1)
        }
    }
}

private extension SIMD3 where Scalar == Double {
    init(_ xy: SIMD2<Double>, _ z: Double) { self.init(xy.x, xy.y, z) }
}

private extension UIColor {
    func withBrightness(_ brightness: Double, offset: Double = 0.2) -> UIColor {
        var hue: CGFloat = 0, saturation: CGFloat = 0, oldBrightness: CGFloat = 0, alpha: CGFloat = 0
        getHue(&hue, saturation: &saturation, brightness: &oldBrightness, alpha: &alpha)
        return UIColor(hue: hue, saturation: saturation, brightness: CGFloat(brightness + offset), alpha: alpha)
    }
}
