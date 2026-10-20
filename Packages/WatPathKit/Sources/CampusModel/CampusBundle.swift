import CampusGeo
import Foundation

/// The compiled map data the app ships with (build/CampusBundle, produced by
/// tools/compiler). Schema v1: Tier 0 building shells, doors and Popular places.
public struct CampusBundle: Sendable, Decodable {
    public static let supportedSchemaVersion = 1

    public var schemaVersion: Int
    public var origin: GeoCoordinate
    public var attribution: String
    public var buildings: [Building]
    public var doors: [Door]
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
        case core, eastCampus, athletics
    }

    public var code: String
    public var name: String
    public var aliases: [String]
    public var group: Group
    /// Tier 2 fill-in order, 1 (first) to 6.
    public var priority: Int
    /// Floor-to-floor height in meters.
    public var levelHeight: Double
    /// Height of the ground floor above the campus ground plane, in meters.
    public var groundElevation: Double
    /// True when no source gave a level count and the compiler guessed.
    public var levelsEstimated: Bool
    public var parts: [BuildingPart]

    public var id: String { code }

    public var levelCount: Int { parts.map(\.levels).max() ?? 1 }
}

public struct BuildingPart: Sendable, Decodable {
    public var osmId: String
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
