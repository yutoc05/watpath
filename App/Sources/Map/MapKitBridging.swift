import CampusGeo
import MapKit

nonisolated extension GeoCoordinate {
    init(_ coordinate: CLLocationCoordinate2D) {
        self.init(latitude: coordinate.latitude, longitude: coordinate.longitude)
    }

    var clCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

nonisolated extension MapCameraState {
    init(_ camera: MKMapCamera) {
        self.init(
            center: GeoCoordinate(camera.centerCoordinate),
            distance: camera.centerCoordinateDistance,
            heading: camera.heading,
            pitch: Double(camera.pitch)
        )
    }
}
