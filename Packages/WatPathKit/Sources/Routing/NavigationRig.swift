import CampusGeo
import Foundation

/// Everything that moves during navigation, as plain values. Drags and flicks go in,
/// and each frame a `Pose` comes out. The app turns that into a camera, and doesn't have
/// to know how any of it was worked out.
public struct NavigationRig: Sendable {
    public struct Pose: Sendable, Equatable {
        /// Meters along the route.
        public var distance: Double
        /// From 0 at the start to 1 at the end.
        public var progress: Double
        /// The exact spot on the route.
        public var walker: SIMD2<Double>
        /// What the camera looks at.
        public var aim: SIMD2<Double>
        /// Degrees clockwise from north.
        public var heading: Double
        /// True on an outdoor stretch long enough to show the Street Map.
        public var isOutside: Bool
        public var distanceRemaining: Double
        public var secondsRemaining: Double
    }

    public let route: Route
    public let track: RouteTrack
    public let tuning: NavigationTuning
    public private(set) var motion: ScrubMotion
    private var heading: HeadingSpring

    public init(route: Route, plane: MapPlane, tuning: NavigationTuning = .standard) {
        self.route = route
        self.tuning = tuning
        track = RouteTrack(route: route, plane: plane, tuning: tuning)
        motion = ScrubMotion(length: track.length, tuning: tuning)
        heading = HeadingSpring(angle: track.facing(at: 0), stiffness: tuning.headingRate)
    }

    public var isAtEnd: Bool { motion.isAtEnd }

    public var pose: Pose {
        let distance = motion.position
        return Pose(
            distance: distance,
            progress: track.length > 0 ? distance / track.length : 1,
            walker: track.point(at: distance),
            aim: track.aim(at: distance),
            heading: heading.angle * 180 / .pi,
            isOutside: track.isOutside(at: distance),
            distanceRemaining: track.length - distance,
            secondsRemaining: route.secondsRemaining(at: distance)
        )
    }

    public mutating func drag(by meters: Double) {
        motion.drag(by: meters)
    }

    public mutating func flick(metersPerSecond speed: Double) {
        motion.flick(metersPerSecond: speed)
    }

    public mutating func hold() {
        motion.hold()
    }

    /// Moves everything on by a frame.
    public mutating func advance(seconds: Double) {
        motion.advance(seconds: seconds)
        heading.advance(toward: track.facing(at: motion.position), seconds: seconds)
    }
}

/// The camera's trip from wherever it was to the start of a route. The destination can
/// move while it flies, so the camera lands on the rig rather than on where it used to be.
public struct CameraFlight: Sendable {
    private let start: MapCameraState
    private let seconds: Double
    public private(set) var elapsed = 0.0

    public init(from start: MapCameraState, seconds: Double) {
        self.start = start
        self.seconds = seconds
    }

    public var isFinished: Bool { elapsed >= seconds }

    public mutating func advance(seconds step: Double) {
        elapsed += step
    }

    /// The camera now, on its way to `target`.
    public func state(toward target: MapCameraState) -> MapCameraState {
        guard !isFinished, seconds > 0 else { return target }
        let linear = elapsed / seconds
        let eased = linear * linear * (3 - 2 * linear)
        func mix(_ from: Double, _ to: Double) -> Double { from + (to - from) * eased }
        // Distance by ratio, which reads as a steady zoom. Heading the short way around.
        let turn = HeadingSpring.wrapped((target.heading - start.heading) * .pi / 180) * 180 / .pi
        return MapCameraState(
            center: GeoCoordinate(latitude: mix(start.center.latitude, target.center.latitude), longitude: mix(start.center.longitude, target.center.longitude)),
            distance: exp(mix(log(start.distance), log(target.distance))),
            heading: start.heading + turn * eased,
            pitch: mix(start.pitch, target.pitch)
        )
    }
}
