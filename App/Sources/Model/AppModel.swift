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
        /// The 3D campus model on black, as if seeing through walls.
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
    /// Path Map: floors the user picked (building code → index into its floors).
    /// Every other building shows its default floor, so one floor each.
    private(set) var floorChoices: [String: Int] = [:]
    /// Path Map: the building under the middle of the map, as the map reports it.
    var centeredBuilding: String?
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

    // MARK: Floors

    /// The building the floor picker controls: the selected building (or the
    /// selected door's), else the one in the middle of the Path Map.
    var focusedBuilding: Building? {
        switch selection {
        case .campus(.building(let code)): campus.building(code: code)
        case .campus(.door(let id)): campus.door(id: id).flatMap { campus.building(code: $0.building) }
        default: centeredBuilding.flatMap { campus.building(code: $0) }
        }
    }

    /// The Path Map floor shown for `building`, or nil if it has none (it's drawn as a footprint).
    func displayedFloorIndex(of building: Building) -> Int? {
        floorChoices[building.code] ?? building.defaultFloorIndex
    }

    /// Only floors the Path Map shows can be picked.
    func showFloor(_ index: Int, of building: Building) {
        guard building.mappedFloorIndices.contains(index) else { return }
        floorChoices[building.code] = index == building.defaultFloorIndex ? nil : index
    }

    /// The floor shown for every building with Path Map floors, by code.
    var displayedFloors: [String: Int] {
        Dictionary(uniqueKeysWithValues: campus.buildings.compactMap { building in
            displayedFloorIndex(of: building).map { (building.code, $0) }
        })
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
