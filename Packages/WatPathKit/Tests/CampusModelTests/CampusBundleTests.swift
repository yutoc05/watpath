import CampusModel
import Foundation
import Testing

struct CampusBundleTests {
    let json = """
    {"schemaVersion":1,"origin":{"latitude":43.472,"longitude":-80.544},"attribution":"© OpenStreetMap contributors",
     "buildings":[{"code":"MC","name":"Mathematics & Computer","aliases":["Math & Computer"],"group":"core","priority":1,
       "levelHeight":4.0,"groundElevation":0.0,"levelsEstimated":false,
       "parts":[{"osmId":"way/1","levels":7,"outline":[[-80.544,43.472],[-80.543,43.472],[-80.543,43.473],[-80.544,43.472]],"holes":[]}]}],
     "doors":[{"id":"MC-n1","building":"MC","name":"North main entrance","kind":"main","coordinate":[-80.5435,43.4729],
       "level":"1","accessible":true,"verified":false,"photos":[]},
      {"id":"MC-n2","building":"MC","name":"South exit","kind":"exit","coordinate":[-80.5436,43.4721],
       "level":null,"accessible":null,"verified":false,"photos":["photos/MC-n2/a.jpg"]}],
     "popular":[{"kind":"building","id":"MC"},{"kind":"door","id":"MC-n1"}]}
    """

    @Test func decodesBuildingsWithLonLatRings() throws {
        let bundle = try CampusBundle.decode(Data(json.utf8))
        let mc = try #require(bundle.building(code: "MC"))
        #expect(mc.group == .core)
        #expect(mc.levelCount == 7)
        #expect(mc.parts[0].outline[1] == .init(latitude: 43.472, longitude: -80.543))
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
        let old = json.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":0")
        #expect(throws: CampusBundle.LoadError.unsupportedSchema(0)) {
            try CampusBundle.decode(Data(old.utf8))
        }
    }

    @Test func compiledBundleInRepoLoads() throws {
        // build/CampusBundle exists after `make data`; skip quietly before that.
        let root = URL(filePath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../../build/CampusBundle")
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("campus.json").path) else { return }
        let bundle = try CampusBundle.load(from: root)
        #expect(bundle.buildings.count == 49)
        #expect(bundle.buildings.allSatisfy { !$0.parts.isEmpty && $0.parts.allSatisfy { $0.outline.count >= 4 } })
        #expect(bundle.doors.allSatisfy { bundle.building(code: $0.building) != nil })
    }
}
