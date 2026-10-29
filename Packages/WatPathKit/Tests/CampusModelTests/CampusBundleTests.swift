import CampusModel
import Foundation
import Testing

struct CampusBundleTests {
    let json = """
    {"schemaVersion":5,"origin":{"latitude":43.472,"longitude":-80.544},"attribution":"© OpenStreetMap contributors",
     "buildings":[{"code":"MC","name":"Mathematics & Computer","aliases":["Math & Computer"],"group":"core","priority":1,
       "levelHeight":4.0,"levelsEstimated":false,"label":[-80.5436,43.4723],"defaultFloor":"3",
       "floors":[{"name":"B","title":"Basement","elevation":-8.6,"mapped":false},
         {"name":"1","title":"Floor 1","elevation":-4.6,"mapped":false},{"name":"2","title":"Floor 2","elevation":-0.6,"mapped":false},
         {"name":"3","title":"Floor 3","elevation":3.4,"mapped":true,"corridor":{"triangles":[[[-80.5436,43.4723],[-80.5435,43.4723],[-80.5435,43.4724]]],
           "walls":[[[-80.5436,43.4723],[-80.5435,43.4723]]]}}],
       "parts":[{"osmId":"way/1","levels":3,"outline":[[-80.544,43.472],[-80.543,43.472],[-80.543,43.473],[-80.544,43.472]],"holes":[]}]}],
     "doors":[{"id":"MC-n1","building":"MC","name":"North main entrance","kind":"main","coordinate":[-80.5435,43.4729],
       "level":"1","accessible":true,"verified":false,"photos":[]},
      {"id":"MC-n2","building":"MC","name":"South exit","kind":"exit","coordinate":[-80.5436,43.4721],
       "level":null,"accessible":null,"verified":false,"photos":["photos/MC-n2/a.jpg"]}],
     "connections":[{"id":"conn-w1","buildings":["MC","QNC"],"kind":"bridge","name":"MC to QNC Walkway",
       "ends":[{"building":"MC","floors":["3"]},{"building":"QNC","floors":["2"]}],
       "verified":true,"closed":false,"paths":[{"points":[[-80.5440,43.4718],[-80.5441,43.4716]],"from":0,"to":1}]}],
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
        #expect(mc.floor(named: "3")?.elevation == 3.4)
        // Only floor 3 is on the Path Map (a bridge meets it), and it's where MC starts.
        #expect(mc.mappedFloorIndices == [3] && mc.defaultFloorIndex == 3)
        #expect(mc.groundFloor?.name == "1")
        #expect(mc.floorSummary == "Basement, 1–3")
        #expect(mc.floors[0].corridor == nil)
        let corridor = try #require(mc.floors[3].corridor)
        #expect(corridor.triangles.count == 1 && corridor.triangles[0].count == 3)
        #expect(corridor.walls == [[.init(latitude: 43.4723, longitude: -80.5436), .init(latitude: 43.4723, longitude: -80.5435)]])
        #expect(Floor(name: "B", elevation: -4).isBelowGround && Floor(name: "MB", elevation: -2).isBelowGround)
        #expect(!Floor(name: "1", elevation: 0).isBelowGround && !Floor(name: "P", elevation: 30).isBelowGround)
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
        #expect(walkway.kind == .bridge && walkway.deckCount == 1)
        #expect(walkway.ends == [.init(building: "MC", floors: ["3"]), .init(building: "QNC", floors: ["2"])])
        #expect(walkway.paths[0].points == [.init(latitude: 43.4718, longitude: -80.5440), .init(latitude: 43.4716, longitude: -80.5441)])
        #expect(walkway.paths[0].from == 0 && walkway.paths[0].to == 1)
    }

    @Test func connectionsMeetTheirEndsFloors() throws {
        let bundle = try CampusBundle.decode(Data(json.utf8))
        let walkway = try #require(bundle.connections.first)
        #expect(bundle.elevation(of: walkway, end: 0, deck: 0) == 3.4)  // MC floor 3
        #expect(bundle.elevation(of: walkway, end: 0, deck: 1) == 3.4)  // a single-storey end keeps its floor
        #expect(bundle.elevation(of: walkway, end: 1, deck: 0) == 0)    // QNC isn't in this bundle
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
        let old = json.replacingOccurrences(of: "\"schemaVersion\":5", with: "\"schemaVersion\":4")
        #expect(throws: CampusBundle.LoadError.unsupportedSchema(4)) {
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
        // Buildings start on a floor the map shows; those no connection reaches show none.
        for building in bundle.buildings {
            if let index = building.defaultFloorIndex {
                #expect(building.floors[index].isMapped, "\(building.code)")
            } else {
                #expect(building.mappedFloorIndices.isEmpty, "\(building.code)")
            }
        }
        // Basements are always "B".
        #expect(!bundle.buildings.contains { $0.floors.contains { $0.name == "0" } })
        // Every floor a bridge, tunnel or link meets has a corridor leading on from it.
        for connection in bundle.connections {
            for end in connection.ends {
                for floor in end.floors {
                    #expect(bundle.building(code: end.building)?.floor(named: floor)?.corridor != nil, "\(end.building) floor \(floor)")
                }
            }
        }
        #expect(bundle.doors.allSatisfy { bundle.building(code: $0.building) != nil })
        #expect(bundle.connections.allSatisfy { $0.buildings.allSatisfy { bundle.building(code: $0) != nil } })
        // Every floor a connection meets exists, and both ends of each deck are level.
        for connection in bundle.connections {
            for end in connection.ends {
                #expect(end.floors.allSatisfy { bundle.building(code: end.building)?.floor(named: $0) != nil }, "\(connection.id)")
            }
            guard connection.ends.allSatisfy({ !$0.floors.isEmpty }) else { continue }
            for deck in 0..<connection.deckCount {
                let heights = connection.ends.indices.map { bundle.elevation(of: connection, end: $0, deck: deck) }
                #expect((heights.max() ?? 0) - (heights.min() ?? 0) < 0.5, "\(connection.id) deck \(deck): \(heights)")
            }
        }
    }
}
