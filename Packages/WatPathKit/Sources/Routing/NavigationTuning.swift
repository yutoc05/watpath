/// How navigation feels. Every constant lives here, so it can be tweaked in one place.
public struct NavigationTuning: Sendable {
    /// Camera tilt, in degrees from straight down. MapKit's lens is long, which flattens
    /// perspective, so it looks less steep than the number suggests.
    public var pitch: Double
    /// Camera distance in meters at the start.
    public var cameraDistance: Double
    /// How close a pinch can bring the camera. MapKit won't come closer than about 88 m.
    public var closestCameraDistance: Double
    /// How far a pinch can take it. Past this MapKit flattens steep pitches by itself,
    /// which would pull the Street Map out of line with what's drawn over it.
    public var farthestCameraDistance: Double
    /// Degrees the camera turns for a swipe across the whole width of the screen.
    public var turnDegreesPerScreen: Double
    /// How fast a turn swings back once the finger lifts, in radians per second. Lower
    /// than `headingRate`, because this is a move to watch, not one to get out of the way.
    public var turnReturnRate: Double
    /// A flicked turn starts at no more than this many degrees per second.
    public var turnFlickTopRate: Double
    /// Where the walker sits on the screen, from the top (0) to the bottom (1). Below
    /// the middle leaves more of the way ahead in view.
    public var walkerHeight: Double
    /// The camera faces from this many meters behind the walker...
    public var lookBehind: Double
    /// ...to this many ahead, so it starts turning before a corner arrives.
    public var lookAhead: Double
    /// How fast the camera swings to face the route, in radians per second.
    public var headingRate: Double
    /// The camera's path is a spline through points this many meters apart, which sets
    /// how widely it rounds a corner.
    public var splineSpacing: Double
    /// A flick loses this share of its speed per millisecond, as a `UIScrollView` does.
    public var flickDeceleration: Double
    /// A flick stops being a flick below this many meters per second...
    public var flickStopSpeed: Double
    /// ...and starts at no more than this.
    public var flickTopSpeed: Double
    /// Meters of route per meter of ground the finger drags. Above 1, the route gains on
    /// the finger, which covers a campus in fewer swipes.
    public var dragGain: Double
    /// Outdoor stretches shorter than this, in meters, stay on the Path Map, so it
    /// doesn't flicker on the way from one door to the next.
    public var shortestOutdoorStretch: Double
    /// The Street Map sleeps under the Path Map, and wakes this many meters before an
    /// outdoor stretch, so it's ready by the time it has to show.
    public var streetMapLeadMeters: Double
    /// Seconds to fly from wherever the map was to the start of the route.
    public var flightSeconds: Double
    /// Meters between the dots of the dotted line.
    public var dotSpacing: Double

    public static let standard = NavigationTuning(
        pitch: 70,
        cameraDistance: 130,
        closestCameraDistance: 90,
        farthestCameraDistance: 600,
        turnDegreesPerScreen: 180,
        turnReturnRate: 4,
        turnFlickTopRate: 360,
        walkerHeight: 0.6,
        lookBehind: 4,
        lookAhead: 8,
        headingRate: 6,
        splineSpacing: 6,
        flickDeceleration: 0.998,
        flickStopSpeed: 0.2,
        flickTopSpeed: 150,
        dragGain: 1.5,
        shortestOutdoorStretch: 12,
        streetMapLeadMeters: 60,
        flightSeconds: 1.1,
        dotSpacing: 3.5
    )
}
