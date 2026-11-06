import CampusGeo
import CampusModel
import Foundation
import Testing

@testable import Routing

/// Hand-built graphs with answers worked out by hand. Nodes sit on a grid of 0.001°
/// squares near the campus origin, but what matters is the lengths given to each edge.
struct RouterTests {
    private static let origin = GeoCoordinate(latitude: 43.47, longitude: -80.54)

    private static func node(_ x: Double, _ y: Double) -> GeoCoordinate {
        GeoCoordinate(latitude: origin.latitude + y * 0.001, longitude: origin.longitude + x * 0.001)
    }

    private static func campus() throws -> CampusBundle {
        try CampusBundle.decode(Data("""
        {"schemaVersion":\(CampusBundle.supportedSchemaVersion),"origin":{"latitude":43.47,"longitude":-80.54},"attribution":"",
        "buildings":[],"corridors":[],"dividers":[],"doors":[],"connections":[],"popular":[]}
        """.utf8))
    }

    private static func router(_ nodes: [GeoCoordinate], _ edges: [WalkGraph.Edge], model: TimeModel = .standard) throws -> Router {
        try Router(graph: WalkGraph(nodes: nodes, edges: edges), campus: campus(), model: model)
    }

    private static func at(_ node: Int) -> Endpoint {
        Endpoint(coordinate: .init(latitude: 0, longitude: 0), attachments: [.init(node: node, points: [], inside: 0, outside: 0, kind: .corridor)])
    }

    /// Two ways from 0 to 3: over the top (0-1-3), outside and short, or along the
    /// bottom (0-2-3), inside and long.
    private static func square(outside: Double, inside: Double) -> ([GeoCoordinate], [WalkGraph.Edge]) {
        (
            [node(0, 0), node(1, 1), node(1, -1), node(2, 0)],
            [
                .init(a: 0, b: 1, kind: .outdoor, length: outside / 2),
                .init(a: 1, b: 3, kind: .outdoor, length: outside / 2),
                .init(a: 0, b: 2, kind: .corridor, length: inside / 2),
                .init(a: 2, b: 3, kind: .corridor, length: inside / 2),
            ]
        )
    }

    @Test func offersTheFastestAndTheMostIndoorRoutes() throws {
        let (nodes, edges) = Self.square(outside: 100, inside: 180)
        let routes = try Self.router(nodes, edges).routes(from: Self.at(0), to: Self.at(3))
        #expect(routes.map(\.label) == [.fastest, .mostIndoor])
        #expect(routes[0].outsideLength == 100 && routes[0].insideLength == 0)
        #expect(routes[1].outsideLength == 0 && routes[1].insideLength == 180)
        #expect(abs(routes[0].seconds - 100 / 1.3) < 1e-9)
        #expect(routes[1].insideFraction == 1)
        #expect(routes[0].insideFraction == 0)
    }

    @Test func oneRouteWhenNothingBeatsIt() throws {
        // The indoor way is shorter too, so nothing is traded for anything.
        let (nodes, edges) = Self.square(outside: 200, inside: 100)
        let routes = try Self.router(nodes, edges).routes(from: Self.at(0), to: Self.at(3))
        #expect(routes.map(\.label) == [.best])
        #expect(routes[0].outsideLength == 0)
    }

    @Test func aRouteBeatenOnBothCountsIsDropped() throws {
        // 0-1-3 is outside and slower than the indoor way, so even with outside time
        // free of weight it can't appear.
        let (nodes, edges) = Self.square(outside: 500, inside: 400)
        let routes = try Self.router(nodes, edges).routes(from: Self.at(0), to: Self.at(3))
        #expect(routes.count == 1 && routes[0].outsideLength == 0)
    }

    @Test func noRouteAcrossAGap() throws {
        let nodes = [Self.node(0, 0), Self.node(1, 0), Self.node(2, 0)]
        let router = try Self.router(nodes, [.init(a: 0, b: 1, kind: .outdoor, length: 10)])
        #expect(router.routes(from: Self.at(0), to: Self.at(2)).isEmpty)
    }

    @Test func aOneWayEdgeOnlyGoesOneWay() throws {
        let nodes = [Self.node(0, 0), Self.node(1, 0)]
        let router = try Self.router(nodes, [.init(a: 0, b: 1, kind: .door, length: 10, isOneWay: true)])
        #expect(router.routes(from: Self.at(0), to: Self.at(1)).count == 1)
        #expect(router.routes(from: Self.at(1), to: Self.at(0)).isEmpty)
    }

    @Test func passingThroughADoorTakesTime() throws {
        let nodes = [Self.node(0, 0), Self.node(1, 0)]
        let router = try Self.router(nodes, [.init(a: 0, b: 1, kind: .door, length: 13)])
        let route = try #require(router.routes(from: Self.at(0), to: Self.at(1)).first)
        #expect(abs(route.seconds - (10 + TimeModel.standard.doorSeconds)) < 1e-9)
    }

