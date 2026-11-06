import CampusGeo
import Testing

struct GroundProjectionTests {
    private let plane = MapPlane(origin: GeoCoordinate(latitude: 43.472, longitude: -80.544))

    private func projector(distance: Double = 500, pitch: Double = 0, heading: Double = 30) -> PinholeProjector {
        PinholeProjector(
            state: MapCameraState(center: GeoCoordinate(latitude: 43.472, longitude: -80.544), distance: distance, heading: heading, pitch: pitch),
            plane: plane,
            model: .measured,
            viewportSize: SIMD2(390, 844),
            anchor: SIMD2(0, 20)
        )
    }

    @Test func agreesWithThePinholeProjector() throws {
        let projector = projector(pitch: 60)
        let ground = GroundProjection(projector)
        let points: [SIMD2<Double>] = [SIMD2(0, 0), SIMD2(120, -40), SIMD2(-300, 250)]
        let screen = try #require(ground.project(line: points).first)
        for (point, projected) in zip(points, screen) {
            let expected = try #require(projector.project(SIMD3(point.x, point.y, 0)))
            #expect(abs(projected.x - expected.x) < 1e-6 && abs(projected.y - expected.y) < 1e-6)
        }
    }

    @Test func keepsEveryPointOfARingInView() {
        let ring: [SIMD2<Double>] = [SIMD2(-10, -10), SIMD2(10, -10), SIMD2(10, 10), SIMD2(-10, 10), SIMD2(-10, -10)]
        #expect(GroundProjection(projector()).project(ring: ring).count == ring.count)
    }

    /// A camera 100 m out at 75° has the ground behind it well within campus.
    private var tilted: PinholeProjector { projector(distance: 100, pitch: 75, heading: 0) }

    @Test func clipsARingThatCrossesBehindTheCamera() throws {
        let projector = tilted
        // A long building running from ahead of the camera to far behind it.
        let ring: [SIMD2<Double>] = [SIMD2(-20, 100), SIMD2(20, 100), SIMD2(20, -2_000), SIMD2(-20, -2_000), SIMD2(-20, 100)]
        let screen = GroundProjection(projector).project(ring: ring)
        #expect(!screen.isEmpty)
        // The near end becomes two points where the sides cross the cutoff; nothing is lost
        // ahead of the camera, and nothing is flung to the wrong side of the screen.
        let middle = projector.viewportSize.x / 2
        #expect(screen.contains { $0.x < middle } && screen.contains { $0.x > middle })
        #expect(screen.allSatisfy { $0.x.isFinite && $0.y.isFinite })
    }

    @Test func dropsARingEntirelyBehindTheCamera() {
        let ring: [SIMD2<Double>] = [SIMD2(-20, -2_000), SIMD2(20, -2_000), SIMD2(20, -2_100), SIMD2(-20, -2_000)]
        #expect(GroundProjection(tilted).project(ring: ring).isEmpty)
    }

    @Test func aLineStopsAtTheCameraAndResumesPastIt() {
        let ground = GroundProjection(tilted)
        let cut = ground.project(line: [SIMD2(0, 100), SIMD2(0, -2_000)])
        #expect(cut.count == 1 && cut[0].count == 2)
        let there = ground.project(line: [SIMD2(0, 100), SIMD2(0, -2_000), SIMD2(30, 100)])
        #expect(there.count == 2)
        #expect(ground.project(line: [SIMD2(0, -2_000), SIMD2(30, -2_000)]).isEmpty)
    }
}
