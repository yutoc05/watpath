import CampusGeo
import CampusModel
import Foundation
import Testing

@testable import Routing

/// Writes the routes from SLC to E5 as JSON for the README's route banner
/// (tools/demo/make_readme_media.py). It isn't a check: it runs only when README_ROUTES
/// names the file to write.
struct ReadmeRoutes {
    private static let directory = URL(filePath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../../build/CampusBundle")

    @Test(.enabled(if: ProcessInfo.processInfo.environment["README_ROUTES"] != nil))
    func writeTheRoutesFromSLCToE5() throws {
        let path = try #require(ProcessInfo.processInfo.environment["README_ROUTES"])
        let router = try Router(graph: WalkGraph.load(from: Self.directory), campus: CampusBundle.load(from: Self.directory))
        let routes = try router.routes(from: #require(router.endpoint(building: "SLC")), to: #require(router.endpoint(building: "E5")))
        // Typed out in full, since Linux's Swift 6.2 is slow to infer mixed dictionaries.
        var json: [[String: Any]] = []
        for route in routes {
            var spans: [[String: Any]] = []
            for span in route.spans {
                let points: [[Double]] = span.points.map { (point: GeoCoordinate) -> [Double] in [point.longitude, point.latitude] }
                spans.append(["kind": span.kind.rawValue, "points": points])
            }
            json.append([
                "label": route.label.rawValue,
                "minutes": Int((route.seconds / 60).rounded()),
                "seconds": route.seconds,
                "distance": route.distance,
                "inside": route.insideLength,
                "outside": route.outsideLength,
                "buildings": route.buildings,
                "spans": spans,
            ])
        }
        try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]).write(to: URL(filePath: path))
    }
}