    // MARK: Floors

    /// A bridge onto floor 3 at node 1, a corridor (no floors) from 1 to 2, and a bridge
    /// from floor `next` at node 2.
    private static func twoBridges(next: Double) throws -> Router {
        try router(
            [node(0, 0), node(1, 0), node(2, 0), node(3, 0)],
            [
                .init(a: 0, b: 1, kind: .bridge, length: 10, floors: [.init(enter: 2, exit: 3)]),
                .init(a: 1, b: 2, kind: .corridor, length: 10),
                .init(a: 2, b: 3, kind: .bridge, length: 10, floors: [.init(enter: next, exit: 1)]),
            ]
        )
    }

    @Test func stairsBetweenTwoConnectionsAreCharged() throws {
        let level = try #require(Self.twoBridges(next: 3).routes(from: Self.at(0), to: Self.at(3)).first)
        let climbing = try #require(Self.twoBridges(next: 1).routes(from: Self.at(0), to: Self.at(3)).first)
        #expect(level.storeys == 0)
        #expect(climbing.storeys == 2)
        #expect(abs(climbing.seconds - level.seconds - 2 * TimeModel.standard.storeySeconds) < 1e-9)
    }

    @Test func aTwoStoreyBridgeUsesWhicheverFloorIsCloser() throws {
        let router = try Self.router(
            [Self.node(0, 0), Self.node(1, 0), Self.node(2, 0), Self.node(3, 0)],
            [
                .init(a: 0, b: 1, kind: .bridge, length: 10, floors: [.init(enter: 1, exit: 3)]),
                .init(a: 1, b: 2, kind: .bridge, length: 10, floors: [.init(enter: 2, exit: 2), .init(enter: 3, exit: 3)]),
                .init(a: 2, b: 3, kind: .bridge, length: 10, floors: [.init(enter: 3, exit: 1)]),
            ]
        )
        let route = try #require(router.routes(from: Self.at(0), to: Self.at(3)).first)
        #expect(route.storeys == 0)  // floor 3 all the way across
    }

    @Test func floorsAreReadBackwardsWhenWalkedBackwards() throws {
        let route = try #require(Self.twoBridges(next: 1).routes(from: Self.at(3), to: Self.at(0)).first)
        #expect(route.storeys == 2)
    }

    @Test func unknownFloorsCostNothing() throws {
        let router = try Self.router(
            [Self.node(0, 0), Self.node(1, 0), Self.node(2, 0)],
            [
                .init(a: 0, b: 1, kind: .door, length: 10, floors: [.init(enter: nil, exit: nil)]),
                .init(a: 1, b: 2, kind: .bridge, length: 10, floors: [.init(enter: 3, exit: 3)]),
            ]
        )
        let route = try #require(router.routes(from: Self.at(0), to: Self.at(2)).first)
        #expect(route.storeys == 0)
    }

    @Test func goingOutsideForgetsTheFloor() throws {
        // Off a floor 3 bridge, out through a door and in through another, then onto a
        // floor 1 bridge. Nobody climbed anything indoors.
        let router = try Self.router(
            (0...5).map { Self.node(Double($0), 0) },
            [
                .init(a: 0, b: 1, kind: .bridge, length: 10, floors: [.init(enter: 3, exit: 3)]),
                .init(a: 1, b: 2, kind: .door, length: 1, floors: [.init(enter: nil, exit: nil)]),
                .init(a: 2, b: 3, kind: .outdoor, length: 10),
                .init(a: 3, b: 4, kind: .door, length: 1, floors: [.init(enter: nil, exit: nil)]),
                .init(a: 4, b: 5, kind: .bridge, length: 10, floors: [.init(enter: 1, exit: 1)]),
            ]
        )
        let route = try #require(router.routes(from: Self.at(0), to: Self.at(5)).first)
        #expect(route.storeys == 0)
    }

    @Test func theStairsCanMakeAnotherRouteFaster() throws {
        // A short way that needs three storeys of stairs against a level way 30 m longer.
        let router = try Self.router(
            [Self.node(0, 0), Self.node(1, 0), Self.node(2, 0), Self.node(1, 1)],
            [
                .init(a: 0, b: 1, kind: .bridge, length: 10, floors: [.init(enter: 3, exit: 3)]),
                .init(a: 1, b: 2, kind: .bridge, length: 10, floors: [.init(enter: 0, exit: 0)]),
                .init(a: 1, b: 3, kind: .corridor, length: 20),
                .init(a: 3, b: 2, kind: .bridge, length: 20, floors: [.init(enter: 3, exit: 3)]),
            ]
        )
        let route = try #require(router.routes(from: Self.at(0), to: Self.at(2)).first)
        #expect(route.storeys == 0)
        #expect(route.distance == 50)
    }

