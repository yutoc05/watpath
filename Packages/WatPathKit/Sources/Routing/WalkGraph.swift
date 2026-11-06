import CampusGeo
import Foundation

/// The walking graph (build/CampusBundle/graph.json, built by tools/compiler/graph.py):
/// the Path Map's lines indoors and OSM's footpaths outdoors, joined at doors.
public struct WalkGraph: Sendable, Decodable {
    public static let supportedSchemaVersion = 10

    public enum LoadError: Error, Equatable {
        case unsupportedSchema(Int)
    }

    /// One way across an edge that changes floors, read from `a` to `b`. Values are
    /// storeys (the basement is 0, floor 1 is 1); nil means nobody knows.
    public struct FloorChange: Sendable, Equatable, Decodable {
        public var enter: Double?
        public var exit: Double?

        public init(enter: Double?, exit: Double?) {
            self.enter = enter
            self.exit = exit
        }

        public init(from decoder: Decoder) throws {
            var pair = try decoder.unkeyedContainer()
            enter = try pair.decode(Double?.self)
            exit = try pair.decode(Double?.self)
        }

        var reversed: FloorChange { FloorChange(enter: exit, exit: enter) }
    }

    public struct Edge: Sendable, Decodable {
        public enum Kind: String, Sendable, Decodable {
            /// A hallway on the Path Map.
            case corridor
            /// From a corridor to a door: there's no line, only that the door is there.
            case door
            case bridge, tunnel
            /// Where a corridor passes into the next building. It has no length.
            case link
            case outdoor

            public var isInside: Bool { self != .outdoor }
        }

        public var a: Int
        public var b: Int
        public var kind: Kind
        /// True meters.
        public var length: Double
        /// Bends between `a` and `b`.
        public var points: [GeoCoordinate]
        /// The building an indoor edge runs through.
        public var building: String?
        /// Set when the edge changes floors: one entry per way across.
        public var floors: [FloorChange]?
        /// Walkable only from `a` to `b`.
        public var isOneWay: Bool

        private enum CodingKeys: String, CodingKey {
            case a, b, kind, length, points, building, floors, oneWay
        }

        public init(
            a: Int, b: Int, kind: Kind, length: Double, points: [GeoCoordinate] = [], building: String? = nil,
            floors: [FloorChange]? = nil, isOneWay: Bool = false
        ) {
            self.a = a
            self.b = b
            self.kind = kind
            self.length = length
            self.points = points
            self.building = building
            self.floors = floors
            self.isOneWay = isOneWay
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            a = try container.decode(Int.self, forKey: .a)
            b = try container.decode(Int.self, forKey: .b)
            kind = try container.decode(Kind.self, forKey: .kind)
            length = try container.decode(Double.self, forKey: .length)
            points = try container.decodeIfPresent([[Double]].self, forKey: .points)?.map(GeoCoordinate.init(lonLat:)) ?? []
            building = try container.decodeIfPresent(String.self, forKey: .building)
            floors = try container.decodeIfPresent([FloorChange].self, forKey: .floors)
            isOneWay = try container.decodeIfPresent(Bool.self, forKey: .oneWay) ?? false
        }
    }

    /// How routes reach a building.
    public struct Building: Sendable, Decodable, Equatable {
        /// With lines: the point on them nearest the building's middle. Without: its
        /// doors, and the ends of any lines that reach it.
        public var anchors: [Int]
        public var hasLines: Bool

        public init(anchors: [Int], hasLines: Bool) {
            self.anchors = anchors
            self.hasLines = hasLines
        }
    }

    /// One edge leaving a node.
    struct Step: Sendable {
        var edge: Int
        var to: Int
        var isForward: Bool
    }

    public var nodes: [GeoCoordinate]
    public var edges: [Edge]
    public var doors: [String: Int]
    public var buildings: [String: Building]
    /// The edges leaving each node.
    let steps: [[Step]]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, nodes, edges, doors, buildings
    }

    public init(nodes: [GeoCoordinate], edges: [Edge], doors: [String: Int] = [:], buildings: [String: Building] = [:]) {
        self.nodes = nodes
        self.edges = edges
        self.doors = doors
        self.buildings = buildings
        steps = Self.steps(nodeCount: nodes.count, edges: edges)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schema = try container.decode(Int.self, forKey: .schemaVersion)
        guard schema == Self.supportedSchemaVersion else { throw LoadError.unsupportedSchema(schema) }
        try self.init(
            nodes: container.decode([[Double]].self, forKey: .nodes).map(GeoCoordinate.init(lonLat:)),
            edges: container.decode([Edge].self, forKey: .edges),
            doors: container.decode([String: Int].self, forKey: .doors),
            buildings: container.decode([String: Building].self, forKey: .buildings)
        )
    }

    public static func load(from directory: URL) throws -> WalkGraph {
        try JSONDecoder().decode(WalkGraph.self, from: Data(contentsOf: directory.appendingPathComponent("graph.json")))
    }

    private static func steps(nodeCount: Int, edges: [Edge]) -> [[Step]] {
        var steps = [[Step]](repeating: [], count: nodeCount)
        for (index, edge) in edges.enumerated() {
            steps[edge.a].append(Step(edge: index, to: edge.b, isForward: true))
            if !edge.isOneWay {
                steps[edge.b].append(Step(edge: index, to: edge.a, isForward: false))
            }
        }
        return steps
    }

    /// The edge's whole line, from `a` to `b`.
    func line(of edge: Edge) -> [GeoCoordinate] {
        [nodes[edge.a]] + edge.points + [nodes[edge.b]]
    }
}

extension GeoCoordinate {
    /// From GeoJSON order, [longitude, latitude].
    fileprivate init(lonLat pair: [Double]) {
        self.init(latitude: pair[1], longitude: pair[0])
    }
}
