import CampusGeo
import CampusModel
import CampusSearch
import CoreLocation
import Foundation
import Observation
import os

/// App-wide state: what's selected, what the user is doing, and their recents.
/// Views read it; the map controller reports taps and camera moves back into it.
@Observable
final class AppModel {
    enum MapMode: String, CaseIterable, Identifiable, Sendable {
        /// Apple's map with campus doors.
        case street
        /// Buildings and the lines through them on black, as if seeing through walls.
        case path

        var id: Self { self }
    }

    enum Activity: Equatable {
        case browsing
        case searching
        /// "Choose location on map": a pin stays centered while the map moves.
        case pickingLocation
    }

    let campus: CampusBundle
    let bundleURL: URL
    let searchIndex: SearchIndex

    private(set) var selection: Place?
    private(set) var activity = Activity.browsing
    var mapMode = MapMode.street
    /// The camera moves to show this place; a new request (new id) per move.
    private(set) var cameraRequest: CameraRequest?
    /// Map center while picking a location, updated as the map moves.
    var pickerCoordinate: GeoCoordinate?
    /// Screen point where the map keeps its center (the safe-area middle).
    var mapAnchor: CGPoint?
    /// Height of the place card when it first opens.
    static let cardPeekHeight = 300.0
    /// How much of the screen the place card covers, so the map frames places above it.
    var cardHeight = AppModel.cardPeekHeight
    private(set) var recents: RecentList<Place>

    @ObservationIgnored private let locationManager = CLLocationManager()
    @ObservationIgnored private let recentsURL: URL?
    private static let logger = Logger(subsystem: "ca.yutochau.watpath", category: "app")

    struct CameraRequest: Equatable {
        let id = UUID()
        let place: Place
    }

    init(campus: CampusBundle, bundleURL: URL) {
        self.campus = campus
        self.bundleURL = bundleURL
        searchIndex = SearchIndex(campus: campus)
        recentsURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("recents.json")
        recents = RecentList()
        if ProcessInfo.processInfo.arguments.contains("-resetRecents"), let recentsURL {
            try? FileManager.default.removeItem(at: recentsURL)  // UI tests start from a clean slate
        }
        recents = loadRecents()
    }

    // MARK: Selection

    /// Selects `place` (or clears the selection). `focus` moves the camera to it and
    /// `remember` adds it to Recents, both for selections made outside the map.
    func select(_ place: Place?, focus: Bool = false, remember: Bool = false) {
        selection = place
        activity = .browsing
        guard let place else { return }
        if focus { cameraRequest = CameraRequest(place: place) }
        if remember {
            recents.add(place)
            saveRecents()
        }
    }

    func beginSearch() {
        activity = .searching
    }

    func endSearch() {
        if activity == .searching { activity = .browsing }
    }

    // MARK: Choose location on map

    /// `insidePath` picks in the Path Map, where the pin snaps into buildings.
    func beginPickingLocation(insidePath: Bool = false) {
        selection = nil
        if insidePath { mapMode = .path }
        activity = .pickingLocation
    }


    func finishPickingLocation() {
        guard let coordinate = pickerCoordinate else { return cancelPickingLocation() }
        select(.droppedPin(coordinate), remember: true)
    }

    func cancelPickingLocation() {
        activity = .browsing
    }

    // MARK: Location

    func requestLocationPermission() {
        if locationManager.authorizationStatus == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
        }
    }

    // MARK: Recents

    func clearRecents() {
        recents.removeAll()
        saveRecents()
    }

    private func loadRecents() -> RecentList<Place> {
        guard let recentsURL, let data = try? Data(contentsOf: recentsURL) else { return RecentList() }
        do {
            var stored = try JSONDecoder().decode(RecentList<Place>.self, from: data)
            // Doors can disappear when the map data is re-imported.
            for place in stored.items where place.summary(in: campus) == nil {
                stored.remove(place)
            }
            return stored
        } catch {
            Self.logger.error("Discarding unreadable recents: \(error.localizedDescription, privacy: .public)")
            return RecentList()
        }
    }

    private func saveRecents() {
        guard let recentsURL else { return }
        do {
            try FileManager.default.createDirectory(at: recentsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(recents).write(to: recentsURL, options: .atomic)
        } catch {
            Self.logger.error("Couldn't save recents: \(error.localizedDescription, privacy: .public)")
        }
    }
}
