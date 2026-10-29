/// Planar polygon helpers for building outlines on the `MapPlane`. A polygon is a
/// list of rings, outline first and holes after; containment uses the even-odd rule,
/// so holes work without knowing which ring is which.
public enum PolygonGeometry {
    public static func contains(_ rings: [[SIMD2<Double>]], _ point: SIMD2<Double>) -> Bool {
        var inside = false
        for ring in rings where ring.count >= 3 {
            var j = ring.count - 1
            for i in ring.indices {
                let a = ring[i], b = ring[j]
                if (a.y > point.y) != (b.y > point.y), point.x < a.x + (point.y - a.y) * (b.x - a.x) / (b.y - a.y) {
                    inside.toggle()
                }
                j = i
            }
        }
        return inside
    }

    /// Closest point on any ring edge to `point`.
    public static func nearestEdgePoint(_ rings: [[SIMD2<Double>]], _ point: SIMD2<Double>) -> SIMD2<Double> {
        var best = point
        var bestDistance = Double.infinity
        for ring in rings {
            for (a, b) in zip(ring, ring.dropFirst() + ring.prefix(1)) {
                let candidate = closestPoint(onSegment: a, b, to: point)
                let distance = length(candidate - point)
                if distance < bestDistance {
                    bestDistance = distance
                    best = candidate
                }
            }
        }
        return best
    }

    public static func distanceToEdges(_ rings: [[SIMD2<Double>]], _ point: SIMD2<Double>) -> Double {
        length(nearestEdgePoint(rings, point) - point)
    }

    /// `point` if it's inside, otherwise the nearest point that is inside, about
    /// `inset` meters in from the edge (so a snapped pin doesn't sit on a wall).
    public static func nearestPointInside(_ rings: [[SIMD2<Double>]], _ point: SIMD2<Double>, inset: Double) -> SIMD2<Double> {
        if contains(rings, point) { return point }
        let edge = nearestEdgePoint(rings, point)
        let toEdge = edge - point
        let distance = length(toEdge)
        guard distance > 1e-9 else { return edge }
        // Keep going the way we were heading; that usually crosses straight into the polygon.
        let ahead = edge + toEdge / distance * inset
        if contains(rings, ahead) { return ahead }
        // At a corner the straight line can clip outside; try stepping in less far.
        for fraction in [0.5, 0.25, 0.1] {
            let shorter = edge + toEdge / distance * inset * fraction
            if contains(rings, shorter) { return shorter }
        }
        return edge
    }

    /// A point comfortably inside the polygon for its label: approximately the
    /// point farthest from every edge (the "pole of inaccessibility"), found by a
    /// grid search refined around the best cell. Unlike the centroid, it stays
    /// inside L- and U-shaped buildings.
    public static func labelPoint(_ rings: [[SIMD2<Double>]]) -> SIMD2<Double> {
        let points = rings.first ?? []
        guard !points.isEmpty else { return .zero }
        let minimum = points.reduce(SIMD2(Double.infinity, .infinity)) { pointwiseMin($0, $1) }
        let maximum = points.reduce(SIMD2(-Double.infinity, -.infinity)) { pointwiseMax($0, $1) }
        var best = (minimum + maximum) / 2
        var bestScore = contains(rings, best) ? distanceToEdges(rings, best) : -.infinity
        var cell = (maximum - minimum) / 16
        var center = best
        for _ in 0..<5 {
            for i in -8...8 {
                for j in -8...8 {
                    let candidate = center + SIMD2(Double(i) * cell.x, Double(j) * cell.y)
                    guard contains(rings, candidate) else { continue }
                    let score = distanceToEdges(rings, candidate)
                    if score > bestScore {
                        bestScore = score
                        best = candidate
                    }
                }
            }
            center = best
            cell /= 4
        }
        return best
    }

    private static func closestPoint(onSegment a: SIMD2<Double>, _ b: SIMD2<Double>, to p: SIMD2<Double>) -> SIMD2<Double> {
        let ab = b - a
        let lengthSquared = (ab * ab).sum()
        guard lengthSquared > 0 else { return a }
        let t = min(max(((p - a) * ab).sum() / lengthSquared, 0), 1)
        return a + ab * t
    }
}
