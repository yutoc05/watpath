import CampusGeo
import Testing

struct MapCameraTests {
    let plane = MapPlane(origin: GeoCoordinate(latitude: 43.4720, longitude: -80.5440))
    let viewport = SIMD2<Double>(390, 844)
    let model = MapKitCameraModel(verticalFieldOfView: 30, altitudeScale: 1)

    func state(heading: Double = 0, pitch: Double = 0, distance: Double = 500) -> MapCameraState {
        MapCameraState(center: plane.origin, distance: distance, heading: heading, pitch: pitch)
    }

    func pose(_ state: MapCameraState, anchor: SIMD2<Double> = .zero) -> CameraPose {
        CameraPose(state: state, plane: plane, model: model, viewportSize: viewport, anchor: anchor)
    }

    func expectClose(_ a: SIMD3<Double>, _ b: SIMD3<Double>, tolerance: Double = 1e-9) {
        #expect(((a - b) * (a - b)).sum().squareRoot() < tolerance, "\(a) != \(b)")
    }

    @Test func topDownNorthUpLooksStraightDown() {
        let pose = pose(state())
        expectClose(pose.eye, SIMD3(0, 0, 500))
        expectClose(pose.forward, SIMD3(0, 0, -1))
        expectClose(pose.up, SIMD3(0, 1, 0))
        expectClose(pose.right, SIMD3(1, 0, 0))
    }

    @Test func headingEastPutsEastAtTopAndSouthOnTheRight() {
        let pose = pose(state(heading: 90))
        expectClose(pose.up, SIMD3(1, 0, 0))
        expectClose(pose.right, SIMD3(0, -1, 0))
    }

    @Test func pitchedCameraSitsBehindAndAboveTheCenter() {
        // Facing north, tilted 60°, no anchor offset: altitude d·cos(60°), south of center.
        expectClose(pose(state(pitch: 60)).eye, SIMD3(0, -500 * 0.866_025_403_784_438_6, 250), tolerance: 1e-6)
    }

    @Test func centerProjectsToTheAnchor() {
        let anchor = SIMD2<Double>(0, 14)
        let projector = PinholeProjector(state: state(heading: 33, pitch: 45), plane: plane, model: model, viewportSize: viewport, anchor: anchor)
        let p = projector.project(SIMD3(0, 0, 0))!
        #expect(abs(p.x - 195) < 1e-9 && abs(p.y - 436) < 1e-9)
    }

    @Test func northIsUpAndEastIsRightOnScreen() {
        let projector = PinholeProjector(state: state(), plane: plane, model: model, viewportSize: viewport, anchor: .zero)
        #expect(projector.project(SIMD3(0, 50, 0))!.y < viewport.y / 2)
        #expect(projector.project(SIMD3(50, 0, 0))!.x > viewport.x / 2)
    }

    @Test func unprojectInvertsProject() {
        let projector = PinholeProjector(state: state(heading: 125, pitch: 55), plane: plane, model: model, viewportSize: viewport, anchor: SIMD2(0, 6.5))
        for point in [SIMD3<Double>(30, -12, 0), SIMD3(-80, 140, 0), SIMD3(5, 5, 12)] {
            let screen = projector.project(point)!
            let back = projector.unproject(screen, height: point.z)!
            expectClose(back, point, tolerance: 1e-6)
        }
    }

    @Test func skyDoesNotUnproject() {
        let projector = PinholeProjector(state: state(pitch: 75), plane: plane, model: model, viewportSize: viewport, anchor: .zero)
        #expect(projector.unproject(SIMD2(195, 0)) == nil)
    }

    @Test func pointsBehindTheCameraDoNotProject() {
        let projector = PinholeProjector(state: state(pitch: 60), plane: plane, model: model, viewportSize: viewport, anchor: .zero)
        #expect(projector.project(SIMD3(0, -2000, 0)) == nil)
    }
}

