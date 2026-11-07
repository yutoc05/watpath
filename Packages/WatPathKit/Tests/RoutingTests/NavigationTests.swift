import CampusGeo
import CampusModel
import Foundation
import Testing

@testable import Routing

private let origin = GeoCoordinate(latitude: 43.47, longitude: -80.54)
private let plane = MapPlane(origin: origin)

/// A route through plane points, with each stretch its own kind.
private func route(_ stretches: [(WalkGraph.Edge.Kind, [SIMD2<Double>])]) -> Route {
    let spans = stretches.map { kind, points -> Route.Span in
        let length = zip(points, points.dropFirst()).reduce(0) { $0 + MeasuredLine.distance($1.0, $1.1) }
        return Route.Span(kind: kind, points: points.map(plane.coordinate(fromPlanar:)), length: length, seconds: length / 1.3)
    }
    let distance = spans.reduce(0) { $0 + $1.length }
    let outside = spans.filter { $0.kind == .outdoor }.reduce(0) { $0 + $1.length }
    return Route(spans: spans, distance: distance, insideLength: distance - outside, outsideLength: outside, seconds: distance / 1.3, storeys: 0, buildings: [], edges: [])
}

/// 100 m north, then 100 m east: a square corner at (0, 100).
private let corner = route([(.corridor, [[0, 0], [0, 100], [100, 100]])])

struct RouteTimeTests {
    @Test func timeLeftRunsDownEvenlyOnAPlainWalk() {
        let walk = route([(.corridor, [[0, 0], [0, 130]])])
        #expect(abs(walk.secondsRemaining(at: 0) - 100) < 1e-6)
        #expect(abs(walk.secondsRemaining(at: 65) - 50) < 1e-6)
        #expect(walk.secondsRemaining(at: 130) == 0)
        #expect(walk.secondsRemaining(at: 500) == 0)
    }

    @Test func stairsComeOffAtTheStretchThatHasThem() {
        var walk = route([(.corridor, [[0, 0], [0, 13]]), (.bridge, [[0, 13], [0, 26]]), (.corridor, [[0, 26], [0, 39]])])
        walk.spans[1].seconds += 30  // two storeys, on the bridge
        walk.seconds += 30
        #expect(abs(walk.secondsRemaining(at: 13) - 50) < 1e-6)
        #expect(abs(walk.secondsRemaining(at: 26) - 10) < 1e-6)
    }

    @Test func aZeroLengthSpanStillCounts() {
        var walk = route([(.corridor, [[0, 0], [0, 13]]), (.corridor, [[0, 13], [0, 26]])])
        walk.spans.insert(.init(kind: .link, points: [], length: 0, seconds: 15), at: 1)
        walk.seconds += 15
        #expect(abs(walk.secondsRemaining(at: 6.5) - 30) < 1e-6)
        #expect(abs(walk.secondsRemaining(at: 19.5) - 5) < 1e-6)
    }
}

struct RouteTrackTests {
    private let track = RouteTrack(route: corner, plane: plane)

    @Test func measuresTheWholeRoute() {
        #expect(abs(track.length - 200) < 1e-6)
    }

    @Test func pointsFollowTheRouteExactly() {
        #expect(length(track.point(at: 0) - [0, 0]) < 1e-6)
        #expect(length(track.point(at: 50) - [0, 50]) < 1e-6)
        #expect(length(track.point(at: 100) - [0, 100]) < 1e-6)
        #expect(length(track.point(at: 150) - [50, 100]) < 1e-6)
        #expect(length(track.point(at: 200) - [100, 100]) < 1e-6)
    }

    @Test func distancesOffTheRouteStayOnIt() {
        #expect(length(track.point(at: -10) - [0, 0]) < 1e-6)
        #expect(length(track.point(at: 1_000) - [100, 100]) < 1e-6)
    }

    @Test func theCameraStaysCloseToTheRouteAndRoundsTheCorner() {
        // On the straights, it's the route itself.
        #expect(length(track.aim(at: 50) - track.point(at: 50)) < 0.5)
        #expect(length(track.aim(at: 150) - track.point(at: 150)) < 0.5)
        // At the corner it cuts inside by a little, and never swings outside.
        let atCorner = track.aim(at: 100)
        #expect(length(atCorner - [0, 100]) > 0.05)
        #expect(length(atCorner - [0, 100]) < 6)
        #expect(atCorner.x >= -0.5 && atCorner.y <= 100.5)
    }

