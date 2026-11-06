import CampusGeo

/// Where a route starts or ends, tied to the graph without changing it: temporary
/// connections to the nodes it can reach. Tying a point to the middle of an edge gives
/// it one to each end of that edge.
public struct Endpoint: Sendable {
    /// A way between the endpoint and a graph node.
    struct Attachment: Sendable {
        var node: Int
        /// From the endpoint to the node.
        var points: [GeoCoordinate]
        /// Meters indoors and outdoors.
        var inside: Double
        var outside: Double
        /// What the walk along it looks like, from the endpoint to the node.
        var kind: WalkGraph.Edge.Kind
    }

    /// Where on an edge the endpoint sits.
    struct Position: Sendable {
        var edge: Int
        /// Share of the way from `a` to `b`, from 0 to 1.
        var fraction: Double
        /// How far off the edge the endpoint really is, and the point it joins at.
        var stub: Double
        var stubIsInside: Bool
        var join: GeoCoordinate
    }

    public var coordinate: GeoCoordinate
    var attachments: [Attachment]
    var position: Position?
}