/// Screen points recorded from real MapKit (iOS 27.1 Simulator, 402×874 pt view,
/// safe-area anchor (0, 14)) during Spike S1. If MapKit changes its camera, these fail.
struct MapKitFidelityTests {
    struct MapKitObservation {
        var center: GeoCoordinate
        var distance: Double
        var heading: Double
        var pitch: Double
        var points: [(GeoCoordinate, SIMD2<Double>)]
    }

    let plane = MapPlane(origin: GeoCoordinate(latitude: 43.4720, longitude: -80.5440))
    let viewport = SIMD2<Double>(402, 874)
    let anchor = SIMD2<Double>(0, 14)

    let observations = [
        MapKitObservation(center: .init(latitude: 43.47205555122025, longitude: -80.54392102831639), distance: 500, heading: 0, pitch: 0, points: [
            (.init(latitude: 43.473155378980444, longitude: -80.54459361852322), [24.119999999999997, 52.44]),
            (.init(latitude: 43.47249213467474, longitude: -80.54358473321302), [289.44, 292.79]),
            (.init(latitude: 43.47209418459749, longitude: -80.54392102831639), [201, 437]),
            (.init(latitude: 43.471032971580755, longitude: -80.54324843810964), [377.88, 821.56]),
        ]),
        MapKitObservation(center: .init(latitude: 43.47205555122025, longitude: -80.54392102831639), distance: 200.00000000000006, heading: 134.99999999999994, pitch: 50.00000000000001, points: [
            (.init(latitude: 43.471581275301595, longitude: -80.5427383182136), [24.119999999999997, 52.44]),
            (.init(latitude: 43.47176582847503, longitude: -80.54373444821805), [289.44, 292.79]),
            (.init(latitude: 43.47203872370429, longitude: -80.5438978406611), [201, 437]),
            (.init(latitude: 43.47229547343079, longitude: -80.544548643743), [377.88, 821.56]),
        ]),
        MapKitObservation(center: .init(latitude: 43.47205555122025, longitude: -80.54392102831639), distance: 1199.9999999999998, heading: 0, pitch: 69.99999967119774, points: [
            (.init(latitude: 43.49346227033592, longitude: -80.5485048160245), [24.119999999999997, 52.44]),
            (.init(latitude: 43.47600885799827, longitude: -80.54285491844884), [289.44, 292.79]),
            (.init(latitude: 43.472320399749115, longitude: -80.54392102831639), [201, 437]),
            (.init(latitude: 43.467801244196345, longitude: -80.54294143422956), [377.88, 821.56]),
        ]),
        MapKitObservation(center: .init(latitude: 43.47205555122025, longitude: -80.54392102831639), distance: 499.99999999999994, heading: 135.00000000000003, pitch: 29.999999999999996, points: [
            (.init(latitude: 43.47142067627637, longitude: -80.54194511621219), [24.119999999999997, 52.44]),
            (.init(latitude: 43.47149989853328, longitude: -80.54365654304229), [289.44, 292.79]),
            (.init(latitude: 43.47202416274533, longitude: -80.54387777623734), [201, 437]),
            (.init(latitude: 43.47248302079555, longitude: -80.54534727795918), [377.88, 821.56]),
        ]),
    ]

    @Test func measuredModelReproducesMapKitWithinAHundredthOfAPoint() {
        for observation in observations {
            let state = MapCameraState(center: observation.center, distance: observation.distance, heading: observation.heading, pitch: observation.pitch)
            let projector = PinholeProjector(state: state, plane: plane, model: .measured, viewportSize: viewport, anchor: anchor)
            for (coordinate, screen) in observation.points {
                let projected = try! #require(projector.project(plane.point(coordinate)))
                let error = ((projected - screen) * (projected - screen)).sum().squareRoot()
                #expect(error < 0.01, "pitch \(observation.pitch): \(projected) vs MapKit \(screen)")
            }
        }
    }
}