    /// Cutting corners makes the camera's path shorter than the route. If that added up
    /// along the way, the walker would slide around the screen.
    @Test func theCameraNeverFallsBehindTheWalker() {
        let zigzag = (0...20).map { step -> SIMD2<Double> in
            SIMD2(Double(step) * 30, step.isMultiple(of: 2) ? 0 : 30)
        }
        let walk = RouteTrack(route: route([(.corridor, zigzag)]), plane: plane)
        for distance in stride(from: 0, through: walk.length, by: 2) {
            #expect(length(walk.aim(at: distance) - walk.point(at: distance)) < NavigationTuning.standard.splineSpacing)
        }
    }

    @Test func theCamerasPathHasNoSharpTurns() {
        var previous = track.aim(at: 0)
        var previousDirection: SIMD2<Double>?
        for step in 1...200 {
            let next = track.aim(at: Double(step))
            let direction = next - previous
            if let previousDirection, length(direction) > 1e-6, length(previousDirection) > 1e-6 {
                let cosine = (direction * previousDirection).sum() / (length(direction) * length(previousDirection))
                #expect(cosine > 0.8, "at \(step) m")  // under about 37° per meter
            }
            previous = next
            previousDirection = direction
        }
    }

    @Test func facingFollowsTheRouteAndTurnsBeforeTheCorner() {
        #expect(abs(track.facing(at: 50)) < 0.01)  // north
        #expect(abs(track.facing(at: 150) - .pi / 2) < 0.01)  // east
        let early = track.facing(at: 96)
        #expect(early > 0.05 && early < .pi / 2)
    }

    @Test func facingWorksAtBothEnds() {
        #expect(abs(track.facing(at: 0)) < 0.01)
        #expect(abs(track.facing(at: 200) - .pi / 2) < 0.01)
    }

    @Test func aRouteTooShortForASplineStillWorks() {
        let tiny = RouteTrack(route: route([(.corridor, [[0, 0], [0, 3]])]), plane: plane)
        #expect(length(tiny.aim(at: 1.5) - [0, 1.5]) < 1e-6)
        #expect(abs(tiny.facing(at: 1.5)) < 1e-6)
    }

    @Test func aRouteWithNoLengthDoesntBreak() {
        let empty = RouteTrack(route: route([(.corridor, [[5, 5]])]), plane: plane)
        #expect(empty.length == 0)
        #expect(length(empty.point(at: 0) - [5, 5]) < 1e-6)
        #expect(empty.dots(every: 3).isEmpty)
    }

    @Test func knowsWhenItsOutside() {
        let walk = RouteTrack(
            route: route([(.corridor, [[0, 0], [0, 50]]), (.outdoor, [[0, 50], [0, 100]]), (.corridor, [[0, 100], [0, 150]])]),
            plane: plane
        )
        #expect(!walk.isOutside(at: 25))
        #expect(walk.isOutside(at: 75))
        #expect(!walk.isOutside(at: 125))
    }

    @Test func knowsWhenAnOutdoorStretchIsNear() {
        let walk = RouteTrack(
            route: route([(.corridor, [[0, 0], [0, 100]]), (.outdoor, [[0, 100], [0, 200]]), (.corridor, [[0, 200], [0, 300]])]),
            plane: plane
        )
        #expect(!walk.isNearOutside(at: 30, within: 60))
        #expect(walk.isNearOutside(at: 50, within: 60))
        #expect(walk.isNearOutside(at: 150, within: 60))
        #expect(walk.isNearOutside(at: 250, within: 60))
        #expect(!walk.isNearOutside(at: 270, within: 60))
    }

    @Test func aRouteThatStaysInsideIsNeverNearOutside() {
        #expect(!RouteTrack(route: corner, plane: plane).isNearOutside(at: 100, within: 500))
    }

    @Test func aShortStepOutsideStaysOnThePathMap() {
        let walk = RouteTrack(
            route: route([(.corridor, [[0, 0], [0, 50]]), (.outdoor, [[0, 50], [0, 55]]), (.corridor, [[0, 55], [0, 100]])]),
            plane: plane
        )
        #expect(!walk.isOutside(at: 52))
    }

    @Test func outdoorSpansThatTouchCountAsOneStretch() {
        let walk = RouteTrack(
            route: route([(.outdoor, [[0, 0], [0, 8]]), (.outdoor, [[0, 8], [0, 16]]), (.corridor, [[0, 16], [0, 50]])]),
            plane: plane
        )
        #expect(walk.isOutside(at: 4))
    }

