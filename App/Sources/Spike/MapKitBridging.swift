import CampusGeo
import MapKit

extension GeoCoordinate {
    init(_ coordinate: CLLocationCoordinate2D) {
        self.init(latitude: coordinate.latitude, longitude: coordinate.longitude)
    }

    var clCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

extension MapCameraState {
    init(_ camera: MKMapCamera) {
        self.init(
            center: GeoCoordinate(camera.centerCoordinate),
            distance: camera.centerCoordinateDistance,
            heading: camera.heading,
            pitch: Double(camera.pitch)
        )
    }
}

/// RealityKit is y-up with -z forward; our ENU frame is z-up. (east, north, up)
/// maps to RealityKit (x, y, z) = (east, up, -north), a proper rotation.
enum RenderSpace {
    static func point(_ p: SIMD3<Double>) -> SIMD3<Float> {
        SIMD3(Float(p.x), Float(p.z), Float(-p.y))
    }
}
