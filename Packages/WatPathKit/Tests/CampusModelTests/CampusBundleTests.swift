import CampusModel
import Foundation
import Testing

struct CampusBundleTests {
    let json = """
    {"schemaVersion":0,"origin":{"latitude":43.472,"longitude":-80.544},"attribution":"© OpenStreetMap contributors",
     "buildings":[{"code":"MC","name":"Mathematics & Computer","aliases":["Math & Computer"],"group":"core","priority":1,
       "levelHeight":4.0,"groundElevation":0.0,"levelsEstimated":false,
       "parts":[{"osmId":"way/1","levels":7,"outline":[[-80.544,43.472],[-80.543,43.472],[-80.543,43.473],[-80.544,43.472]],"holes":[]}]}]}
    """

    @Test func decodesBuildingsWithLonLatRings() throws {
        let bundle = try CampusBundle.decode(Data(json.utf8))
        let mc = try #require(bundle.building(code: "MC"))
        #expect(mc.group == .core)
        #expect(mc.parts[0].levels == 7)
        #expect(mc.parts[0].outline[1] == .init(latitude: 43.472, longitude: -80.543))
    }

    @Test func rejectsOtherSchemaVersions() {
        let future = json.replacingOccurrences(of: "\"schemaVersion\":0", with: "\"schemaVersion\":9")
        #expect(throws: CampusBundle.LoadError.unsupportedSchema(9)) {
            try CampusBundle.decode(Data(future.utf8))
        }
    }

    @Test func compiledBundleInRepoLoads() throws {
        // build/CampusBundle exists after `make data`; skip quietly before that.
        let root = URL(filePath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../../build/CampusBundle")
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("buildings.json").path) else { return }
        let bundle = try CampusBundle.load(from: root)
        #expect(bundle.buildings.count == 49)
        #expect(bundle.buildings.allSatisfy { !$0.parts.isEmpty && $0.parts.allSatisfy { $0.outline.count >= 4 } })
    }
}
