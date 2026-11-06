import CampusGeo
import Foundation

/// The compiled map data the app ships with (build/CampusBundle, produced by
/// tools/compiler). Schema v10: Tier 0 building shells with every floor they have,
/// the Path Map's lines (corridors, each bridge's and tunnel's own, and the dividers
/// between buildings that touch), doors, building-to-building connections with the
/// floor at each end, and Popular places.
public struct CampusBundle: Sendable, Decodable {
    public static let supportedSchemaVersion = 10

    public var schemaVersion: Int
    public var origin: GeoCoordinate
    public var attribution: String
    public var buildings: [Building]
    /// The white lines on the Path Map: hallways, all on one flat level.
    public var corridors: [[GeoCoordinate]]
    /// Hairlines where two buildings touch, so they don't merge into one shape.
    public var dividers: [[GeoCoordinate]]
    public var doors: [Door]
    public var connections: [Connection]
    public var popular: [PlaceReference]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, origin, attribution, buildings, corridors, dividers, doors, connections, popular
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        // A newer or older bundle may not even parse, so report the schema first.
        guard schemaVersion == Self.supportedSchemaVersion else {
            throw LoadError.unsupportedSchema(schemaVersion)
        }
        origin = try container.decode(GeoCoordinate.self, forKey: .origin)
        attribution = try container.decode(String.self, forKey: .attribution)
        buildings = try container.decode([Building].self, forKey: .buildings)
        corridors = try container.decode([[[Double]]].self, forKey: .corridors).map {
            try GeoCoordinate.ring($0, at: [CodingKeys.corridors])
        }
        dividers = try container.decode([[[Double]]].self, forKey: .dividers).map {
            try GeoCoordinate.ring($0, at: [CodingKeys.dividers])
        }
        doors = try container.decode([Door].self, forKey: .doors)
        connections = try container.decode([Connection].self, forKey: .connections)
        popular = try container.decode([PlaceReference].self, forKey: .popular)
    }

    public enum LoadError: Error, Equatable {
        case unsupportedSchema(Int)
    }

    public static func load(from directory: URL) throws -> CampusBundle {
        let data = try Data(contentsOf: directory.appendingPathComponent("campus.json"))
        return try decode(data)
    }

    public static func decode(_ data: Data) throws -> CampusBundle {
        try JSONDecoder().decode(CampusBundle.self, from: data)
    }

    public func building(code: String) -> Building? {
        buildings.first { $0.code == code }
    }

    public func door(id: String) -> Door? {
        doors.first { $0.id == id }
    }

    public func doors(of building: Building) -> [Door] {
        doors.filter { $0.building == building.code }
    }
}

/// A campus place stored by reference, as Popular entries and recents do.
public enum PlaceReference: Hashable, Sendable, Codable {
    case building(code: String)
    case door(id: String)

    private enum CodingKeys: String, CodingKey { case kind, id }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(String.self, forKey: .id)
        switch try container.decode(String.self, forKey: .kind) {
        case "building": self = .building(code: id)
        case "door": self = .door(id: id)
        case let kind:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: container, debugDescription: "Unknown place kind \(kind)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .building(let code):
            try container.encode("building", forKey: .kind)
            try container.encode(code, forKey: .id)
        case .door(let id):
            try container.encode("door", forKey: .kind)
            try container.encode(id, forKey: .id)
        }
    }
}

public struct Building: Sendable, Decodable, Identifiable {
    public enum Group: String, Sendable, Decodable {
        case core
    }

    public var code: String
    public var name: String
    public var aliases: [String]
    public var group: Group
    /// Which label wins where labels collide, 1 (first) to 6.
    public var priority: Int
    /// True when no source gave a level count and the compiler guessed.
    public var levelsEstimated: Bool
    /// Every floor the building has, bottom to top. Never empty.
    public var floors: [Floor]
    public var parts: [BuildingPart]
    /// Where the Path Map puts the building's label, when the data places it by
    /// hand; otherwise the app picks the widest point inside.
    public var label: GeoCoordinate?

    public var id: String { code }

    private enum CodingKeys: String, CodingKey {
        case code, name, aliases, group, priority, levelsEstimated, floors, parts, label
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        code = try container.decode(String.self, forKey: .code)
        name = try container.decode(String.self, forKey: .name)
        aliases = try container.decode([String].self, forKey: .aliases)
        group = try container.decode(Group.self, forKey: .group)
        priority = try container.decode(Int.self, forKey: .priority)
        levelsEstimated = try container.decode(Bool.self, forKey: .levelsEstimated)
        floors = try container.decode([Floor].self, forKey: .floors)
        parts = try container.decode([BuildingPart].self, forKey: .parts)
        label = try container.decodeIfPresent([Double].self, forKey: .label).map {
            try GeoCoordinate.point($0, at: [CodingKeys.label])
        }
    }

