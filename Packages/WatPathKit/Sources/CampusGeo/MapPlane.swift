import Foundation

/// The flat map MapKit actually draws: Web Mercator (spherical formulas applied to
/// WGS84 angles), centered on `origin` and scaled to meters there.
///
/// Everything rendered over MapKit must live in this plane, not in true local
/// meters. Spike S1 measured MapKit's map as 0.355% taller north–south than true
/// ground (exactly Web Mercator's distortion at 43.5°N), which would misplace
/// geometry by ~2 m at the edge of campus (docs/adr/001-camera-architecture.md).
public struct MapPlane: Sendable {
    public let origin: GeoCoordinate

    /// WGS84 semi-major axis: the sphere radius Web Mercator uses.
    private static let earthRadius = 6_378_137.0
    /// Plane meters per radian of longitude (and of Mercator y) at the origin.
    private let metersPerRadian: Double
    private let originMercatorY: Double

    public init(origin: GeoCoordinate) {
        self.origin = origin
        metersPerRadian = Self.earthRadius * cos(origin.latitude * .pi / 180)
        originMercatorY = Self.mercatorY(latitude: origin.latitude)
    }

    /// Position on the plane: x east, y north, in meters near the origin.
    public func planar(_ coordinate: GeoCoordinate) -> SIMD2<Double> {
        SIMD2(
            (coordinate.longitude - origin.longitude) * .pi / 180 * metersPerRadian,
            (Self.mercatorY(latitude: coordinate.latitude) - originMercatorY) * metersPerRadian
        )
    }

    /// Plane position lifted to `height` meters above the campus ground.
    public func point(_ coordinate: GeoCoordinate, height: Double = 0) -> SIMD3<Double> {
        let p = planar(coordinate)
        return SIMD3(p.x, p.y, height)
    }

    /// Inverse of `planar(_:)`.
    public func coordinate(fromPlanar p: SIMD2<Double>) -> GeoCoordinate {
        let mercatorY = p.y / metersPerRadian + originMercatorY
        return GeoCoordinate(
            latitude: (2 * atan(exp(mercatorY)) - .pi / 2) * 180 / .pi,
            longitude: origin.longitude + p.x / metersPerRadian * 180 / .pi
        )
    }

    private static func mercatorY(latitude: Double) -> Double {
        log(tan(.pi / 4 + latitude * .pi / 360))
    }
}