    @Test func dotsAreEvenlySpacedAlongTheRoute() {
        let dots = track.dots(every: 25)
        #expect(dots.count == 9)
        #expect(length(dots[4].point - [0, 100]) < 1e-6)
        #expect(dots[8].distance == 200)
    }

    private func length(_ v: SIMD2<Double>) -> Double {
        (v * v).sum().squareRoot()
    }
}

struct ScrubMotionTests {
    @Test func aDragMovesExactlyThatFar() {
        var motion = ScrubMotion(length: 100)
        motion.drag(by: 30)
        #expect(motion.position == 30)
        motion.drag(by: -10)
        #expect(motion.position == 20)
    }

    @Test func itStaysOnTheRoute() {
        var motion = ScrubMotion(length: 100)
        motion.drag(by: -5)
        #expect(motion.position == 0)
        motion.drag(by: 500)
        #expect(motion.position == 100)
        #expect(motion.isAtEnd)
    }

    @Test func aFlickCoastsAndSlowsToAStop() {
        var motion = ScrubMotion(length: 10_000)
        motion.flick(metersPerSecond: 50)
        var last = 0.0
        for _ in 0..<600 {
            motion.advance(seconds: 1.0 / 60)
            #expect(motion.position >= last)
            last = motion.position
        }
        #expect(motion.velocity == 0)
        // v / -ln(r) at r per millisecond: about half a second's worth of the first speed.
        #expect(abs(motion.position - 50 * 0.4995) < 0.5)
    }

    @Test func aFlickGoesTheSameDistanceAtAnyFrameRate() {
        func distance(frames: Int) -> Double {
            var motion = ScrubMotion(length: 10_000)
            motion.flick(metersPerSecond: 40)
            for _ in 0..<frames { motion.advance(seconds: 5.0 / Double(frames)) }
            return motion.position
        }
        #expect(abs(distance(frames: 300) - distance(frames: 40)) < 0.2)
    }

    @Test func aFlickBackwardsGoesBackwards() {
        var motion = ScrubMotion(length: 1_000)
        motion.drag(by: 500)
        motion.flick(metersPerSecond: -40)
        motion.advance(seconds: 0.1)
        #expect(motion.position < 500)
    }

    @Test func aFlickStopsDeadAtEitherEnd() {
        var motion = ScrubMotion(length: 10)
        motion.flick(metersPerSecond: 100)
        motion.advance(seconds: 1)
        #expect(motion.position == 10 && motion.velocity == 0)
        motion.flick(metersPerSecond: -100)
        motion.advance(seconds: 1)
        #expect(motion.position == 0 && motion.velocity == 0)
    }

    @Test func aHugeFlickIsCapped() {
        var motion = ScrubMotion(length: 10_000)
        motion.flick(metersPerSecond: 9_000)
        #expect(motion.velocity == NavigationTuning.standard.flickTopSpeed)
    }

    @Test func aTinyFlickIsNoFlick() {
        var motion = ScrubMotion(length: 100)
        motion.flick(metersPerSecond: 0.1)
        #expect(motion.velocity == 0)
    }

    @Test func aFingerCatchesAFlick() {
        var motion = ScrubMotion(length: 1_000)
        motion.flick(metersPerSecond: 50)
        motion.advance(seconds: 0.1)
        motion.hold()
        let caught = motion.position
        motion.advance(seconds: 1)
        #expect(motion.position == caught)
    }

    @Test func draggingEndsAFlick() {
        var motion = ScrubMotion(length: 1_000)
        motion.flick(metersPerSecond: 50)
        motion.drag(by: 1)
        #expect(motion.velocity == 0)
    }
}

struct HeadingSpringTests {
    private func settle(_ spring: inout HeadingSpring, toward target: Double, seconds: Double = 3) {
        for _ in 0..<Int(seconds * 60) { spring.advance(toward: target, seconds: 1.0 / 60) }
    }

    @Test func settlesOnTheTarget() {
        var spring = HeadingSpring(angle: 0, stiffness: 6)
        settle(&spring, toward: 1.2)
        #expect(abs(spring.angle - 1.2) < 1e-3)
    }

    @Test func neverOvershoots() {
        var spring = HeadingSpring(angle: 0, stiffness: 6)
        for _ in 0..<300 {
            spring.advance(toward: 1, seconds: 1.0 / 60)
            #expect(spring.angle <= 1 + 1e-9)
        }
    }

