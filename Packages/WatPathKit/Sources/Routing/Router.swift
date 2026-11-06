import CampusGeo
import CampusModel

/// Finds routes around campus. It never changes the graph, so one router can serve
/// any number of searches at once.
public struct Router: Sendable {
    /// Which side of the walls to look on for a point that isn't in a building.
    public enum Surface: Sendable {
        case indoors, outdoors
    }

    public let graph: WalkGraph
    public let model: TimeModel
    private let plane: MapPlane
    private let search: PathSearch
    /// Each edge's line on the plane, with its bends.
    private let lines: [[SIMD2<Double>]]
    private let outlines: [(code: String, rings: [[SIMD2<Double>]])]

    public init(graph: WalkGraph, campus: CampusBundle, model: TimeModel = .standard) {
        let plane = MapPlane(origin: campus.origin)
        self.graph = graph
        self.model = model
        self.plane = plane
        search = PathSearch(graph: graph, model: model)
        lines = graph.edges.map { edge in graph.line(of: edge).map(plane.planar) }
        outlines = campus.buildings.map { building in
            (building.code, building.parts.flatMap { part in ([part.outline] + part.holes).map { $0.map(plane.planar) } })
        }
    }

    // MARK: Endpoints

    /// A building: its point of arrival if it has lines, otherwise any of its doors.
    public func endpoint(building code: String) -> Endpoint? {
        guard let anchors = graph.buildings[code]?.anchors, !anchors.isEmpty else { return nil }
        return Endpoint(
            coordinate: graph.nodes[anchors[0]],
            attachments: anchors.map { .init(node: $0, points: [graph.nodes[$0]], inside: 0, outside: 0, kind: .corridor) }
        )
    }

    public func endpoint(door id: String) -> Endpoint? {
        guard let node = graph.doors[id] else { return nil }
        return Endpoint(
            coordinate: graph.nodes[node],
            attachments: [.init(node: node, points: [graph.nodes[node]], inside: 0, outside: 0, kind: .corridor)]
        )
    }

    /// A point on the map. In a building it joins the nearest indoor line, or the
    /// building's doors if it has no lines. Elsewhere, it joins the nearest line on
    /// `surface`. Nil when that's too far away.
    public func endpoint(at coordinate: GeoCoordinate, surface: Surface) -> Endpoint? {
        let point = plane.planar(coordinate)
        let building = outlines.first { PolygonGeometry.contains($0.rings, point) }?.code
        if let building, let entry = graph.buildings[building], !entry.hasLines {
            let attachments = entry.anchors.map { node in
                let target = graph.nodes[node]
                return Endpoint.Attachment(node: node, points: [coordinate, target], inside: Self.length(point, plane.planar(target)), outside: 0, kind: .corridor)
            }
            return attachments.isEmpty ? nil : Endpoint(coordinate: coordinate, attachments: attachments)
        }
        let indoors = building != nil || surface == .indoors
        guard let snap = nearest(to: point, indoors: indoors), snap.distance <= model.maximumSnapMeters else { return nil }
        return endpoint(at: coordinate, on: snap, stubIsInside: indoors)
    }

    private struct Snap {
        var edge: Int
        var fraction: Double
        var join: SIMD2<Double>
        var distance: Double
    }

    private func nearest(to point: SIMD2<Double>, indoors: Bool) -> Snap? {
        var best: Snap?
        for (index, edge) in graph.edges.enumerated() where edge.kind.isInside == indoors && !edge.isOneWay && edge.length > 0 {
            let line = lines[index]
            var walked = 0.0
            let total = Self.polylineLength(line)
            for (a, b) in zip(line, line.dropFirst()) {
                let (join, along) = Self.closest(onSegment: a, b, to: point)
                let distance = Self.length(join, point)
                if distance < best?.distance ?? .infinity {
                    best = Snap(edge: index, fraction: total > 0 ? (walked + along) / total : 0, join: join, distance: distance)
                }
                walked += Self.length(a, b)
            }
        }
        return best
    }

