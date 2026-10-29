@testable import CampusSearch
import CampusModel
import Foundation
import Testing

struct SearchIndexTests {
    static let campus: CampusBundle = {
        let buildings: [(String, String, [String])] = [
            ("MC", "Mathematics & Computer", ["Math & Computer", "Math and Computer"]),
            ("M3", "Mathematics 3", ["Math 3"]),
            ("ML", "Modern Languages", []),
            ("DC", "William G. Davis Computer Research Centre", ["Davis Centre", "Davis"]),
            ("PSE", "Pearl Sullivan Engineering", ["E7", "Engineering 7"]),
            ("E5", "Engineering 5", []),
            ("E6", "Engineering 6", []),
            ("DP", "Dana Porter Library", ["Dana Porter"]),
            ("HH", "J.G. Hagey Hall of the Humanities", ["Hagey Hall"]),
            ("QNC", "Mike & Ophelia Lazaridis Quantum-Nano Centre", ["Quantum Nano Centre"]),
        ]
        let ring = "[[-80.544,43.472],[-80.543,43.472],[-80.543,43.473],[-80.544,43.472]]"
        let buildingJSON = buildings.map { code, name, aliases in
            let aliasList = aliases.map { "\"\($0)\"" }.joined(separator: ",")
            return """
            {"code":"\(code)","name":"\(name)","aliases":[\(aliasList)],"group":"core","priority":1,"levelHeight":4,
             "levelsEstimated":false,"floors":[{"name":"1","title":"Floor 1","elevation":0,"mapped":false}],"parts":[{"osmId":"way/1","levels":3,"outline":\(ring),"holes":[]}]}
            """
        }
        let doorJSON = """
        {"id":"MC-n1","building":"MC","name":"North main entrance","kind":"main","coordinate":[-80.5435,43.4729],
         "level":null,"accessible":null,"verified":false,"photos":[]}
        """
        let json = """
        {"schemaVersion":5,"origin":{"latitude":43.472,"longitude":-80.544},"attribution":"",
         "buildings":[\(buildingJSON.joined(separator: ","))],"doors":[\(doorJSON)],"connections":[],"popular":[]}
        """
        return try! CampusBundle.decode(Data(json.utf8))
    }()

    let index = SearchIndex(campus: campus)

    func top(_ query: String) -> PlaceReference? {
        index.search(query).first?.place
    }

    @Test(arguments: [
        ("mc", "MC"), ("MC", "MC"), ("davis", "DC"), ("davis centre", "DC"), ("e7", "PSE"), ("E 7", "PSE"),
        ("dp", "DP"), ("dana porter", "DP"), ("hagey", "HH"), ("quantum", "QNC"), ("engineering 5", "E5"),
        ("math 3", "M3"), ("math and computer", "MC"), ("modern lang", "ML"),
    ])
    func findsBuilding(query: String, code: String) {
        #expect(top(query) == .building(code: code), "\(query) → \(String(describing: top(query)))")
    }

    @Test(arguments: [("hagy hall", "HH"), ("quantm", "QNC"), ("engineerign 6", "E6"), ("libary", "DP")])
    func toleratesTypos(query: String, code: String) {
        #expect(top(query) == .building(code: code), "\(query) → \(String(describing: top(query)))")
    }

    @Test func findsDoorsByBuildingAndDirection() {
        #expect(top("mc north") == .door(id: "MC-n1"))
        #expect(top("math computer north entrance") == .door(id: "MC-n1"))
    }

    @Test func buildingOutranksItsDoorsForTheBuildingName() {
        let results = index.search("mathematics & computer")
        #expect(results.first?.place == .building(code: "MC"))
        #expect(results.contains { $0.place == .door(id: "MC-n1") })
    }

    @Test func singleLetterPutsCodePrefixesFirst() {
        let results = index.search("m")
        let codes = results.prefix(3).compactMap { result -> String? in
            if case .building(let code) = result.place { return code } else { return nil }
        }
        #expect(Set(codes) == ["MC", "M3", "ML"], "\(results.map(\.title))")
        // Word prefixes ("Mike & Ophelia…") may follow, but nothing reached by typo tolerance.
        #expect(!results.contains { $0.place == .building(code: "HH") })
    }

    @Test func nonsenseFindsNothing() {
        #expect(index.search("zzzz").isEmpty)
        #expect(index.search("   ").isEmpty)
    }

    @Test func editDistanceCountsTranspositionsAsOne() {
        #expect(SearchIndex.editDistance("libary", "library") == 1)
        #expect(SearchIndex.editDistance("engineerign", "engineering") == 1)
        #expect(SearchIndex.editDistance("kitten", "sitting") == 3)
    }
}

struct RecentListTests {
    @Test func newestFirstWithoutDuplicates() {
        var recents = RecentList<String>(capacity: 3)
        for place in ["MC", "DC", "SLC", "DC"] { recents.add(place) }
        #expect(recents.items == ["DC", "SLC", "MC"])
    }

    @Test func dropsOldestPastCapacity() {
        var recents = RecentList<String>(capacity: 2)
        for place in ["MC", "DC", "SLC"] { recents.add(place) }
        #expect(recents.items == ["SLC", "DC"])
    }

    @Test func survivesCoding() throws {
        var recents = RecentList<PlaceReference>()
        recents.add(.building(code: "MC"))
        recents.add(.door(id: "MC-n1"))
        let decoded = try JSONDecoder().decode(RecentList<PlaceReference>.self, from: JSONEncoder().encode(recents))
        #expect(decoded == recents)
    }
}