    /// Every floor, with runs of numbered floors shortened: "Basement, 1–6, Penthouse".
    public var floorSummary: String {
        var parts: [String] = []
        var run: [Int] = []
        func flush() {
            guard let first = run.first, let last = run.last else { return }
            parts.append(first == last ? "\(first)" : "\(first)–\(last)")
            run.removeAll()
        }
        for floor in floors {
            if let number = Int(floor.name) {
                if let last = run.last, number != last + 1 { flush() }
                run.append(number)
            } else {
                flush()
                parts.append(floor.title)
            }
        }
        flush()
        return parts.joined(separator: ", ")
    }
}

/// One storey of a building.
public struct Floor: Sendable, Decodable, Equatable {
    /// Short: "1", "B" (basement), "2M" (2nd-floor mezzanine), "P" (penthouse).
    public var name: String
    /// In full: "Floor 1", "Basement", "2nd floor mezzanine", "Penthouse".
    public var title: String

    public init(name: String, title: String? = nil) {
        self.name = name
        self.title = title ?? name
    }
}

public struct BuildingPart: Sendable, Decodable {
    public var osmId: String
    public var outline: [GeoCoordinate]
    public var holes: [[GeoCoordinate]]

    private enum CodingKeys: String, CodingKey {
        case osmId, outline, holes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        osmId = try container.decode(String.self, forKey: .osmId)
        outline = try GeoCoordinate.ring(container.decode([[Double]].self, forKey: .outline), at: [CodingKeys.outline])
        holes = try container.decode([[[Double]]].self, forKey: .holes).map {
            try GeoCoordinate.ring($0, at: [CodingKeys.holes])
        }
    }
}

public struct Door: Sendable, Decodable, Identifiable {
    public enum Kind: String, Sendable, Decodable {
        case main, entrance, exit, stairwell
    }

    public var id: String
    /// Code of the building the door belongs to.
    public var building: String
    public var name: String
    public var kind: Kind
    public var coordinate: GeoCoordinate
    /// Floor label as signed at the door, when known (e.g. "1", "B").
    public var level: String?
    /// Step-free access, when known.
    public var accessible: Bool?
    /// Checked on site (Tier 1).
    public var verified: Bool
    /// Photo paths relative to the bundle directory.
    public var photos: [String]

    private enum CodingKeys: String, CodingKey {
        case id, building, name, kind, coordinate, level, accessible, verified, photos
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        building = try container.decode(String.self, forKey: .building)
        name = try container.decode(String.self, forKey: .name)
        kind = try container.decode(Kind.self, forKey: .kind)
        coordinate = try GeoCoordinate.point(container.decode([Double].self, forKey: .coordinate), at: [CodingKeys.coordinate])
        level = try container.decodeIfPresent(String.self, forKey: .level)
        accessible = try container.decodeIfPresent(Bool.self, forKey: .accessible)
        verified = try container.decode(Bool.self, forKey: .verified)
        photos = try container.decode([String].self, forKey: .photos)
    }
}

/// A bridge, tunnel or indoor link joining two or more buildings.
public struct Connection: Sendable, Decodable, Identifiable {
    public enum Kind: String, Sendable, Decodable {
        case bridge, tunnel, link
    }

    /// Where it meets a building, and on which floor(s).
    public struct End: Sendable, Decodable, Equatable {
        public var building: String
        /// As signed in that building; two for a two-storey bridge, empty when not known yet.
        public var floors: [String]

        public init(building: String, floors: [String]) {
            self.building = building
            self.floors = floors
        }
    }

    /// A line the Path Map draws for it, from one building's edge to another's (or a junction).
    public struct Path: Sendable, Decodable {
        public var points: [GeoCoordinate]
        /// The end (index into `ends`) it starts and finishes at, or nil at a junction,
        /// like the middle of the ML–AL–EV1 tunnel's T.
        public var from: Int?
        public var to: Int?

        private enum CodingKeys: String, CodingKey { case points, from, to }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            points = try GeoCoordinate.ring(container.decode([[Double]].self, forKey: .points), at: [CodingKeys.points])
            from = try container.decodeIfPresent(Int.self, forKey: .from)
            to = try container.decodeIfPresent(Int.self, forKey: .to)
        }
    }

    public var id: String
    /// Codes of the buildings it joins.
    public var buildings: [String]
    public var kind: Kind
    public var name: String
    public var ends: [End]
    public var verified: Bool
    /// Temporarily unusable (construction, locked).
    public var closed: Bool
    /// Its lines on the Path Map. Empty when its route isn't mapped: it still exists,
    /// but nothing is drawn. Links between adjoining buildings have none of their own.
    public var paths: [Path]
}

extension GeoCoordinate {
    /// The bundle stores coordinates GeoJSON-style, as [longitude, latitude].
    static func point(_ pair: [Double], at path: [CodingKey]) throws -> GeoCoordinate {
        guard pair.count == 2 else {
            throw DecodingError.dataCorrupted(.init(codingPath: path, debugDescription: "Expected [lon, lat]"))
        }
        return GeoCoordinate(latitude: pair[1], longitude: pair[0])
    }

    static func ring(_ pairs: [[Double]], at path: [CodingKey]) throws -> [GeoCoordinate] {
        try pairs.map { try point($0, at: path) }
    }
}
