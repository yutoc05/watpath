/// One ground coordinate and the screen point MapKit drew it at.
public struct Correspondence: Sendable, Equatable, Codable {
    public var coordinate: GeoCoordinate
    public var screen: SIMD2<Double>

    public init(coordinate: GeoCoordinate, screen: SIMD2<Double>) {
        self.coordinate = coordinate
        self.screen = screen
    }
}

/// Everything recorded from MapKit at one camera position.
public struct CalibrationSample: Sendable, Codable {
    public var camera: MapCameraState
    public var viewportSize: SIMD2<Double>
    public var points: [Correspondence]

    public init(camera: MapCameraState, viewportSize: SIMD2<Double>, points: [Correspondence]) {
        self.camera = camera
        self.viewportSize = viewportSize
        self.points = points
    }
}

public struct CalibrationResult: Sendable, Codable {
    public var model: MapKitCameraModel
    /// Fitted anchor (points from the view's middle); should match the safe-area center.
    public var anchor: SIMD2<Double>
    /// Reprojection error in points.
    public var rmsError: Double
    public var maxError: Double
    public var pointCount: Int
}

/// Fits `MapKitCameraModel` by matching our camera against points MapKit
/// projected itself (docs/adr/001-camera-architecture.md).
public enum CameraCalibrator {
    /// Error charged for a point the model puts behind the camera.
    private static let behindCameraError = 10_000.0

    /// Reprojection error, in points, of every correspondence.
    public static func errors(
        model: MapKitCameraModel,
        anchor: SIMD2<Double>,
        samples: [CalibrationSample],
        plane: MapPlane
    ) -> [Double] {
        samples.flatMap { sample in
            let projector = PinholeProjector(
                state: sample.camera,
                plane: plane,
                model: model,
                viewportSize: sample.viewportSize,
                anchor: anchor
            )
            return sample.points.map { point in
                guard let projected = projector.project(plane.point(point.coordinate)) else {
                    return behindCameraError
                }
                return length(projected - point.screen)
            }
        }
    }

    public static func evaluate(
        model: MapKitCameraModel,
        anchor: SIMD2<Double>,
        samples: [CalibrationSample],
        plane: MapPlane
    ) -> CalibrationResult {
        let errors = errors(model: model, anchor: anchor, samples: samples, plane: plane)
        let meanSquare = errors.isEmpty ? 0 : errors.reduce(0) { $0 + $1 * $1 } / Double(errors.count)
        return CalibrationResult(
            model: model,
            anchor: anchor,
            rmsError: meanSquare.squareRoot(),
            maxError: errors.max() ?? 0,
            pointCount: errors.count
        )
    }

    /// Fits field of view, altitude scale and anchor. Samples should mix pitches:
    /// looking straight down, field of view and altitude trade off against each
    /// other and only tilted views tell them apart.
    public static func solve(samples: [CalibrationSample], plane: MapPlane, initialAnchor: SIMD2<Double> = .zero) -> CalibrationResult {
        func unpack(_ p: [Double]) -> (MapKitCameraModel, SIMD2<Double>) {
            (MapKitCameraModel(verticalFieldOfView: p[0], altitudeScale: p[1]), SIMD2(p[2], p[3]))
        }
        func meanSquareError(_ p: [Double]) -> Double {
            guard (5.0...120.0).contains(p[0]), (0.05...20.0).contains(p[1]) else { return .greatestFiniteMagnitude }
            let (model, anchor) = unpack(p)
            let errors = errors(model: model, anchor: anchor, samples: samples, plane: plane)
            return errors.reduce(0) { $0 + $1 * $1 } / Double(max(errors.count, 1))
        }

        let step = [5.0, 0.05, 5.0, 5.0]
        var best = [20.0, 35.0, 50.0, 70.0]
            .map { NelderMead.minimize(start: [$0, 1, initialAnchor.x, initialAnchor.y], step: step, meanSquareError) }
            .min { $0.value < $1.value }!
        // Restarting from the best point guards against the simplex collapsing early.
        best = NelderMead.minimize(start: best.point, step: step.map { $0 / 10 }, meanSquareError)
        let (model, anchor) = unpack(best.point)
        return evaluate(model: model, anchor: anchor, samples: samples, plane: plane)
    }
}
