import CampusGeo
import CampusModel
import Foundation
import Testing

struct CampusBundleTests {
    let json = """
    {"schemaVersion":8,"origin":{"latitude":43.472,"longitude":-80.544},"attribution":"© OpenStreetMap contributors",
     "buildings":[{"code":"MC","name":"Mathematics & Computer","aliases":["Math & Computer"],"group":"core","priority":1,
       "levelsEstimated":false,"label":[-80.5436,43.4723],
       "floors":[{"name":"B","title":"Basement"},{"name":"1","title":"Floor 1"},{"name":"2","title":"Floor 2"},{"name":"3","title":"Floor 3"}],
       "parts":[{"osmId":"way/1","outline":[[-80.544,43.472],[-80.543,43.472],[-80.543,43.473],[-80.544,43.472]],"holes":[]}]}],
     "corridors":[[[-80.5436,43.4723],[-80.5435,43.4723],[-80.5435,43.4724]]],
     "doors":[{"id":"MC-n1","building":"MC","name":"North main entrance","kind":"main","coordinate":[-80.5435,43.4729],
       "level":"1","accessible":true,"verified":false,"photos":[]},
      {"id":"MC-n2","building":"MC","name":"South exit","kind":"exit","coordinate":[-80.5436,43.4721],
       "level":null,"accessible":null,"verified":false,"photos":["photos/MC-n2/a.jpg"]}],
     "connections":[{"id":"conn-w1","buildings":["MC","QNC"],"kind":"bridge","name":"MC to QNC Walkway",
       "ends":[{"building":"MC","floors":["3"]},{"building":"QNC","floors":["2"]}],
       "verified":true,"closed":false,"paths":[{"points":[[-80.5440,43.4718],[-80.5441,43.4716]],"from":0,"to":1},
         {"points":[[-80.5440,43.4718],[-80.5442,43.4718]],"from":0,"to":null}]}],
     "popular":[{"kind":"building","id":"MC"},{"kind":"door","id":"MC-n1"}]}
    """

    @Test func decodesBuildingsWithLonLatRings() throws {
        let bundle = try CampusBundle.decode(Data(json.utf8))
        let mc = try #require(bundle.building(code: "MC"))
        #expect(mc.group == .core)
        #expect(mc.parts[0].outline[1] == .init(latitude: 43.472, longitude: -80.543))
        #expect(mc.label == .init(latitude: 43.4723, longitude: -80.5436))
    }

    @Test func decodesFloorsBottomToTop() throws {
        let mc = try #require(CampusBundle.decode(Data(json.utf8)).building(code: "MC"))
        #expect(mc.floors.map(\.name) == ["B", "1", "2", "3"])
        #expect(mc.floors.map(\.title) == ["Basement", "Floor 1", "Floor 2", "Floor 3"])
        #expect(mc.floorSummary == "Basement, 1–3")
    }

    @Test func decodesCorridorsAsLines() throws {
        let bundle = try CampusBundle.decode(Data(json.utf8))
        #expect(bundle.corridors.count == 1)
        #expect(bundle.corridors[0].count == 3)
        #expect(bundle.corridors[0][0] == .init(latitude: 43.4723, longitude: -80.5436))
    }

    @Test func decodesDoorsAndLinksThemToBuildings() throws {
        let bundle = try CampusBundle.decode(Data(json.utf8))
        let mc = try #require(bundle.building(code: "MC"))
        #expect(bundle.doors(of: mc).map(\.id) == ["MC-n1", "MC-n2"])
        let exit = try #require(bundle.door(id: "MC-n2"))
        #expect(exit.kind == .exit)
        #expect(exit.level == nil && exit.accessible == nil)
        #expect(exit.coordinate == .init(latitude: 43.4721, longitude: -80.5436))
        #expect(exit.photos == ["photos/MC-n2/a.jpg"])
    }

