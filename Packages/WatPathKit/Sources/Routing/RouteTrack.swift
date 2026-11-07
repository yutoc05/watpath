import CampusGeo
import Foundation

/// A line measured along its length, on the map plane.
struct MeasuredLine: Sendable {
    let points: [SIMD2<Double>]
    /// How far along the line each point is.
    let offsets: [Double]

    var length: Double { offsets.last ?? 0 }

    init(_ line: [SIMD2<Double>]) {
        var points: [SIMD2<Double>] = []
        var offsets: [Double] = []
        for point in line where points.last != point {
            offsets.append((offsets.last ?? 0) + (points.last.map { Self.distance($0, point) } ?? 0))
            points.append(point)
        }
        self.points = points
        self.offsets = offsets
    }

    func point(at offset: Double) -> SIMD2<Double> {
        guard let first = points.first, let last = points.last else { return .zero }
        guard offset > 0 else { return first }
        guard offset < length else { return last }
        var low = 0, high = offsets.count - 1
        while high - low > 1 {
            let middle = (low + high) / 2
            if offsets[middle] <= offset { low = middle } else { high = middle }
        }
        let share = (offset - offsets[low]) / (offsets[high] - offsets[low])
        return points[low] + (points[high] - points[low]) * share
    }

    func point(atShare share: Double) -> SIMD2<Double> {
        point(at: share * length)
    }

    static func distance(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double {
        let d = b - a
        return (d * d).sum().squareRoot()
    }
}

/// A route as something to move along: where a distance along it falls on the map, and
/// which way it's heading there. Distances are the route's own true meters. The map
/// plane differs from those by at most about 0.2%, so positions go by share of the way.
public struct RouteTrack: Sendable {
    /// Meters.
    public let length: Double
    private let line: MeasuredLine
    /// The line with its corners rounded, for the camera to follow, in even steps along
    /// the route. It's shorter than the route, since it cuts corners, so it's read by
    /// step and not by length: that way the two can't drift apart along a long route.
    private let cameraPath: [SIMD2<Double>]
    private let outdoorStretches: [ClosedRange<Double>]
    private let tuning: NavigationTuning

    public init(route: Route, plane: MapPlane, tuning: NavigationTuning = .standard) {
        length = route.distance
        line = MeasuredLine(route.points.map(plane.planar))
        cameraPath = Self.rounded(line, spacing: tuning.splineSpacing)
        self.tuning = tuning

        var stretches: [ClosedRange<Double>] = []
        var walked = 0.0
        for span in route.spans {
            if span.kind == .outdoor {
                if let last = stretches.last, last.upperBound == walked {
                    stretches[stretches.count - 1] = last.lowerBound...(walked + span.length)
                } else {
                    stretches.append(walked...(walked + span.length))
                }
            }
            walked += span.length
        }
        outdoorStretches = stretches.filter { $0.upperBound - $0.lowerBound >= tuning.shortestOutdoorStretch }
    }

    /// The exact spot on the route.
    public func point(at distance: Double) -> SIMD2<Double> {
        line.point(atShare: share(distance))
    }

    /// Where the camera looks: on the route, or close to it where it rounds a corner.
    public func aim(at distance: Double) -> SIMD2<Double> {
        guard cameraPath.count > 1 else { return point(at: distance) }
        let position = share(distance) * Double(cameraPath.count - 1)
        let step = min(Int(position), cameraPath.count - 2)
        return cameraPath[step] + (cameraPath[step + 1] - cameraPath[step]) * (position - Double(step))
    }

    /// The way the route runs around `distance`, in radians clockwise from north. It
    /// leans on what's ahead, so the camera turns into a corner rather than after it.
    public func facing(at distance: Double) -> Double {
        var behind = aim(at: distance - tuning.lookBehind)
        var ahead = aim(at: distance + tuning.lookAhead)
        // At the very start and end, the window closes up on one side.
        if behind == ahead {
            behind = line.points.first ?? behind
            ahead = line.points.last ?? ahead
        }
        let direction = ahead - behind
        return atan2(direction.x, direction.y)
    }

    public func isOutside(at distance: Double) -> Bool {
        outdoorStretches.contains { $0.contains(distance) }
    }

    /// True within `margin` meters of an outdoor stretch, either way along the route.
    public func isNearOutside(at distance: Double, within margin: Double) -> Bool {
        outdoorStretches.contains { $0.lowerBound - margin <= distance && distance <= $0.upperBound + margin }
    }

    /// Evenly spaced points along the route, for its dots.
    public func dots(every spacing: Double) -> [(distance: Double, point: SIMD2<Double>)] {
        guard length > 0, spacing > 0 else { return [] }
        let count = Int(length / spacing)
        return (0...count).map { index in
            let distance = Double(index) * spacing
            return (distance, point(at: distance))
        }
    }

    private func share(_ distance: Double) -> Double {
        length > 0 ? min(max(distance / length, 0), 1) : 0
    }

    /// A centripetal Catmull-Rom spline through points spaced evenly along `line`. The
    /// spacing makes corners round off within a few meters and leaves straights straight,
    /// and the centripetal form never overshoots or loops at a sharp corner.
    private static func rounded(_ line: MeasuredLine, spacing: Double) -> [SIMD2<Double>] {
        let count = Int((line.length / spacing).rounded())
        guard count >= 2 else { return [] }
        let knots = (0...count).map { line.point(at: Double($0) / Double(count) * line.length) }
        // Mirrored ends, so the spline runs all the way to the first and last points.
        let padded = [knots[0] * 2 - knots[1]] + knots + [knots[count] * 2 - knots[count - 1]]
        var result = [knots[0]]
        for index in 1..<(padded.count - 2) {
            for step in 1...substeps {
                result.append(catmullRom(padded[index - 1], padded[index], padded[index + 1], padded[index + 2], Double(step) / Double(substeps)))
            }
        }
        return result
    }

    private static let substeps = 6

    /// The Barry–Goldman form, `share` of the way from `b` to `c`.
    private static func catmullRom(_ a: SIMD2<Double>, _ b: SIMD2<Double>, _ c: SIMD2<Double>, _ d: SIMD2<Double>, _ share: Double) -> SIMD2<Double> {
        func gap(_ p: SIMD2<Double>, _ q: SIMD2<Double>) -> Double {
            max(MeasuredLine.distance(p, q).squareRoot(), 1e-6)
        }
        let t0 = 0.0, t1 = t0 + gap(a, b), t2 = t1 + gap(b, c), t3 = t2 + gap(c, d)
        let t = t1 + share * (t2 - t1)
        func mix(_ p: SIMD2<Double>, _ q: SIMD2<Double>, _ from: Double, _ to: Double) -> SIMD2<Double> {
            p * ((to - t) / (to - from)) + q * ((t - from) / (to - from))
        }
        let a1 = mix(a, b, t0, t1), a2 = mix(b, c, t1, t2), a3 = mix(c, d, t2, t3)
        return mix(mix(a1, a2, t0, t2), mix(a2, a3, t1, t3), t1, t2)
    }
}
