/// How long walking takes, and how much routes care about being outside. Every
/// routing constant lives here.
public struct TimeModel: Sendable {
    /// Meters per second.
    public var walkingSpeed: Double
    /// Seconds to change floors by one storey.
    public var storeySeconds: Double
    /// Seconds to pass through a door. It also keeps routes from ducking in and out of
    /// buildings to save a few meters.
    public var doorSeconds: Double
    /// How many times worse a second outside is than one inside, for each route tried.
    public var outsideWeights: [Double]
    /// Two routes count as the same route if they share more than this share of the
    /// shorter one...
    public var sameRouteOverlap: Double
    /// ...unless one spares you at least this many meters outside.
    public var worthwhileOutsideMeters: Double
    public var maximumRoutes: Int
    /// A route that takes more than this many times as long as the fastest isn't offered...
    public var maximumDetour: Double
    /// ...unless it's within this many seconds of it: on a short walk, ratios mean little.
    public var detourAllowanceSeconds: Double
    /// A place farther than this, in meters, from anywhere walkable isn't on the map.
    public var maximumSnapMeters: Double

    public static let standard = TimeModel(
        walkingSpeed: 1.3,
        storeySeconds: 15,
        doorSeconds: 5,
        outsideWeights: [1, 1.25, 1.5, 2, 3, 5, 10, 50],
        sameRouteOverlap: 0.8,
        worthwhileOutsideMeters: 30,
        maximumRoutes: 4,
        maximumDetour: 1.6,
        detourAllowanceSeconds: 120,
        maximumSnapMeters: 300
    )

    public init(
        walkingSpeed: Double,
        storeySeconds: Double,
        doorSeconds: Double,
        outsideWeights: [Double],
        sameRouteOverlap: Double,
        worthwhileOutsideMeters: Double,
        maximumRoutes: Int,
        maximumDetour: Double,
        detourAllowanceSeconds: Double,
        maximumSnapMeters: Double
    ) {
        self.walkingSpeed = walkingSpeed
        self.storeySeconds = storeySeconds
        self.doorSeconds = doorSeconds
        self.outsideWeights = outsideWeights
        self.sameRouteOverlap = sameRouteOverlap
        self.worthwhileOutsideMeters = worthwhileOutsideMeters
        self.maximumRoutes = maximumRoutes
        self.maximumDetour = maximumDetour
        self.detourAllowanceSeconds = detourAllowanceSeconds
        self.maximumSnapMeters = maximumSnapMeters
    }
}