    @Test func turnsTheShortWayAround() {
        var spring = HeadingSpring(angle: 170 * .pi / 180, stiffness: 6)
        spring.advance(toward: -170 * .pi / 180, seconds: 1.0 / 60)
        // Through 180°, so it wraps to negative, or is still just short of it.
        #expect(spring.angle > 170 * .pi / 180 || spring.angle < -170 * .pi / 180)
        settle(&spring, toward: -170 * .pi / 180)
        #expect(abs(spring.angle + 170 * .pi / 180) < 1e-3)
    }

    @Test func aLongFrameDoesntBlowUp() {
        var spring = HeadingSpring(angle: 0, stiffness: 6)
        spring.advance(toward: 1, seconds: 10)
        #expect(abs(spring.angle - 1) < 1e-3)
    }

    @Test func nothingMovesAtTheTarget() {
        var spring = HeadingSpring(angle: 0.5, stiffness: 6)
        spring.advance(toward: 0.5, seconds: 1)
        #expect(abs(spring.angle - 0.5) < 1e-12)
    }
}

struct NavigationRigTests {
    @Test func startsAtTheStartFacingTheRoute() {
        let rig = NavigationRig(route: corner, plane: plane)
        #expect(rig.pose.distance == 0)
        #expect(rig.pose.progress == 0)
        #expect(abs(rig.pose.heading) < 0.5)
        #expect(!rig.isAtEnd)
    }

    @Test func aDragMovesTheWalkerAlongTheRoute() {
        var rig = NavigationRig(route: corner, plane: plane)
        rig.drag(by: 150)
        rig.advance(seconds: 1.0 / 60)
        #expect(rig.pose.progress == 0.75)
        #expect(abs(rig.pose.walker.x - 50) < 1e-6 && abs(rig.pose.walker.y - 100) < 1e-6)
        #expect(abs(rig.pose.distanceRemaining - 50) < 1e-6)
        #expect(abs(rig.pose.secondsRemaining - 50 / 1.3) < 1e-6)
    }

    @Test func theCameraSwingsGraduallyThroughACorner() {
        var rig = NavigationRig(route: corner, plane: plane)
        rig.drag(by: 96)
        var last = rig.pose.heading
        var biggest = 0.0
        for _ in 0..<30 {
            rig.drag(by: 1)
            rig.advance(seconds: 1.0 / 60)
            biggest = max(biggest, abs(rig.pose.heading - last))
            last = rig.pose.heading
        }
        #expect(biggest < 8)  // degrees per frame, with the walker at 60 m/s
        for _ in 0..<180 { rig.advance(seconds: 1.0 / 60) }
        #expect(abs(rig.pose.heading - 90) < 1)
    }

    @Test func reachingTheEndIsArrival() {
        var rig = NavigationRig(route: corner, plane: plane)
        rig.drag(by: 500)
        #expect(rig.isAtEnd)
        #expect(rig.pose.progress == 1)
        #expect(rig.pose.distanceRemaining == 0)
        #expect(rig.pose.secondsRemaining == 0)
    }

    @Test func aRouteWithNoLengthIsAlreadyThere() {
        let rig = NavigationRig(route: route([(.corridor, [[5, 5]])]), plane: plane)
        #expect(rig.isAtEnd)
        #expect(rig.pose.progress == 1)
    }
}

struct CameraFlightTests {
    private let start = MapCameraState(center: .init(latitude: 43.47, longitude: -80.54), distance: 2_400, heading: 350, pitch: 0)
    private let target = MapCameraState(center: .init(latitude: 43.48, longitude: -80.53), distance: 130, heading: 10, pitch: 50)

    @Test func startsWhereTheCameraWasAndLandsOnTarget() {
        var flight = CameraFlight(from: start, seconds: 1)
        let first = flight.state(toward: target)
        #expect(first.center == start.center && first.pitch == start.pitch && first.heading == start.heading)
        #expect(abs(first.distance - start.distance) < 1e-6)
        flight.advance(seconds: 2)
        #expect(flight.isFinished)
        #expect(flight.state(toward: target) == target)
    }

    @Test func turnsTheShortWayAround() {
        var flight = CameraFlight(from: start, seconds: 1)
        flight.advance(seconds: 0.5)
        #expect(abs(flight.state(toward: target).heading - 360) < 1e-6)  // 350° through north to 10°
    }

    @Test func zoomsAtASteadyRatio() {
        var flight = CameraFlight(from: start, seconds: 1)
        flight.advance(seconds: 0.5)
        #expect(abs(flight.state(toward: target).distance - (2_400.0 * 130).squareRoot()) < 1e-6)
    }

    @Test func aFlightWithNoTimeJustArrives() {
        #expect(CameraFlight(from: start, seconds: 0).state(toward: target) == target)
    }
}
