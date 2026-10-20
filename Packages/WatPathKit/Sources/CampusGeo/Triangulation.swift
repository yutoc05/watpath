/// Ear-clipping triangulation for simple polygons. O(n²), which is plenty for
/// building outlines (tens to a couple of hundred vertices). Holes are not
/// supported yet; the map compiler will take over meshing in Phase 2.
public enum Triangulation {
    /// Triangle vertex indices into `ring`, three per triangle, counter-clockwise.
    /// A repeated closing vertex is ignored. Works for either winding.
    public static func triangulate(_ ring: [SIMD2<Double>]) -> [Int] {
        var count = ring.count
        if count > 1, ring[0] == ring[count - 1] { count -= 1 }
        guard count >= 3 else { return [] }

        var remaining = Array(0..<count)
        if signedArea(remaining.map { ring[$0] }) < 0 { remaining.reverse() }

        var triangles: [Int] = []
        triangles.reserveCapacity((count - 2) * 3)
        while remaining.count > 3 {
            guard let ear = findEar(in: remaining, ring: ring) else {
                // Self-intersecting or degenerate input: drop the flattest vertex,
                // which is harmless if it's collinear, and keep going.
                remaining.remove(at: flattestVertex(in: remaining, ring: ring))
                continue
            }
            let n = remaining.count
            triangles += [remaining[(ear + n - 1) % n], remaining[ear], remaining[(ear + 1) % n]]
            remaining.remove(at: ear)
        }
        if signedArea(remaining.map { ring[$0] }) > 0 { triangles += remaining }
        return triangles
    }

    /// Signed area: positive for counter-clockwise rings.
    public static func signedArea(_ ring: [SIMD2<Double>]) -> Double {
        guard ring.count >= 3 else { return 0 }
        var sum = 0.0
        for i in ring.indices {
            sum += cross(ring[i], ring[(i + 1) % ring.count])
        }
        return sum / 2
    }

    private static func findEar(in remaining: [Int], ring: [SIMD2<Double>]) -> Int? {
        let n = remaining.count
        for i in 0..<n {
            let a = ring[remaining[(i + n - 1) % n]]
            let b = ring[remaining[i]]
            let c = ring[remaining[(i + 1) % n]]
            guard cross(b - a, c - b) > 1e-12 else { continue }  // reflex or collinear
            let blocked = remaining.contains { index in
                let p = ring[index]
                return p != a && p != b && p != c && contains(triangle: (a, b, c), point: p)
            }
            if !blocked { return i }
        }
        return nil
    }

    private static func flattestVertex(in remaining: [Int], ring: [SIMD2<Double>]) -> Int {
        let n = remaining.count
        return (0..<n).min { i, j in
            func turn(_ k: Int) -> Double {
                let a = ring[remaining[(k + n - 1) % n]]
                let b = ring[remaining[k]]
                let c = ring[remaining[(k + 1) % n]]
                return abs(cross(b - a, c - b))
            }
            return turn(i) < turn(j)
        }!
    }

    private static func contains(triangle: (SIMD2<Double>, SIMD2<Double>, SIMD2<Double>), point p: SIMD2<Double>) -> Bool {
        let (a, b, c) = triangle
        return cross(b - a, p - a) >= 0 && cross(c - b, p - b) >= 0 && cross(a - c, p - c) >= 0
    }
}