    private func endpoint(at coordinate: GeoCoordinate, on snap: Snap, stubIsInside: Bool) -> Endpoint {
        let edge = graph.edges[snap.edge]
        let join = plane.coordinate(fromPlanar: snap.join)
        let line = graph.line(of: edge)
        let bends = Self.bendsBefore(fraction: snap.fraction, line: lines[snap.edge])
        func attachment(toward node: Int, along: [GeoCoordinate], fraction: Double) -> Endpoint.Attachment {
            let length = edge.length * fraction
            let points = [coordinate, join] + along
            return Endpoint.Attachment(
                node: node,
                points: points,
                inside: (stubIsInside ? snap.distance : 0) + (edge.kind.isInside ? length : 0),
                outside: (stubIsInside ? 0 : snap.distance) + (edge.kind.isInside ? 0 : length),
                kind: edge.kind
            )
        }
        return Endpoint(
            coordinate: coordinate,
            attachments: [
                attachment(toward: edge.a, along: line[..<bends].reversed(), fraction: snap.fraction),
                attachment(toward: edge.b, along: Array(line[bends...]), fraction: 1 - snap.fraction),
            ],
            position: .init(edge: snap.edge, fraction: snap.fraction, stub: snap.distance, stubIsInside: stubIsInside, join: join)
        )
    }

    /// A walk that stays on one edge never reaches a node, so it needs its own connection.
    private func directWalk(from start: Endpoint, to end: Endpoint) -> Endpoint.Attachment? {
        guard let from = start.position, let to = end.position, from.edge == to.edge else { return nil }
        let edge = graph.edges[from.edge]
        let line = graph.line(of: edge)
        let first = Self.bendsBefore(fraction: from.fraction, line: lines[from.edge])
        let last = Self.bendsBefore(fraction: to.fraction, line: lines[from.edge])
        let middle = from.fraction <= to.fraction ? Array(line[first..<max(first, last)]) : Array(line[last..<max(first, last)].reversed())
        let length = abs(to.fraction - from.fraction) * edge.length
        let stubs = [(from.stub, from.stubIsInside), (to.stub, to.stubIsInside)]
        return Endpoint.Attachment(
            node: -1,
            points: [start.coordinate, from.join] + middle + [to.join, end.coordinate],
            inside: (edge.kind.isInside ? length : 0) + stubs.filter(\.1).reduce(0) { $0 + $1.0 },
            outside: (edge.kind.isInside ? 0 : length) + stubs.filter { !$0.1 }.reduce(0) { $0 + $1.0 },
            kind: edge.kind
        )
    }

    // MARK: Routes

    /// The routes worth choosing between: the fastest, the most indoor, and the best
    /// trade-offs between them, fastest first. Empty when there's no way there.
    public func routes(from start: Endpoint, to end: Endpoint) -> [Route] {
        let direct = directWalk(from: start, to: end)
        var found: [Route] = []
        for weight in model.outsideWeights {
            guard let walk = search.cheapestWalk(from: start, to: end, direct: direct, outsideWeight: weight) else { continue }
            let route = self.route(walk, from: start, to: end, direct: direct)
            if !found.contains(where: { $0.edges == route.edges }) {
                found.append(route)
            }
        }
        let quickest = found.map(\.seconds).min() ?? 0
        let longest = max(quickest * model.maximumDetour, quickest + model.detourAllowanceSeconds)
        let front = found
            .filter { route in route.seconds <= longest && !found.contains { route.isBeaten(by: $0) } }
            .sorted { ($0.seconds, $0.outsideLength) < ($1.seconds, $1.outsideLength) }
        guard let fastest = front.first, let mostIndoor = front.last else { return [] }
        // These two are the reason to have a list, so everything else has to differ from them.
        var kept = isSameRoute(fastest, mostIndoor) ? [fastest] : [fastest, mostIndoor]
        for route in front.dropFirst().dropLast() where !kept.contains(where: { isSameRoute(route, $0) }) {
            kept.append(route)
        }
        return Self.labeled(Self.spread(kept.sorted { $0.seconds < $1.seconds }, limit: model.maximumRoutes))
    }

    private func isSameRoute(_ a: Route, _ b: Route) -> Bool {
        guard a.edges != b.edges else { return true }
        let shared = a.edges.intersection(b.edges).reduce(0.0) { $0 + graph.edges[$1].length }
        let shorter = min(a.distance, b.distance)
        return shorter <= 0 || (shared / shorter > model.sameRouteOverlap && abs(a.outsideLength - b.outsideLength) < model.worthwhileOutsideMeters)
    }

