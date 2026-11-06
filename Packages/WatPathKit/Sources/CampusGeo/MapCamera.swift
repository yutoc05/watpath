import Foundation

/// The camera as MapKit reports it (`MKMapCamera`), without depending on MapKit.
public struct MapCameraState: Sendable, Equatable, Codable {
    public var center: GeoCoordinate
    /// `centerCoordinateDistance`, meters.
    public var distance: Double
    /// Degrees clockwise from north.
    public var heading: Double
    /// Degrees from straight down (0) toward the horizon.
    public var pitch: Double

    public init(center: GeoCoordinate, distance: Double, heading: Double, pitch: Double) {
        self.center = center
        self.distance = distance
        self.heading = heading
        self.pitch = pitch
    }
}

/// MapKit's undocumented camera constants, measured by fitting `CameraCalibrator` to
/// points MapKit projected itself (0.000 pt residual; docs/adr/001-camera-architecture.md).
public struct MapKitCameraModel: Sendable, Equatable, Codable {
    /// Full vertical field of view, degrees.
    public var verticalFieldOfView: Double
    /// Camera altitude = `altitudeScale` × distance × cos(pitch), in plane meters.
    public var altitudeScale: Double

    public init(verticalFieldOfView: Double, altitudeScale: Double) {
        self.verticalFieldOfView = verticalFieldOfView
        self.altitudeScale = altitudeScale
    }

    public static let measured = MapKitCameraModel(verticalFieldOfView: 30, altitudeScale: 1.001_995)
}

/// A camera position and orientation on the `MapPlane` (z up).
public struct CameraPose: Sendable, Equatable {
    public var eye: SIMD3<Double>
    public var target: SIMD3<Double>
    /// Unit vectors: screen right, screen up, and the optical axis.
    public var right: SIMD3<Double>
    public var up: SIMD3<Double>
    public var forward: SIMD3<Double>
    /// Focal length in points.
    public var focalLength: Double

    /// The pose MapKit uses for `state`. MapKit aims its optical axis through the
    /// middle of the view, but keeps the center coordinate under `anchor` (the
    /// middle of the safe area, as an offset in points from the view's middle,
    /// y down) and orbits around it. So the eye sits on the ray through the anchor,
    /// at the altitude MapKit's distance implies.
    public init(state: MapCameraState, plane: MapPlane, model: MapKitCameraModel, viewportSize: SIMD2<Double>, anchor: SIMD2<Double>) {
        let heading = state.heading * .pi / 180
        let pitch = state.pitch * .pi / 180
        let horizontalForward = SIMD3(sin(heading), cos(heading), 0)
        let worldUp = SIMD3<Double>(0, 0, 1)

        target = plane.point(state.center)
        forward = sin(pitch) * horizontalForward - cos(pitch) * worldUp
        up = cos(pitch) * horizontalForward + sin(pitch) * worldUp
        right = cross(forward, up)
        focalLength = (viewportSize.y / 2) / tan(model.verticalFieldOfView * .pi / 360)

        var anchorRay = forward + (anchor.x / focalLength) * right - (anchor.y / focalLength) * up
        anchorRay /= dot(anchorRay, anchorRay).squareRoot()
        let altitude = model.altitudeScale * state.distance * cos(pitch)
        eye = target - anchorRay * (altitude / -anchorRay.z)
    }
}

/// Projects plane points to screen points (UIKit convention: origin top-left, y down).
public struct PinholeProjector: Sendable {
    public var pose: CameraPose
    public var viewportSize: SIMD2<Double>

    public init(state: MapCameraState, plane: MapPlane, model: MapKitCameraModel, viewportSize: SIMD2<Double>, anchor: SIMD2<Double>) {
        pose = CameraPose(state: state, plane: plane, model: model, viewportSize: viewportSize, anchor: anchor)
        self.viewportSize = viewportSize
    }

    /// Screen position of `point`, or nil if it's behind the camera.
    public func project(_ point: SIMD3<Double>) -> SIMD2<Double>? {
        let v = point - pose.eye
        let depth = dot(v, pose.forward)
        guard depth > 1e-6 else { return nil }
        let scale = pose.focalLength / depth
        return SIMD2(viewportSize.x / 2 + dot(v, pose.right) * scale, viewportSize.y / 2 - dot(v, pose.up) * scale)
    }

    /// The point at `height` drawn at `screen`, or nil if that pixel shows sky.
    public func unproject(_ screen: SIMD2<Double>, height: Double = 0) -> SIMD3<Double>? {
        let x = (screen.x - viewportSize.x / 2) / pose.focalLength
        let y = (viewportSize.y / 2 - screen.y) / pose.focalLength
        let ray = pose.forward + x * pose.right + y * pose.up
        guard ray.z < -1e-9 else { return nil }
        return pose.eye + ray * ((height - pose.eye.z) / ray.z)
    }
}
