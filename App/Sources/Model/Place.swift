import CampusGeo
import CampusModel
import MapKit

/// Anything the user can select, search for, or keep in Recents. Plain data, so it
/// isn't tied to the main actor (Recents encodes it off the UI).
nonisolated enum Place: Hashable, Codable, Sendable {
    case campus(PlaceReference)
    /// A result from Apple's search, for places our campus data doesn't cover.
    case mapItem(MapItemPlace)
    case droppedPin(GeoCoordinate)
    /// Where the phone is. Only ever a route's origin, so it's never kept in Recents.
    case currentLocation(GeoCoordinate)
}

/// The parts of an `MKMapItem` we keep, as plain values so they can be stored.
nonisolated struct MapItemPlace: Hashable, Codable, Sendable {
    var name: String
    var address: String?
    var coordinate: GeoCoordinate

    init(_ item: MKMapItem) {
        name = item.name ?? "Unnamed place"
        address = item.address?.shortAddress ?? item.address?.fullAddress
        coordinate = GeoCoordinate(item.location.coordinate)
    }
}

/// What a place looks like in lists, cards and on the map.
struct PlaceSummary {
    var title: String
    var subtitle: String
    var systemImage: String
    var coordinate: GeoCoordinate
}

extension Place {
    func summary(in campus: CampusBundle) -> PlaceSummary? {
        switch self {
        case .campus(.building(let code)):
            guard let building = campus.building(code: code) else { return nil }
            return PlaceSummary(title: building.name, subtitle: building.code, systemImage: "building.2.fill", coordinate: building.center)
        case .campus(.door(let id)):
            guard let door = campus.door(id: id), let building = campus.building(code: door.building) else { return nil }
            return PlaceSummary(title: door.name, subtitle: "\(building.code) · \(building.name)", systemImage: "door.left.hand.open", coordinate: door.coordinate)
        case .mapItem(let item):
            return PlaceSummary(title: item.name, subtitle: item.address ?? "", systemImage: "mappin", coordinate: item.coordinate)
        case .droppedPin(let coordinate):
            return PlaceSummary(title: "Dropped Pin", subtitle: coordinate.formatted, systemImage: "mappin.and.ellipse", coordinate: coordinate)
        case .currentLocation(let coordinate):
            return PlaceSummary(title: "Current Location", subtitle: "", systemImage: "location.fill", coordinate: coordinate)
        }
    }
}

nonisolated extension Building {
    /// Middle of the building's outline, for labels and camera framing.
    var center: GeoCoordinate {
        let points = parts.flatMap { $0.outline.dropLast() }
        let count = Double(max(points.count, 1))
        return GeoCoordinate(
            latitude: points.reduce(0) { $0 + $1.latitude } / count,
            longitude: points.reduce(0) { $0 + $1.longitude } / count
        )
    }
}

nonisolated extension GeoCoordinate {
    /// "43.47213, -80.54392": about 1 m precision, the way Apple Maps shows dropped pins.
    var formatted: String {
        String(format: "%.5f, %.5f", latitude, longitude)
    }
}
