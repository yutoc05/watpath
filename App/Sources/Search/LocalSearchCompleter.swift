import CampusGeo
import MapKit
import Observation

/// Apple's search for places outside our campus data (addresses, shops, transit),
/// biased to the area around campus.
@Observable
final class LocalSearchCompleter: NSObject, MKLocalSearchCompleterDelegate {
    private(set) var results: [MKLocalSearchCompletion] = []

    @ObservationIgnored private let completer = MKLocalSearchCompleter()
    @ObservationIgnored private let region: MKCoordinateRegion

    init(around center: GeoCoordinate) {
        region = MKCoordinateRegion(center: center.clCoordinate, latitudinalMeters: 5_000, longitudinalMeters: 5_000)
        super.init()
        completer.delegate = self
        completer.region = region
        completer.resultTypes = [.address, .pointOfInterest]
    }

    func update(query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else {
            completer.cancel()
            results = []
            return
        }
        completer.queryFragment = trimmed
    }

    /// Looks up the coordinate behind a completion.
    func resolve(_ completion: MKLocalSearchCompletion) async -> MapItemPlace? {
        let request = MKLocalSearch.Request(completion: completion)
        request.region = region
        guard let item = try? await MKLocalSearch(request: request).start().mapItems.first else { return nil }
        return MapItemPlace(item)
    }

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        results = completer.results
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: any Error) {
        results = []
    }
}
