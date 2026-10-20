import CampusGeo
import Testing

struct CameraCalibrationTests {
    let plane = MapPlane(origin: GeoCoordinate(latitude: 43.4720, longitude: -80.5440))
    let viewport = SIMD2<Double>(390, 844)
    let truth = MapKitCameraModel(verticalFieldOfView: 30, altitudeScale: 1.002)
    let trueAnchor = SIMD2<Double>(0, 6.5)

    /// Fake MapKit: projects a ground grid with the "true" model.
    func syntheticSamples() -> [CalibrationSample] {
        var samples: [CalibrationSample] = []
        let center = SIMD2<Double>(120, -80)
        for pitch in [0.0, 30, 50, 70] {
            for heading in [0.0, 140] {
                let camera = MapCameraState(center: plane.coordinate(fromPlanar: center), distance: 900, heading: heading, pitch: pitch)
                let projector = PinholeProjector(state: camera, plane: plane, model: truth, viewportSize: viewport, anchor: trueAnchor)
                var points: [Correspondence] = []
                for dx in stride(from: -150.0, through: 150, by: 50) {
                    for dy in stride(from: -150.0, through: 150, by: 50) {
                        let coordinate = plane.coordinate(fromPlanar: center + SIMD2(dx, dy))
                        guard let screen = projector.project(plane.point(coordinate)),
                              (0...viewport.x).contains(screen.x), (0...viewport.y).contains(screen.y)
                        else { continue }
                        points.append(Correspondence(coordinate: coordinate, screen: screen))
                    }
                }
                samples.append(CalibrationSample(camera: camera, viewportSize: viewport, points: points))
            }
        }
        return samples
    }

    @Test func truthHasZeroError() {
        let result = CameraCalibrator.evaluate(model: truth, anchor: trueAnchor, samples: syntheticSamples(), plane: plane)
        #expect(result.rmsError < 1e-6)
        #expect(result.pointCount > 100)
    }

    @Test func solverRecoversKnownModelAndAnchor() {
        let result = CameraCalibrator.solve(samples: syntheticSamples(), plane: plane)
        #expect(abs(result.model.verticalFieldOfView - truth.verticalFieldOfView) < 0.01)
        #expect(abs(result.model.altitudeScale - truth.altitudeScale) < 0.0005)
        #expect(abs(result.anchor.x - trueAnchor.x) < 0.05)
        #expect(abs(result.anchor.y - trueAnchor.y) < 0.05)
        #expect(result.rmsError < 0.01)
    }

    @Test func nelderMeadFindsRosenbrockMinimum() {
        let result = NelderMead.minimize(start: [-1.2, 1], step: [0.5, 0.5]) { p in
            let (x, y) = (p[0], p[1])
            return (1 - x) * (1 - x) + 100 * (y - x * x) * (y - x * x)
        }
        #expect(abs(result.point[0] - 1) < 1e-4)
        #expect(abs(result.point[1] - 1) < 1e-4)
    }
}