    /// At most `limit` routes: always the first and last, with the rest evenly picked.
    private static func spread(_ routes: [Route], limit: Int) -> [Route] {
        guard routes.count > limit, limit >= 2 else { return routes }
        return (0..<limit).map { routes[$0 * (routes.count - 1) / (limit - 1)] }
    }

    private static func labeled(_ routes: [Route]) -> [Route] {
        zip(routes, labels(routes.count)).enumerated().map { index, pair in
            var route = pair.0
            route.id = index
            route.label = pair.1
            return route
        }
    }

    /// Names for a list of `count` routes, fastest first.
    static func labels(_ count: Int) -> [Route.Label] {
        guard count > 1 else { return [.best] }
        let middle: [Route.Label] = [.balanced, .lessOutside]
        return [.fastest] + middle.prefix(count - 2) + [.mostIndoor]
    }

    private func route(_ walk: Walk, from start: Endpoint, to end: Endpoint, direct: Endpoint.Attachment?) -> Route {
        var spans: [Route.Span] = []
        var inside = 0.0, outside = 0.0
        var doors = 0
        var buildings: [String] = []

        func add(_ kind: WalkGraph.Edge.Kind, _ points: [GeoCoordinate], _ length: Double) {
            if let last = spans.indices.last, spans[last].kind == kind {
                spans[last].points += points
                spans[last].length += length
            } else if length > 0 || points.count > 1 {
                spans.append(Route.Span(kind: kind, points: points, length: length))
            }
        }
        func add(_ attachment: Endpoint.Attachment, reversed: Bool) {
            inside += attachment.inside
            outside += attachment.outside
            add(attachment.kind, reversed ? attachment.points.reversed() : attachment.points, attachment.inside + attachment.outside)
        }

        guard let startAttachment = walk.startAttachment, let endAttachment = walk.endAttachment else {
            if let direct { add(direct, reversed: false) }
            return finish(spans: spans, inside: inside, outside: outside, doors: 0, storeys: 0, buildings: [], edges: [])
        }
        add(start.attachments[startAttachment], reversed: false)
        for hop in walk.hops {
            let edge = graph.edges[hop.edge]
            let line = graph.line(of: edge)
            add(edge.kind, hop.isForward ? line : line.reversed(), edge.length)
            if edge.kind.isInside { inside += edge.length } else { outside += edge.length }
            if edge.kind == .door { doors += 1 }
            if let building = edge.building, buildings.last != building, edge.kind != .door { buildings.append(building) }
        }
        add(end.attachments[endAttachment], reversed: true)
        return finish(spans: spans, inside: inside, outside: outside, doors: doors, storeys: walk.storeys, buildings: buildings, edges: Set(walk.hops.map(\.edge)))
    }

    private func finish(spans: [Route.Span], inside: Double, outside: Double, doors: Int, storeys: Double, buildings: [String], edges: Set<Int>) -> Route {
        let distance = inside + outside
        return Route(
            spans: spans,
            distance: distance,
            insideLength: inside,
            outsideLength: outside,
            seconds: distance / model.walkingSpeed + Double(doors) * model.doorSeconds + storeys * model.storeySeconds,
            storeys: storeys,
            buildings: buildings,
            edges: edges
        )
    }

    // MARK: Geometry

    private static func length(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double {
        let d = b - a
        return (d * d).sum().squareRoot()
    }

    private static func polylineLength(_ line: [SIMD2<Double>]) -> Double {
        zip(line, line.dropFirst()).reduce(0) { $0 + length($1.0, $1.1) }
    }

    /// The closest point on a segment, and how far along it that is.
    private static func closest(onSegment a: SIMD2<Double>, _ b: SIMD2<Double>, to point: SIMD2<Double>) -> (SIMD2<Double>, Double) {
        let ab = b - a
        let squared = (ab * ab).sum()
        guard squared > 0 else { return (a, 0) }
        let t = min(max(((point - a) * ab).sum() / squared, 0), 1)
        return (a + ab * t, t * squared.squareRoot())
    }

    /// How many of the line's points come before a place `fraction` of the way along it.
    private static func bendsBefore(fraction: Double, line: [SIMD2<Double>]) -> Int {
        let target = fraction * polylineLength(line)
        var walked = 0.0
        for (index, (a, b)) in zip(line, line.dropFirst()).enumerated() {
            walked += length(a, b)
            if walked >= target { return index + 1 }
        }
        return line.count - 1
    }
}
