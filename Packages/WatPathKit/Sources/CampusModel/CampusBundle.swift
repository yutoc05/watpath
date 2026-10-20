import CampusGeo
import Foundation

/// The compiled map data the app ships with (build/CampusBundle, produced by
/// tools/compiler). Schema v0 carries Tier 0 building shells only.
public struct CampusBundle: Sendable, Decodable {
    public static let supportedSchemaVersion = 0

    public var schemaVersion: Int
    public var origin: GeoCoordinate
    public var attribution: String
    public var buildings: [Building]

    public enum LoadError: Error, Equatable {
        case unsupportedSchema(Int)
    }

    public static func load(from directory: URL) throws -> CampusBundle {
        let data = try Data(contentsOf: directory.appendingPathComponent("buildings.json"))
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
        outline = try Self.ring(container.decode([[Double]].self, forKey: .outline), at: [CodingKeys.outline])
        holes = try container.decode([[[Double]]].self, forKey: .holes).map {
            try Self.ring($0, at: [CodingKeys.holes])
        }
    }

    /// Rings are stored GeoJSON-style as [longitude, latitude] pairs.
    private static func ring(_ pairs: [[Double]], at path: [CodingKey]) throws -> [GeoCoordinate] {
        try pairs.map { pair in
            guard pair.count == 2 else {
                throw DecodingError.dataCorrupted(.init(codingPath: path, debugDescription: "Expected [lon, lat]"))
            }
            return GeoCoordinate(latitude: pair[1], longitude: pair[0])
        }
    }
}
