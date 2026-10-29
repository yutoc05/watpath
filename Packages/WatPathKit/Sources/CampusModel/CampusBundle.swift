import CampusGeo
import Foundation

/// The compiled map data the app ships with (build/CampusBundle, produced by
/// tools/compiler). Schema v5: Tier 0 building shells with every floor they have,
/// which of those the Path Map shows and their corridors, doors,
/// building-to-building connections with the floor at each end, and Popular places.
public struct CampusBundle: Sendable, Decodable {
    public static let supportedSchemaVersion = 5

    public var schemaVersion: Int
    public var origin: GeoCoordinate
    public var attribution: String
    public var buildings: [Building]
    public var doors: [Door]
    public var connections: [Connection]
    public var popular: [PlaceReference]

    public enum LoadError: Error, Equatable {
        case unsupportedSchema(Int)
    }

    public static func load(from directory: URL) throws -> CampusBundle {
        let data = try Data(contentsOf: directory.appendingPathComponent("campus.json"))
        return try decode(data)
    }

    public static func decode(_ data: Data) throws -> CampusBundle {
        let bundle = try JSONDecoder().decode(CampusBundle.self, from: data)
        guard bundle.schemaVersion == supportedSchemaVersion else {
            throw LoadError.unsupportedSchema(bundle.schemaVersion)
        }
        return bundle
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

    /// Height of a connection's walking surface where it meets `end`, on `deck`
    /// (0 for the lowest floor of a multi-storey bridge). Ends without known floors
    /// meet the building at ground level.
    public func elevation(of connection: Connection, end: Int, deck: Int) -> Double {
        let end = connection.ends[end]
        guard let building = building(code: end.building) else { return 0 }
        let name = end.floors.isEmpty ? nil : end.floors[min(deck, end.floors.count - 1)]
        return (name.flatMap(building.floor(named:)) ?? building.groundFloor)?.elevation ?? 0
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
    /// Tier 2 fill-in order, 1 (first) to 6.
    public var priority: Int
    /// Floor-to-floor height in meters.
    public var levelHeight: Double
    /// True when no source gave a level count and the compiler guessed.
    public var levelsEstimated: Bool
    /// Every floor the building has, bottom to top. Never empty.
    public var floors: [Floor]
    public var parts: [BuildingPart]
    /// The Path Map floor shown until the user picks another, if it shows any.
    public var defaultFloorIndex: Int?
    /// Where the Path Map puts the building's label, when the data places it by
    /// hand; otherwise the app picks the widest point inside.
    public var label: GeoCoordinate?

    public var id: String { code }

    private enum CodingKeys: String, CodingKey {
        case code, name, aliases, group, priority, levelHeight, levelsEstimated, floors, parts, label, defaultFloor
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        code = try container.decode(String.self, forKey: .code)
        name = try container.decode(String.self, forKey: .name)
        aliases = try container.decode([String].self, forKey: .aliases)
        group = try container.decode(Group.self, forKey: .group)
        priority = try container.decode(Int.self, forKey: .priority)
        levelHeight = try container.decode(Double.self, forKey: .levelHeight)
        levelsEstimated = try container.decode(Bool.self, forKey: .levelsEstimated)
        floors = try container.decode([Floor].self, forKey: .floors)
        parts = try container.decode([BuildingPart].self, forKey: .parts)
        label = try container.decodeIfPresent([Double].self, forKey: .label).map {
            try GeoCoordinate.point($0, at: [CodingKeys.label])
        }
        let defaultFloor = try container.decodeIfPresent(String.self, forKey: .defaultFloor)
        defaultFloorIndex = floors.firstIndex { $0.name == defaultFloor }
    }

    /// The floors the Path Map can show: only those a bridge, tunnel or link meets.
    public var mappedFloorIndices: [Int] { floors.indices.filter { floors[$0].isMapped } }

    /// Floor 1, or the lowest floor if there's no floor 1: where doors usually are.
    public var groundFloor: Floor? { floor(named: "1") ?? floors.first }

    public func floor(named name: String) -> Floor? {
        floors.first { $0.name == name }
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

/// The hallways on one floor, merged into one walkable area.
public struct Corridor: Sendable, Decodable, Equatable {
    /// The floor area, as triangles of three points.
    public var triangles: [[GeoCoordinate]]
    /// Wall lines along its sides; open where a hallway ends at a door, stairs or bridge.
    public var walls: [[GeoCoordinate]]

    public init(triangles: [[GeoCoordinate]], walls: [[GeoCoordinate]]) {
        self.triangles = triangles
        self.walls = walls
    }

    private enum CodingKeys: String, CodingKey { case triangles, walls }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        triangles = try container.decode([[[Double]]].self, forKey: .triangles).map { try GeoCoordinate.ring($0, at: [CodingKeys.triangles]) }
        walls = try container.decode([[[Double]]].self, forKey: .walls).map { try GeoCoordinate.ring($0, at: [CodingKeys.walls]) }
        guard triangles.allSatisfy({ $0.count == 3 }) else {
            throw DecodingError.dataCorrupted(.init(codingPath: [CodingKeys.triangles], debugDescription: "Triangles need three points"))
        }
    }
}

/// One storey of a building.
public struct Floor: Sendable, Decodable, Equatable {
    /// Short, as on the floor picker: "1", "B" (basement), "2M" (2nd-floor mezzanine), "P" (penthouse).
    public var name: String
    /// In full: "Floor 1", "Basement", "2nd floor mezzanine", "Penthouse".
    public var title: String
    /// Height of the floor surface above the campus ground plane, in meters.
    /// Solved from the floors bridges and tunnels meet, so they line up across buildings.
    public var elevation: Double
    /// Shown on the Path Map: a bridge, tunnel or link meets it. Other floors are never drawn.
    public var isMapped: Bool
    /// The hallways people walk on this floor, when mapped.
    public var corridor: Corridor?

    public init(name: String, title: String? = nil, elevation: Double, isMapped: Bool = true, corridor: Corridor? = nil) {
        self.name = name
        self.title = title ?? name
        self.elevation = elevation
        self.isMapped = isMapped
        self.corridor = corridor
    }

    private enum CodingKeys: String, CodingKey {
        case name, title, elevation, isMapped = "mapped", corridor
    }

    /// The basement, a midlevel basement, a lower level or a concourse.
    public var isBelowGround: Bool { ["B", "MB", "LL", "C"].contains(name) || (Int(name).map { $0 < 1 } ?? false) }
}

public struct BuildingPart: Sendable, Decodable {
    public var osmId: String
    /// Floors above ground: a part shows on floors 1…levels (and on basements).
    public var levels: Int
    public var outline: [GeoCoordinate]
    public var holes: [[GeoCoordinate]]

    private enum CodingKeys: String, CodingKey {
        case osmId, levels, outline, holes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        osmId = try container.decode(String.self, forKey: .osmId)
        levels = try container.decode(Int.self, forKey: .levels)
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

    /// A piece of the walkway's center line and the ends it runs between.
    public struct Path: Sendable, Decodable {
        public var points: [GeoCoordinate]
        /// Indexes into `ends`.
        public var from: Int
        public var to: Int

        private enum CodingKeys: String, CodingKey { case points, from, to }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            points = try GeoCoordinate.ring(container.decode([[Double]].self, forKey: .points), at: [CodingKeys.points])
            from = try container.decode(Int.self, forKey: .from)
            to = try container.decode(Int.self, forKey: .to)
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
    public var paths: [Path]

    /// Storeys of walkway: 2 for a bridge listed as floors "2,3" at each end.
    public var deckCount: Int { max(1, ends.map(\.floors.count).max() ?? 1) }
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