    // MARK: Lists

    @Test func routesThatShareMostOfTheirLengthAreOneRoute() throws {
        // A long shared corridor, then a choice of two ends that differ by a few meters outside.
        let router = try Self.router(
            [Self.node(0, 0), Self.node(1, 0), Self.node(2, 1), Self.node(2, -1), Self.node(3, 0)],
            [
                .init(a: 0, b: 1, kind: .corridor, length: 500),
                .init(a: 1, b: 2, kind: .outdoor, length: 10),
                .init(a: 2, b: 4, kind: .corridor, length: 10),
                .init(a: 1, b: 3, kind: .corridor, length: 15),
                .init(a: 3, b: 4, kind: .corridor, length: 15),
            ]
        )
        let routes = router.routes(from: Self.at(0), to: Self.at(4))
        #expect(routes.count == 1)
    }

    @Test func aRouteThatSparesRealTimeOutsideSurvivesTheOverlapRule() throws {
        let router = try Self.router(
            [Self.node(0, 0), Self.node(1, 0), Self.node(2, 1), Self.node(2, -1), Self.node(3, 0)],
            [
                .init(a: 0, b: 1, kind: .corridor, length: 500),
                .init(a: 1, b: 2, kind: .outdoor, length: 40),
                .init(a: 2, b: 4, kind: .corridor, length: 10),
                .init(a: 1, b: 3, kind: .corridor, length: 40),
                .init(a: 3, b: 4, kind: .corridor, length: 40),
            ]
        )
        let routes = router.routes(from: Self.at(0), to: Self.at(4))
        #expect(routes.map(\.label) == [.fastest, .mostIndoor])
    }

    @Test func labelsNameTheEndsAndTheMiddle() {
        #expect(Router.labels(1) == [.best])
        #expect(Router.labels(2) == [.fastest, .mostIndoor])
        #expect(Router.labels(3) == [.fastest, .balanced, .mostIndoor])
        #expect(Router.labels(4) == [.fastest, .balanced, .lessOutside, .mostIndoor])
    }

    // MARK: Points on edges

    private static func line() throws -> Router {
        // 0 and 1 are 100 plane-meters apart along the x axis.
        let plane = MapPlane(origin: origin)
        return try router(
            [plane.coordinate(fromPlanar: SIMD2(0, 0)), plane.coordinate(fromPlanar: SIMD2(100, 0))],
            [.init(a: 0, b: 1, kind: .outdoor, length: 100)]
        )
    }

    @Test func aPointJoinsTheNearestEdgeAndKeepsItsStub() throws {
        let router = try Self.line()
        let plane = MapPlane(origin: Self.origin)
        let start = try #require(router.endpoint(at: plane.coordinate(fromPlanar: SIMD2(30, 4)), surface: .outdoors))
        let route = try #require(router.routes(from: start, to: Self.at(1)).first)
        #expect(abs(route.distance - 74) < 1e-6)  // 4 m to the path, then 70 m along it
        #expect(route.outsideLength == route.distance)
        #expect(route.points.first == start.coordinate)
    }

    @Test func theOnlyRouteIsListedOnce() throws {
        // Most of the walk is the stretch from the pin to the graph, which no edge counts.
        let plane = MapPlane(origin: Self.origin)
        let router = try Self.router(
            [plane.coordinate(fromPlanar: SIMD2(0, 0)), plane.coordinate(fromPlanar: SIMD2(100, 0)), plane.coordinate(fromPlanar: SIMD2(110, 0))],
            [.init(a: 0, b: 1, kind: .corridor, length: 100), .init(a: 1, b: 2, kind: .corridor, length: 10)]
        )
        let start = try #require(router.endpoint(at: plane.coordinate(fromPlanar: SIMD2(5, 0)), surface: .indoors))
        #expect(router.routes(from: start, to: Self.at(2)).map(\.label) == [.best])
    }

    @Test func twoPointsOnOneEdgeWalkStraightBetweenThem() throws {
        let router = try Self.line()
        let plane = MapPlane(origin: Self.origin)
        let start = try #require(router.endpoint(at: plane.coordinate(fromPlanar: SIMD2(30, 0)), surface: .outdoors))
        let end = try #require(router.endpoint(at: plane.coordinate(fromPlanar: SIMD2(50, 0)), surface: .outdoors))
        let route = try #require(router.routes(from: start, to: end).first)
        #expect(abs(route.distance - 20) < 1e-6)
        let back = try #require(router.routes(from: end, to: start).first)
        #expect(abs(back.distance - 20) < 1e-6)
    }

    @Test func aPointTooFarAwayIsNotOnTheMap() throws {
        let router = try Self.line()
        let plane = MapPlane(origin: Self.origin)
        #expect(router.endpoint(at: plane.coordinate(fromPlanar: SIMD2(0, 5_000)), surface: .outdoors) == nil)
    }
}
