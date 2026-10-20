import CampusGeo
import Testing

struct MapPlaneTests {
    let plane = MapPlane(origin: GeoCoordinate(latitude: 43.4720, longitude: -80.5440))

    @Test func originIsZero() {
        #expect(plane.planar(plane.origin) == .zero)
    }

    @Test func eastIsScaledByCosineOfOriginLatitude() {
        let p = plane.planar(GeoCoordinate(latitude: 43.4720, longitude: -80.5430))
        #expect(abs(p.x - 80.79) < 0.01)  // 6378137 m × cos(43.472°) × 0.001°
        #expect(abs(p.y) < 1e-9)
    }

    @Test func northFollowsSphericalMercator() {
        // Web Mercator on a sphere of radius a: about a × Δφ near the origin, which is
        // 0.2% more than the true ~111.1 m on the ellipsoid. MapKit draws it this way.
        let p = plane.planar(GeoCoordinate(latitude: 43.4730, longitude: -80.5440))
        #expect(abs(p.x) < 1e-9)
        #expect(abs(p.y - 111.32) < 0.01)
    }

    @Test func roundTrip() {
        let coordinate = GeoCoordinate(latitude: 43.4761, longitude: -80.5403)
        let back = plane.coordinate(fromPlanar: plane.planar(coordinate))
        #expect(abs(back.latitude - coordinate.latitude) < 1e-12)
        #expect(abs(back.longitude - coordinate.longitude) < 1e-12)
    }
}
