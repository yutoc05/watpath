import CampusGeo
import CampusModel
import Foundation
import Testing

@testable import Routing

/// Routes on the real map (build/CampusBundle, from `make data`). When the data changes,
/// these say whether the campus still routes the way someone who walks it would expect.
struct CampusRoutesTests {
    private static let directory = URL(filePath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../../build/CampusBundle")

    private static func loaded() throws -> Router? {
        // Quiet before the first `make data`, as CampusBundleTests is.
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("graph.json").path) else { return nil }
        return try Router(graph: WalkGraph.load(from: directory), campus: CampusBundle.load(from: directory))
    }

    private static func routes(_ router: Router, _ from: String, _ to: String) throws -> [Route] {
        try router.routes(from: #require(router.endpoint(building: from)), to: #require(router.endpoint(building: to)))
    }

    @Test func everyBuildingReachesEveryOther() throws {
        guard let router = try Self.loaded() else { return }
        let codes = router.graph.buildings.keys.sorted()
        #expect(codes.count == 38)
        for from in codes {
            for to in codes where from != to {
                #expect(try !Self.routes(router, from, to).isEmpty, "\(from) to \(to)")
            }
        }
    }

    @Test func everyDoorIsAPlaceToGo() throws {
        guard let router = try Self.loaded() else { return }
        let campus = try CampusBundle.load(from: Self.directory)
        let start = try #require(router.endpoint(building: "SLC"))
        for door in campus.doors {
            let end = try #require(router.endpoint(door: door.id), "\(door.id)")
            #expect(!router.routes(from: start, to: end).isEmpty, "\(door.id)")
        }
    }

    @Test func routesAreNeverBeatenAndAddUp() throws {
        guard let router = try Self.loaded() else { return }
        let codes = router.graph.buildings.keys.sorted()
        for from in codes {
            for to in codes where from != to {
                let routes = try Self.routes(router, from, to)
                #expect(routes.count <= 4)
                #expect(Set(routes.map(\.label)).count == routes.count)
                for route in routes {
                    #expect(abs(route.insideLength + route.outsideLength - route.distance) < 1e-6)
                    #expect(abs(route.spans.reduce(0) { $0 + $1.length } - route.distance) < 1e-6)
                    #expect(route.points.count >= 2)
                    #expect(!routes.contains { route.isBeaten(by: $0) }, "\(from) to \(to)")
                }
                for (a, b) in zip(routes, routes.dropFirst()) {
                    #expect(a.seconds <= b.seconds, "\(from) to \(to)")
                }
            }
        }
    }

    /// Weight 1 is plain shortest time, so nothing in the list may be quicker than it.
    @Test func fastestIsTrulyTheFastest() throws {
        guard let router = try Self.loaded() else { return }
        let search = PathSearch(graph: router.graph, model: router.model)
        for (from, to) in [("MC", "DC"), ("SLC", "E5"), ("PAC", "HH"), ("ML", "DWE"), ("NH", "E6")] {
            let start = try #require(router.endpoint(building: from))
            let end = try #require(router.endpoint(building: to))
            let walk = try #require(search.cheapestWalk(from: start, to: end, direct: nil, outsideWeight: 1))
            let routes = router.routes(from: start, to: end)
            let time = walk.hops.reduce(0.0) { total, hop in
                let edge = router.graph.edges[hop.edge]
                return total + edge.length / router.model.walkingSpeed + (edge.kind == .door ? router.model.doorSeconds : 0)
            } + walk.storeys * router.model.storeySeconds
            #expect(abs(try #require(routes.first).seconds - time) < 1e-6, "\(from) to \(to)")
        }
    }

    /// The bridge across to QNC and on through B2 stay indoors the whole way, which is
    /// the reason the app exists.
    @Test func thereIsAnAllIndoorWayAlongTheMainSpine() throws {
        guard let router = try Self.loaded() else { return }
        for (from, to) in [("MC", "QNC"), ("MC", "E3"), ("SLC", "E5"), ("SLC", "DWE"), ("QNC", "EIT"), ("NH", "E2"), ("C2", "E6")] {
            let routes = try Self.routes(router, from, to)
            #expect(try #require(routes.last).outsideLength == 0, "\(from) to \(to)")
        }
    }

    /// Buildings on either side of the gap between the networks can't be reached indoors.
    @Test func goingBetweenSeparateNetworksMeansGoingOutside() throws {
        guard let router = try Self.loaded() else { return }
        for (from, to) in [("MC", "EV1"), ("HH", "E5"), ("BMH", "SLC")] {
            let routes = try Self.routes(router, from, to)
            #expect(try #require(routes.last).outsideLength > 0, "\(from) to \(to)")
        }
    }

    /// Going to a building has to end at that building.
    @Test func everyArrivalPointIsAtItsBuilding() throws {
        guard let router = try Self.loaded() else { return }
        let campus = try CampusBundle.load(from: Self.directory)
        let plane = MapPlane(origin: campus.origin)
        for building in campus.buildings {
            let rings = building.parts.flatMap { part in ([part.outline] + part.holes).map { $0.map(plane.planar) } }
            let entry = try #require(router.graph.buildings[building.code])
            for anchor in entry.anchors {
                let point = plane.planar(router.graph.nodes[anchor])
                #expect(PolygonGeometry.contains(rings, point) || PolygonGeometry.distanceToEdges(rings, point) < 45, "\(building.code)")
            }
        }
    }

    /// Rough checks against walking times anyone at UW would recognize.
    @Test func walksTakeSensibleTimes() throws {
        guard let router = try Self.loaded() else { return }
        for (from, to, low, high) in [("MC", "DC", 1.5, 6.0), ("MC", "SLC", 1.0, 5.0), ("SLC", "E5", 5.0, 13.0), ("ML", "DWE", 4.0, 12.0), ("PAC", "PAS", 5.0, 13.0)] {
            let minutes = try #require(Self.routes(router, from, to).first).seconds / 60
            #expect(minutes > low && minutes < high, "\(from) to \(to): \(minutes)")
        }
    }

    @Test func aDoorThatOnlyLetsPeopleOutCantBeUsedToComeIn() throws {
        guard let router = try Self.loaded() else { return }
        let campus = try CampusBundle.load(from: Self.directory)
        let oneWay = router.graph.edges.filter(\.isOneWay)
        #expect(!oneWay.isEmpty)
        #expect(oneWay.allSatisfy { $0.kind == .door })
        #expect(oneWay.count <= campus.doors.filter { $0.kind == .exit }.count)
    }
}
