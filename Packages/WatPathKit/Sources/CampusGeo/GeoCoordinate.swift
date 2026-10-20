/// A WGS84 latitude/longitude in degrees. Mirrors CLLocationCoordinate2D so this
/// module stays free of CoreLocation (and testable on Linux).
public struct GeoCoordinate: Hashable, Sendable, Codable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}
