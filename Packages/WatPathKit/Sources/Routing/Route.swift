import CampusGeo

/// A way from one place to another, and what it costs.
public struct Route: Sendable, Identifiable, Equatable {
    public enum Label: String, Sendable, Equatable {
        case best = "Best route"
        case fastest = "Fastest"
        case balanced = "Balanced"
        case lessOutside = "Less outside"
        case mostIndoor = "Most indoor"
    }

    /// A stretch of one kind, in walking order.
    public struct Span: Sendable, Equatable {
        public var kind: WalkGraph.Edge.Kind
        public var points: [GeoCoordinate]
        /// Meters.
        public var length: Double
    }

    /// Its place in the list it came from.
    public internal(set) var id = 0
    public internal(set) var label = Label.best
    public var spans: [Span]
    /// Meters.
    public var distance: Double
    public var insideLength: Double
    public var outsideLength: Double
    public var seconds: Double
    /// Storeys climbed or descended, as far as anyone knows.
    public var storeys: Double
    /// Buildings passed through, in order.
    public var buildings: [String]
    /// The graph edges it uses, for telling routes apart.
    var edges: Set<Int>

    /// The whole line, from start to finish.
    public var points: [GeoCoordinate] {
        var line: [GeoCoordinate] = []
        for point in spans.flatMap(\.points) where line.last != point {
            line.append(point)
        }
        return line
    }

    /// How much of the walk is indoors, from 0 to 1.
    public var insideFraction: Double {
        distance > 0 ? insideLength / distance : 1
    }

    /// True when `other` is at least as good on both time and time outside, and
    /// better on one of them.
    func isBeaten(by other: Route) -> Bool {
        other.seconds <= seconds && other.outsideLength <= outsideLength
            && (other.seconds < seconds || other.outsideLength < outsideLength)
    }
}
