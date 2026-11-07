import CampusGeo
import CampusModel
import CampusSearch
import CoreLocation
import Foundation
import Observation
import Routing
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
        /// The directions sheet is up: where are you, or which route.
        case directions
        /// Scrubbing along a route.
        case navigating
    }

    /// What's left of the route, as the navigation card shows it.
    struct NavigationStatus: Equatable {
        /// Meters.
        var distanceRemaining: Double
        var secondsRemaining: Double
    }

    /// The routes on the map, and which one is picked.
    struct RoutePreview: Equatable {
        var routes: [Route]
        var selected: Route.ID
    }

    let campus: CampusBundle
    let bundleURL: URL
    let searchIndex: SearchIndex

    private(set) var selection: Place?
    private var browsingActivity = Activity.browsing
    private(set) var directions = DirectionsFlow<Place>()
    private(set) var navigationStatus: NavigationStatus?
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
    /// Built off the main thread at launch, since nothing needs it until directions start.
    @ObservationIgnored private let router: Task<Router?, Never>
    /// Whether the user said "I'm in the PATH", which decides how a pin joins the graph.
    @ObservationIgnored private var originIsInside = false
    private static let logger = Logger(subsystem: "ca.yutochau.watpath", category: "app")

    struct CameraRequest: Equatable {
        let id = UUID()
        let place: Place
    }

    /// What the user is doing right now, whether or not they're getting directions.
    var activity: Activity {
        switch directions.step {
        case .idle: browsingActivity
        case .pickingOriginInPath, .pickingOriginOnMap: .pickingLocation
        case .searchingOrigin: .searching
        case .originPrompt, .findingRoutes, .routes, .noRoutes: .directions
        case .navigating, .arrived: .navigating
        }
    }

    var isAtEndOfRoute: Bool {
        if case .arrived = directions.step { true } else { false }
    }

    var routePreview: RoutePreview? {
        guard case .routes(let routes, let selected) = directions.step else { return nil }
        return RoutePreview(routes: routes, selected: selected)
    }

    /// Where the phone is, if the system knows.
    var currentLocation: GeoCoordinate? {
        locationManager.location.map { GeoCoordinate($0.coordinate) }
    }

    init(campus: CampusBundle, bundleURL: URL) {
        self.campus = campus
        self.bundleURL = bundleURL
        searchIndex = SearchIndex(campus: campus)
        router = Task.detached(priority: .utility) {
            do {
                return try Router(graph: WalkGraph.load(from: bundleURL), campus: campus)
            } catch {
                Logger(subsystem: "ca.yutochau.watpath", category: "app").error("Couldn't load the walking graph: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
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
        browsingActivity = .browsing
        guard let place else { return }
        if focus { cameraRequest = CameraRequest(place: place) }
        if remember { addToRecents(place) }
    }

    func beginSearch() {
        browsingActivity = .searching
    }

    func endSearch() {
        if directions.isActive {
            directions.send(.back)
        } else if browsingActivity == .searching {
            browsingActivity = .browsing
        }
    }

    // MARK: Choose location on map

    /// `insidePath` picks in the Path Map, where the pin snaps into buildings.
    func beginPickingLocation(insidePath: Bool = false) {
        selection = nil
        if insidePath { mapMode = .path }
        browsingActivity = .pickingLocation
    }

    func finishPickingLocation() {
        guard let coordinate = pickerCoordinate else { return cancelPickingLocation() }
        if directions.isActive {
            setOrigin(.droppedPin(coordinate))
        } else {
            select(.droppedPin(coordinate), remember: true)
        }
    }

    func cancelPickingLocation() {
        if directions.isActive {
            directions.send(.back)
        } else {
            browsingActivity = .browsing
        }
    }

    // MARK: Directions

    /// Directions to the selected place.
    func beginDirections() {
        guard let selection else { return }
        directions.send(.chooseDestination(selection))
    }

    /// "I'm in the PATH": a pin in the Path Map, starting where the phone is if that's
    /// inside a building, and otherwise wherever the map already is.
    func chooseInThePath() {
        originIsInside = true
        mapMode = .path
        directions.send(.chooseInPath)
        if let here = currentLocation, isInsideABuilding(here) {
            cameraRequest = CameraRequest(place: .currentLocation(here))
        }
    }

    /// "I'm Outside": search for where you are.
    func chooseOutside() {
        originIsInside = false
        directions.send(.chooseOutside)
    }

    func chooseOriginOnMap() {
        directions.send(.chooseOriginOnMap)
    }

    func setOrigin(_ place: Place, remember: Bool = false) {
        guard let destination = directions.destination else { return }
        if remember { addToRecents(place) }
        directions.send(.setOrigin(place))
        let inside = originIsInside
        Task {
            let router = await router.value
            let routes = await Task.detached(priority: .userInitiated) {
                guard let router, place != destination,
                      let start = router.endpoint(for: place, surface: inside ? .indoors : .outdoors),
                      let end = router.endpoint(for: destination, surface: .outdoors)
                else { return [Route]() }
                return router.routes(from: start, to: end)
            }.value
            directions.send(.found(routes, from: place))
        }
    }

    func selectRoute(_ id: Route.ID) {
        directions.send(.selectRoute(id))
    }

    /// Navigation happens on the Path Map, which steps aside by itself outdoors.
    func startRoute(_ id: Route.ID) {
        mapMode = .path
        directions.send(.startRoute(id))
    }

    /// The map reports this as the walker moves, when anything on the card would change.
    func updateNavigation(_ status: NavigationStatus, isAtEnd: Bool) {
        navigationStatus = status
        if isAtEnd != isAtEndOfRoute {
            directions.send(isAtEnd ? .reachedEnd : .leftEnd)
        }
    }

    /// One step back: from the route list, that's asking where you are again.
    func backInDirections() {
        directions.send(.back)
    }

    func endDirections() {
        directions.send(.cancel)
        navigationStatus = nil
    }

    private func isInsideABuilding(_ coordinate: GeoCoordinate) -> Bool {
        let plane = MapPlane(origin: campus.origin)
        let point = plane.planar(coordinate)
        return campus.buildings.contains { building in
            building.parts.contains { PolygonGeometry.contains(([$0.outline] + $0.holes).map { $0.map(plane.planar) }, point) }
        }
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

    private func addToRecents(_ place: Place) {
        recents.add(place)
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

nonisolated extension Router {
    /// `surface` says where a point outside every building should join the graph.
    func endpoint(for place: Place, surface: Surface) -> Endpoint? {
        switch place {
        case .campus(.building(let code)): endpoint(building: code)
        case .campus(.door(let id)): endpoint(door: id)
        case .mapItem(let item): endpoint(at: item.coordinate, surface: .outdoors)
        case .droppedPin(let coordinate), .currentLocation(let coordinate): endpoint(at: coordinate, surface: surface)
        }
    }
}
