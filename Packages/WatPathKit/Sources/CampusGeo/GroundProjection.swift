/// Projects points on the ground to the screen. The Path Map is flat, so this is the
/// only projection it needs, for a couple of thousand points every frame.
///
/// Anything at or behind the camera can't be projected, and a tilted camera has part
/// of campus behind it, so shapes are clipped where they cross just in front of the
/// camera. Dropping those points instead would turn a filled building into nonsense.
public struct GroundProjection: Sendable {
    /// How far in front of the camera shapes are cut off, in meters.
    public static let nearDepth = 1.0

    private let eye: SIMD3<Double>
    private let right: SIMD3<Double>
    private let up: SIMD3<Double>
    private let forward: SIMD3<Double>
    private let focalLength: Double
    private let center: SIMD2<Double>

    public init(_ projector: PinholeProjector) {
        eye = projector.pose.eye
        right = projector.pose.right
        up = projector.pose.up
        forward = projector.pose.forward
        focalLength = projector.pose.focalLength
        center = projector.viewportSize / 2
    }

    /// The closed `ring` on screen. Empty if it's all behind the camera.
    public func project(ring: [SIMD2<Double>]) -> [SIMD2<Double>] {
        guard let last = ring.last else { return [] }
        var result: [SIMD2<Double>] = []
        result.reserveCapacity(ring.count)
        var previous = last
        var previousDepth = depth(of: last)
        for point in ring {
            let pointDepth = depth(of: point)
            if (pointDepth >= Self.nearDepth) != (previousDepth >= Self.nearDepth) {
                result.append(screen(crossing(previous, previousDepth, point, pointDepth)))
            }
            if pointDepth >= Self.nearDepth { result.append(screen(point)) }
            previous = point
            previousDepth = pointDepth
        }
        return result
    }

    /// The open `line` on screen, in one piece per stretch in front of the camera.
    public func project(line: [SIMD2<Double>]) -> [[SIMD2<Double>]] {
        var pieces: [[SIMD2<Double>]] = []
        var piece: [SIMD2<Double>] = []
        var previous: (point: SIMD2<Double>, depth: Double)?
        for point in line {
            let pointDepth = depth(of: point)
            let isInFront = pointDepth >= Self.nearDepth
            if let previous, isInFront != (previous.depth >= Self.nearDepth) {
                piece.append(screen(crossing(previous.point, previous.depth, point, pointDepth)))
                if !isInFront {
                    pieces.append(piece)
                    piece = []
                }
            }
            if isInFront { piece.append(screen(point)) }
            previous = (point, pointDepth)
        }
        if piece.count >= 2 { pieces.append(piece) }
        return pieces
    }

    private func depth(of point: SIMD2<Double>) -> Double {
        forward.x * (point.x - eye.x) + forward.y * (point.y - eye.y) - forward.z * eye.z
    }

    private func crossing(_ a: SIMD2<Double>, _ depthA: Double, _ b: SIMD2<Double>, _ depthB: Double) -> SIMD2<Double> {
        a + (b - a) * ((Self.nearDepth - depthA) / (depthB - depthA))
    }

    private func screen(_ point: SIMD2<Double>) -> SIMD2<Double> {
        let x = point.x - eye.x, y = point.y - eye.y
        let scale = focalLength / (forward.x * x + forward.y * y - forward.z * eye.z)
        return SIMD2(
            center.x + (right.x * x + right.y * y - right.z * eye.z) * scale,
            center.y - (up.x * x + up.y * y - up.z * eye.z) * scale
        )
    }
}