    @Test func decodesConnections() throws {
        let bundle = try CampusBundle.decode(Data(json.utf8))
        let walkway = try #require(bundle.connections.first)
        #expect(walkway.buildings == ["MC", "QNC"])
        #expect(walkway.kind == .bridge)
        #expect(walkway.ends == [.init(building: "MC", floors: ["3"]), .init(building: "QNC", floors: ["2"])])
        #expect(walkway.paths[0].points == [.init(latitude: 43.4718, longitude: -80.5440), .init(latitude: 43.4716, longitude: -80.5441)])
        #expect(walkway.paths[0].from == 0 && walkway.paths[0].to == 1)
        #expect(walkway.paths[1].to == nil, "a junction belongs to no building")
    }

    @Test func decodesPopularPlaces() throws {
        let bundle = try CampusBundle.decode(Data(json.utf8))
        #expect(bundle.popular == [.building(code: "MC"), .door(id: "MC-n1")])
    }

    @Test func placeReferencesRoundTripThroughJSON() throws {
        let places: [PlaceReference] = [.building(code: "DC"), .door(id: "DC-n7")]
        let decoded = try JSONDecoder().decode([PlaceReference].self, from: JSONEncoder().encode(places))
        #expect(decoded == places)
    }

    @Test func rejectsOtherSchemaVersions() {
        let old = json.replacingOccurrences(of: "\"schemaVersion\":8", with: "\"schemaVersion\":7")
        #expect(throws: CampusBundle.LoadError.unsupportedSchema(7)) {
            try CampusBundle.decode(Data(old.utf8))
        }
    }

    @Test func compiledBundleInRepoLoads() throws {
        // build/CampusBundle exists after `make data`; skip quietly before that.
        let root = URL(filePath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../../build/CampusBundle")
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("campus.json").path) else { return }
        let bundle = try CampusBundle.load(from: root)
        #expect(bundle.buildings.count == 38)
        #expect(bundle.buildings.allSatisfy { !$0.parts.isEmpty && $0.parts.allSatisfy { $0.outline.count >= 4 } })
        #expect(bundle.buildings.allSatisfy { !$0.floors.isEmpty })
        // Basements are always "B".
        #expect(!bundle.buildings.contains { $0.floors.contains { $0.name == "0" } })
        #expect(bundle.doors.allSatisfy { bundle.building(code: $0.building) != nil })
        #expect(bundle.connections.allSatisfy { $0.buildings.allSatisfy { bundle.building(code: $0) != nil } })
        // Every floor a connection meets exists.
        for connection in bundle.connections {
            for end in connection.ends {
                #expect(end.floors.allSatisfy { name in bundle.building(code: end.building)?.floors.contains { $0.name == name } == true }, "\(connection.id)")
            }
        }
        // Links are part of the white lines; a bridge or tunnel draws its own, unless
        // its route isn't known.
        #expect(bundle.corridors.allSatisfy { $0.count >= 2 })
        let drawn = bundle.connections.filter { $0.kind != .link }
        #expect(drawn.filter(\.paths.isEmpty).map(\.id) == ["conn-esc-eit-tunnel"])
        #expect(bundle.connections.filter { $0.kind == .link }.allSatisfy { $0.paths.isEmpty })
        // Every line joins the network: each end of a bridge or tunnel meets a corridor
        // or another bridge or tunnel, so none floats on its own.
        let plane = MapPlane(origin: bundle.origin)
        let lines = bundle.corridors + drawn.flatMap { $0.paths.map(\.points) }
        func touchesAnotherLine(_ point: GeoCoordinate, excluding own: [GeoCoordinate]) -> Bool {
            lines.contains { line in
                line != own && zip(line, line.dropFirst()).contains { a, b in
                    PolygonGeometry.distanceToEdges([[plane.planar(a), plane.planar(b)]], plane.planar(point)) < 0.5
                }
            }
        }
        for connection in drawn {
            for path in connection.paths {
                for tip in [path.points[0], path.points[path.points.count - 1]] {
                    #expect(touchesAnotherLine(tip, excluding: path.points), "\(connection.id) at \(tip)")
                }
            }
        }
        // Every end of a drawn bridge or tunnel has a line ending there for its floor numbers.
        for connection in drawn where !connection.paths.isEmpty {
            for end in connection.ends.indices {
                #expect(connection.paths.contains { $0.from == end || $0.to == end }, "\(connection.id) end \(end)")
            }
        }
    }
}
