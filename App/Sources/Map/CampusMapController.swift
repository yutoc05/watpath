import CampusGeo
import CampusModel
import MapKit
import Routing
import UIKit
import os

/// The campus map in both modes. MapKit owns gestures and the camera in both, so
/// switching modes never moves it. In Path mode an opaque view covers the map, redrawn
/// from MapKit's camera every frame (ADR-002).
///
/// It reports user actions through closures and takes app state through `apply…`;
/// it never owns app state itself.
final class CampusMapController: UIView, MKMapViewDelegate, UIGestureRecognizerDelegate {
    /// Doors appear once the camera is closer than this; above it they'd clutter the map.
    private static let doorsVisibleBelowDistance = PathMapView.doorsVisibleBelowDistance
    /// How long Street and Path take to cross-fade.
    private static let fadeSeconds = 0.25
    /// Search field plus padding at the top of the map.
    private static let searchFieldClearance = 66.0
    private static let logger = Logger(subsystem: "ca.yutochau.watpath", category: "map")
    /// How far inside a building "choose location inside the path" puts the pin.
    private static let snapInset = 3.0
    /// Picking a spot indoors means seeing the lines, so the map comes in at least this close.
    private static let pickingDistance = 700.0
    /// How close to look when the pin starts where the phone is.
    private static let hereDistance = 400.0
    /// How far to look down on the destination when navigation ends.
    private static let arrivalDistance = 400.0
    /// Margin around a route shown whole, in points.
    private static let routeMargin = CGSize(width: 64, height: 36)
    /// How close and how far to come when framing a route, in meters.
    private static let routeDistances = 180.0...3_000.0

    let mapView = MKMapView()
    var onSelect: ((Place?) -> Void)?
    /// While picking a location: the coordinate under the pin, as the map moves.
    var onPickerCoordinateChange: ((GeoCoordinate) -> Void)?
    /// Screen point (in this view) where MapKit keeps the camera center.
    var onAnchorChange: ((CGPoint) -> Void)?
    /// While navigating: what's left of the route, whenever the card would show a change.
    var onNavigationStatus: ((AppModel.NavigationStatus, Bool) -> Void)?
    /// Height of the card over the bottom of the map; selections and routes are framed above it.
    var cardHeight = 300.0 {
        didSet {
            if cardHeight != oldValue { frameSelectedRoute() }
        }
    }
    /// While set, tapping the map selects nothing: it's busy showing something else.
    var isSelectionLocked = false
    /// The pin's "nearest walkable point" while picking where you are, rather than the
    /// nearest point in a building.
    var pickerSnapsToLines = false
    var isPicking = false {
        didSet {
            guard isPicking, !oldValue else { return }
            snapPickerIntoPathIfNeeded()
            if pickerSnapsToLines { comeCloseEnoughToPick() }
            let center = GeoCoordinate(mapView.centerCoordinate)
            Task { @MainActor [weak self] in self?.onPickerCoordinateChange?(center) }
        }
    }

    private let campus: CampusBundle
    private let plane: MapPlane
    private lazy var controls = MapControlsView(mapView: mapView)
    private let pathMap: PathMapView
    private let navigationOverlay = NavigationOverlayView()
    private var mode = AppModel.MapMode.street
    /// Whether the Path Map is, or is fading, in. Navigation shows the Street Map outdoors.
    private var pathMapIsUp = false
    private var displayLink: CADisplayLink?
    private var lastFrame: CFTimeInterval?
    /// Fully covering the Street Map, with no fade under way.
    private var pathMapIsOpaque = false
    /// Everything that moves during navigation. Nil the rest of the time.
    private var rig: NavigationRig?
    /// The camera while navigating. It's kept here because MapKit doesn't always hear it:
    /// see `advanceNavigation`.
    private var navigationCamera: MapCameraState?
    /// The camera's trip to the start of the route.
    private var flight: CameraFlight?
    private var reportedStatus: AppModel.NavigationStatus?
    private var reportedAtEnd = false
    private let scrubPan = UIPanGestureRecognizer()
    /// A touch coming down, which catches a flick before any drag has started.
    private let scrubHold = UILongPressGestureRecognizer()
    private let pathPan = UIPanGestureRecognizer()
    /// While panning the Path Map: the map-plane point the finger is holding.
    private var pathPanAnchor: SIMD2<Double>?
    private let doorAnnotations: [String: DoorAnnotation]
    /// Building outlines on the map plane, for hit-testing taps and snapping.
    private let outlines: [(code: String, rings: [[SIMD2<Double>]])]
    /// Everything the Path Map draws a line for, and the buildings with none of those
    /// inside: the places a pin can stand when it needs to be somewhere walkable.
    private let walkableLines: [[SIMD2<Double>]]
    private let linelessOutlines: [[[SIMD2<Double>]]]
    private var doorsShown = false
    private var highlight: MKMultiPolygon?
    private var pin: MKPointAnnotation?
    private var appliedSelection: Place?
    private var appliedCameraRequest: UUID?
    private var appliedRoutePreview: AppModel.RoutePreview?
    private var routeOverlays: [RouteOverlay] = []
    private var routeStart: MKPointAnnotation?
    /// Set while we change MapKit's selection ourselves, so delegate callbacks
    /// don't echo it back as a user action.
    private var isApplyingSelection = false

    init(campus: CampusBundle) {
        let plane = MapPlane(origin: campus.origin)
        self.campus = campus
        self.plane = plane
        pathMap = PathMapView(campus: campus, plane: plane)
        doorAnnotations = Dictionary(uniqueKeysWithValues: campus.doors.map { ($0.id, DoorAnnotation(door: $0)) })
        outlines = campus.buildings.map { building in
            (building.code, building.parts.flatMap { part in ([part.outline] + part.holes).map { $0.map(plane.planar) } })
        }
        let lines = (campus.corridors + campus.connections.flatMap { $0.paths.map(\.points) }).map { $0.map(plane.planar) }
        walkableLines = lines
        linelessOutlines = outlines.map(\.rings).filter { rings in
            !lines.contains { line in line.contains { PolygonGeometry.contains(rings, $0) } }
        }
        super.init(frame: .zero)

        mapView.delegate = self
        mapView.preferredConfiguration = MKStandardMapConfiguration(elevationStyle: .realistic)
        mapView.showsUserLocation = true
        mapView.register(DoorMarkerView.self, forAnnotationViewWithReuseIdentifier: DoorMarkerView.reuseIdentifier)
        mapView.register(MKMarkerAnnotationView.self, forAnnotationViewWithReuseIdentifier: Self.pinReuseIdentifier)
        mapView.register(RouteStartMarkerView.self, forAnnotationViewWithReuseIdentifier: RouteStartMarkerView.reuseIdentifier)
        mapView.camera = MKMapCamera(lookingAtCenter: Self.campusCenter(campus).clCoordinate, fromDistance: 2_400, pitch: 0, heading: 0)
        addSubview(mapView)

        pathMap.alpha = 0
        pathMap.isHidden = true
        addSubview(pathMap)
        addSubview(navigationOverlay)

        controls.translatesAutoresizingMaskIntoConstraints = false
        addSubview(controls)
        NSLayoutConstraint.activate([
            controls.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 72),
            controls.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -12),
        ])

        // Single taps select buildings. Our own double-tap recognizer makes single taps
        // wait for it to fail, so MapKit's double-tap zoom doesn't also select.
        let doubleTap = UITapGestureRecognizer(target: nil, action: nil)
        doubleTap.numberOfTapsRequired = 2
        doubleTap.cancelsTouchesInView = false
        doubleTap.delegate = self
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        tap.require(toFail: doubleTap)
        tap.delegate = self
        mapView.addGestureRecognizer(doubleTap)
        mapView.addGestureRecognizer(tap)

        pathPan.addTarget(self, action: #selector(handlePathPan))
        pathPan.isEnabled = false
        pathPan.delegate = self
        mapView.addGestureRecognizer(pathPan)

        scrubPan.addTarget(self, action: #selector(handleScrub))
        scrubPan.isEnabled = false
        // On this view, not the map, which is hidden for much of a walk.
        scrubPan.delegate = self
        addGestureRecognizer(scrubPan)
        scrubHold.addTarget(self, action: #selector(handleScrubHold))
        scrubHold.minimumPressDuration = 0
        scrubHold.cancelsTouchesInView = false
        scrubHold.isEnabled = false
        scrubHold.delegate = self
        addGestureRecognizer(scrubHold)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        for view in [mapView, pathMap, navigationOverlay] as [UIView] { view.frame = bounds }
        reportAnchor()
        syncOverlays()
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        reportAnchor()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        displayLink?.invalidate()
        displayLink = nil
        guard window != nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(displayFrame))
        link.add(to: .main, forMode: .common)
        displayLink = link
        lastFrame = nil
    }

    // MARK: Applying app state

    func apply(mode newMode: AppModel.MapMode, animated: Bool) {
        guard newMode != mode else { return }
        mode = newMode
        enableMapGestures()
        showPathMap(mode == .path, animated: animated)
        updateDoorVisibility()
        if mode == .path {
            mapView.removeAnnotations(Array(doorAnnotations.values))
        } else {
            showSelectedDoor()
        }
        if isPicking { snapPickerIntoPathIfNeeded() }
    }

    func apply(selection: Place?) {
        guard selection != appliedSelection else { return }
        appliedSelection = selection
        isApplyingSelection = true
        defer { isApplyingSelection = false }

        clearHighlight()
        if let pin { mapView.removeAnnotation(pin) }
        pin = nil
        for annotation in mapView.selectedAnnotations {
            mapView.deselectAnnotation(annotation, animated: true)
            if !doorsShown, annotation is DoorAnnotation { mapView.removeAnnotation(annotation) }
        }

        switch selection {
        case .campus(.building(let code)):
            guard let building = campus.building(code: code) else { break }
            let overlay = Self.polygons(of: building)
            mapView.addOverlay(overlay, level: .aboveRoads)
            highlight = overlay
        case .campus(.door):
            showSelectedDoor()
        case .mapItem(let item):
            dropPin(at: item.coordinate, title: item.name)
        case .droppedPin(let coordinate), .currentLocation(let coordinate):
            dropPin(at: coordinate, title: "Dropped Pin")
        case nil:
            break
        }
    }

    /// Re-adds the highlight, the only way to make MapKit restyle an overlay.
    private func redrawHighlight() {
        guard let highlight else { return }
        mapView.removeOverlay(highlight)
        mapView.addOverlay(highlight, level: .aboveRoads)
    }

    /// Fades the Path Map in or out over the Street Map. The camera doesn't move.
    private func showPathMap(_ show: Bool, animated: Bool) {
        guard show != pathMapIsUp else { return }
        pathMapIsUp = show
        pathMapIsOpaque = false
        if show {
            pathMap.isHidden = false
            syncOverlays()
        }
        UIView.animate(withDuration: animated ? Self.fadeSeconds : 0, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.pathMap.alpha = show ? 1 : 0
        } completion: { _ in
            if !self.pathMapIsUp { self.pathMap.isHidden = true }
            self.pathMapIsOpaque = self.pathMapIsUp && self.pathMap.alpha == 1
        }
    }

    /// Who moves the map: nobody but the scrub gesture while navigating, and otherwise
    /// MapKit, except for the Path Map's own one-finger pan.
    private func enableMapGestures() {
        let navigating = rig != nil
        mapView.isScrollEnabled = !navigating && mode == .street
        mapView.isZoomEnabled = !navigating
        mapView.isRotateEnabled = !navigating
        mapView.isPitchEnabled = !navigating
        pathPan.isEnabled = !navigating && mode == .path
        scrubPan.isEnabled = navigating
        scrubHold.isEnabled = navigating
    }

    private func clearHighlight() {
        if let highlight { mapView.removeOverlay(highlight) }
        highlight = nil
    }

    func apply(cameraRequest: AppModel.CameraRequest?) {
        guard let cameraRequest, cameraRequest.id != appliedCameraRequest else { return }
        appliedCameraRequest = cameraRequest.id
        guard let summary = cameraRequest.place.summary(in: campus) else { return }
        let camera = switch cameraRequest.place {
        case .campus(.building(let code)): camera(showing: summary.coordinate, distance: campus.building(code: code).map(framingDistance) ?? 400)
        case .campus(.door): camera(showing: summary.coordinate, distance: 280)
        case .mapItem, .droppedPin: camera(showing: summary.coordinate, distance: 700)
        case .currentLocation:
            // The pin sits at the map's center, so this goes there, not above a card.
            MKMapCamera(lookingAtCenter: summary.coordinate.clCoordinate, fromDistance: Self.hereDistance, pitch: mapView.camera.pitch, heading: mapView.camera.heading)
        }
        mapView.setCamera(camera, animated: true)
    }

    /// Shows routes on both maps, or clears them with nil, and frames the picked one.
    func apply(routePreview: AppModel.RoutePreview?) {
        guard routePreview != appliedRoutePreview else { return }
        let highlightChanges = (routePreview == nil) != (appliedRoutePreview == nil)
        appliedRoutePreview = routePreview
        if highlightChanges { redrawHighlight() }
        let selected = routePreview?.routes.first { $0.id == routePreview?.selected }
        let others = routePreview?.routes.filter { $0.id != routePreview?.selected } ?? []

        pathMap.show(route: selected, alternatives: others, plane: plane)

        mapView.removeOverlays(routeOverlays)
        // In order, so the picked route ends up on top.
        routeOverlays = (others + (selected.map { [$0] } ?? [])).map { route in
            RouteOverlay(route: route, isSelected: route.id == selected?.id)
        }
        mapView.addOverlays(routeOverlays, level: .aboveLabels)

        if let routeStart { mapView.removeAnnotation(routeStart) }
        routeStart = nil
        if let start = selected?.points.first {
            let annotation = MKPointAnnotation()
            annotation.coordinate = start.clCoordinate
            mapView.addAnnotation(annotation)
            routeStart = annotation
        }
        updateDoorVisibility()
        frameSelectedRoute()
    }

    /// Fits the picked route between the top of the map and the card, seen from above.
    private func frameSelectedRoute() {
        guard let preview = appliedRoutePreview, let route = preview.routes.first(where: { $0.id == preview.selected }) else { return }
        let band = visibleBand.insetBy(dx: Self.routeMargin.width, dy: Self.routeMargin.height)
        guard band.height > 40, bounds.height > 0 else { return }

        // The route's extent along the screen's axes, which the heading turns.
        let heading = mapView.camera.heading * .pi / 180
        let right = SIMD2(cos(heading), -sin(heading)), up = SIMD2(sin(heading), cos(heading))
        let points = route.points.map(plane.planar)
        let across = points.map { ($0 * right).sum() }, along = points.map { ($0 * up).sum() }
        guard let west = across.min(), let east = across.max(), let south = along.min(), let north = along.max() else { return }
        let middle = right * ((west + east) / 2) + up * ((south + north) / 2)

        // Looking straight down, the screen's height covers 2·altitude·tan(FOV/2) of ground.
        let model = MapKitCameraModel.measured
        let metersPerPoint = max((east - west) / Double(band.width), (north - south) / Double(band.height))
        let distance = metersPerPoint * Double(bounds.height) / (2 * model.altitudeScale * tan(model.verticalFieldOfView * .pi / 360))
        let clamped = min(max(distance, Self.routeDistances.lowerBound), Self.routeDistances.upperBound)
        mapView.setCamera(camera(showing: plane.coordinate(fromPlanar: middle), distance: clamped, pitch: 0), animated: true)
    }

    // MARK: Path Map

    @objc private func displayFrame(_ link: CADisplayLink) {
        // A frame's real length, so a dropped one doesn't slow the walker down.
        let seconds = lastFrame.map { min(link.timestamp - $0, 0.1) } ?? 0
        lastFrame = link.timestamp
        if rig != nil { advanceNavigation(seconds: seconds) }
        syncOverlays()
    }

    /// Redraws what we draw ourselves from MapKit's current camera.
    private func syncOverlays() {
        guard bounds.height > 0, !pathMap.isHidden || rig != nil else { return }
        let state = currentCamera
        let projector = projector(for: state)
        if !pathMap.isHidden {
            pathMap.update(
                projector: projector,
                plane: plane,
                distance: state.distance,
                // Close up, a highlighted destination would fill the screen. The flag marks it.
                selection: rig == nil ? appliedSelection : nil,
                userLocation: mapView.userLocation.location
            )
        }
        if let pose = rig?.pose { navigationOverlay.update(projector: projector, pose: pose) }
    }

    /// The camera everything we draw is drawn from.
    private var currentCamera: MapCameraState {
        navigationCamera ?? MapCameraState(mapView.camera)
    }

    private func projector(for state: MapCameraState) -> PinholeProjector {
        PinholeProjector(state: state, plane: plane, model: .measured, viewportSize: viewportSize, anchor: cameraAnchor)
    }

    /// "Choose location inside the path": if the pin is out in the black, slide the
    /// map so the pin lands just inside the nearest building or, when it's marking where
    /// you are, on the nearest place you could be walking.
    private func snapPickerIntoPathIfNeeded() {
        guard isPicking, mode == .path else { return }
        let center = plane.planar(GeoCoordinate(mapView.centerCoordinate))
        guard !outlines.contains(where: { PolygonGeometry.contains($0.rings, center) }) else { return }
        var candidates = (pickerSnapsToLines ? linelessOutlines : outlines.map(\.rings)).map {
            PolygonGeometry.nearestPointInside($0, center, inset: Self.snapInset)
        }
        if pickerSnapsToLines, let onLine = PolygonGeometry.nearestPoint(onLines: walkableLines, to: center) {
            candidates.append(onLine)
        }
        guard let target = candidates.min(by: { length($0 - center) < length($1 - center) }) else { return }
        guard let camera = mapView.camera.copy() as? MKMapCamera else { return }
        camera.centerCoordinate = plane.coordinate(fromPlanar: target).clCoordinate
        mapView.setCamera(camera, animated: true)
    }

    private func comeCloseEnoughToPick() {
        guard mapView.camera.centerCoordinateDistance > Self.pickingDistance, let camera = mapView.camera.copy() as? MKMapCamera else { return }
        camera.centerCoordinateDistance = Self.pickingDistance
        mapView.setCamera(camera, animated: true)
    }

    // MARK: Navigation

    /// Starts navigating `route`, or stops with nil.
    func apply(navigation route: Route?) {
        guard (route == nil) != (rig == nil) else { return }
        if let route {
            let rig = NavigationRig(route: route, plane: plane)
            self.rig = rig
            flight = CameraFlight(from: MapCameraState(mapView.camera), seconds: rig.tuning.flightSeconds)
            reportedStatus = nil
            reportedAtEnd = false
            navigationOverlay.show(track: rig.track, dotSpacing: rig.tuning.dotSpacing)
        } else {
            // MapKit may have slept through the walk, so it hears where it ended first.
            if let navigationCamera { mapView.setCamera(camera(for: navigationCamera), animated: false) }
            mapView.isHidden = false
            navigationCamera = nil
            rig = nil
            flight = nil
            navigationOverlay.hide()
            showPathMap(mode == .path, animated: true)
            // Back to looking at the destination from above, clear of its card.
            if let end = selectionCoordinate { mapView.setCamera(camera(showing: end, distance: Self.arrivalDistance, pitch: 0), animated: true) }
        }
        let navigating = rig != nil
        pathMap.hidesDoors = navigating
        controls.isHidden = navigating
        redrawHighlight()
        enableMapGestures()
        updateDoorVisibility()
    }

    /// Moves the walker and the camera on by a frame.
    private func advanceNavigation(seconds: Double) {
        rig?.advance(seconds: seconds)
        guard let rig, bounds.height > 0 else { return }
        let pose = rig.pose
        var state = cameraState(
            drawing: pose.aim,
            at: SIMD2(Double(bounds.midX), Double(bounds.height) * rig.tuning.walkerHeight),
            distance: rig.tuning.cameraDistance,
            heading: pose.heading,
            pitch: rig.tuning.pitch
        )
        if flight != nil {
            flight?.advance(seconds: seconds)
            state = flight?.state(toward: state) ?? state
            if flight?.isFinished == true { flight = nil }
        }
        navigationCamera = state

        // MapKit would spend most of the frame drawing 3D buildings behind an opaque Path
        // Map, so while nobody can see it, it's hidden and not told about the camera. The
        // route says when an outdoor stretch is coming, in time to wake it first.
        let isNeeded = flight != nil || !pathMapIsOpaque
            || rig.track.isNearOutside(at: pose.distance, within: rig.tuning.streetMapLeadMeters)
        if mapView.isHidden == isNeeded { mapView.isHidden = !isNeeded }
        if isNeeded { mapView.setCamera(camera(for: state), animated: false) }

        showPathMap(!pose.isOutside, animated: true)
        reportNavigation(pose, isAtEnd: rig.isAtEnd)
    }

    private func camera(for state: MapCameraState) -> MKMapCamera {
        MKMapCamera(lookingAtCenter: state.center.clCoordinate, fromDistance: state.distance, pitch: state.pitch, heading: state.heading)
    }

    /// Tells the app only when the card would change, since a report redraws it.
    private func reportNavigation(_ pose: NavigationRig.Pose, isAtEnd: Bool) {
        let status = AppModel.NavigationStatus(
            distanceRemaining: (pose.distanceRemaining / 10).rounded() * 10,
            secondsRemaining: (pose.secondsRemaining / 15).rounded() * 15
        )
        guard status != reportedStatus || isAtEnd != reportedAtEnd else { return }
        reportedStatus = status
        reportedAtEnd = isAtEnd
        Task { @MainActor [weak self] in self?.onNavigationStatus?(status, isAtEnd) }
    }

    /// Meters of route a point of finger movement covers: however much ground it drags
    /// past the walker, so the route tracks the finger, times the gain.
    private var scrubMetersPerPoint: Double {
        guard let rig else { return 0 }
        let screen = SIMD2(Double(bounds.midX), Double(bounds.height) * rig.tuning.walkerHeight)
        let projector = projector(for: currentCamera)
        guard let here = projector.unproject(screen), let next = projector.unproject(screen + SIMD2(0, 1)) else { return 0 }
        return length(SIMD2(here.x - next.x, here.y - next.y)) * rig.tuning.dragGain
    }

    /// A drag down walks forward, the way the ground would move past you. The flight to
    /// the start isn't interrupted: the camera is about to land.
    @objc private func handleScrub(_ recognizer: UIPanGestureRecognizer) {
        guard flight == nil else { return recognizer.setTranslation(.zero, in: self) }
        let scale = scrubMetersPerPoint
        switch recognizer.state {
        case .changed:
            rig?.drag(by: Double(recognizer.translation(in: self).y) * scale)
            recognizer.setTranslation(.zero, in: self)
        case .ended:
            rig?.flick(metersPerSecond: Double(recognizer.velocity(in: self).y) * scale)
        default:
            break
        }
    }

    @objc private func handleScrubHold(_ recognizer: UILongPressGestureRecognizer) {
        if recognizer.state == .began { rig?.hold() }
    }

    // MARK: Framing

    /// Pans (keeping zoom) if `coordinate` is off screen or under the search field or card.
    private func keepVisible(_ coordinate: GeoCoordinate) {
        let point = mapView.convert(coordinate.clCoordinate, toPointTo: self)
        let band = visibleBand.insetBy(dx: 20, dy: 40)
        guard !band.contains(point) else { return }
        mapView.setCamera(camera(showing: coordinate, distance: mapView.camera.centerCoordinateDistance), animated: true)
    }

    /// The part of the screen not covered by the search field or the card.
    private var visibleBand: CGRect {
        let top = safeAreaInsets.top + Self.searchFieldClearance
        let bottom = max(bounds.height - cardHeight, top + 1)
        return CGRect(x: 0, y: top, width: bounds.width, height: bottom - top)
    }

    /// A camera (current pitch and heading) that draws `coordinate` in the middle of
    /// `visibleBand` rather than at MapKit's center. With the camera centered on the
    /// target, find the ground point drawn where we want the target; shifting the
    /// camera by the difference moves the target there, since moving the camera
    /// across a flat map moves everything on screen equally.
    private func camera(showing coordinate: GeoCoordinate, distance: Double, pitch: CGFloat? = nil) -> MKMapCamera {
        let band = visibleBand
        let state = cameraState(
            drawing: plane.planar(coordinate),
            at: SIMD2(Double(band.midX), Double(band.midY)),
            distance: distance,
            heading: mapView.camera.heading,
            pitch: Double(pitch ?? mapView.camera.pitch)
        )
        return MKMapCamera(lookingAtCenter: state.center.clCoordinate, fromDistance: distance, pitch: state.pitch, heading: state.heading)
    }

    /// The camera that draws `target` at the screen point `screen`.
    private func cameraState(drawing target: SIMD2<Double>, at screen: SIMD2<Double>, distance: Double, heading: Double, pitch: Double) -> MapCameraState {
        var state = MapCameraState(center: plane.coordinate(fromPlanar: target), distance: distance, heading: heading, pitch: pitch)
        if let ground = projector(for: state).unproject(screen) {
            state.center = plane.coordinate(fromPlanar: target + (target - SIMD2(ground.x, ground.y)))
        }
        return state
    }

    /// Camera distance that fits the building across a portrait screen. MapKit's
    /// 30° vertical FOV is only ~14° wide on a phone, hence the large factor.
    private func framingDistance(for building: Building) -> Double {
        let points = building.parts.flatMap { $0.outline.map(plane.planar) }
        let minimum = points.reduce(SIMD2(Double.infinity, .infinity)) { pointwiseMin($0, $1) }
        let maximum = points.reduce(SIMD2(-Double.infinity, -.infinity)) { pointwiseMax($0, $1) }
        let size = maximum - minimum
        return min(max(5 * max(size.x, size.y / 2), 250), 1_500)
    }

    /// Where MapKit keeps its center: the middle of the safe area, as an offset from
    /// the view's middle (ADR-001).
    private var cameraAnchor: SIMD2<Double> {
        let insets = mapView.safeAreaInsets
        return SIMD2(Double(insets.left - insets.right) / 2, Double(insets.top - insets.bottom) / 2)
    }

    private var viewportSize: SIMD2<Double> {
        SIMD2(Double(bounds.width), Double(bounds.height))
    }

    // MARK: MKMapViewDelegate

    func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) {
        syncOverlays()  // as soon as MapKit moves, for the least lag behind the finger
        controls.updatePitchButton()
        updateDoorVisibility()
        if isPicking {
            onPickerCoordinateChange?(GeoCoordinate(mapView.centerCoordinate))
        }
    }

    func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
        // Path panning moves the camera every frame; it snaps once the finger lifts.
        guard pathPanAnchor == nil else { return }
        snapPickerIntoPathIfNeeded()
    }

    func mapView(_ mapView: MKMapView, viewFor annotation: any MKAnnotation) -> MKAnnotationView? {
        switch annotation {
        case is DoorAnnotation:
            mapView.dequeueReusableAnnotationView(withIdentifier: DoorMarkerView.reuseIdentifier, for: annotation)
        case let pin as MKPointAnnotation where pin === self.pin:
            mapView.dequeueReusableAnnotationView(withIdentifier: Self.pinReuseIdentifier, for: annotation)
        case let start as MKPointAnnotation where start === routeStart:
            mapView.dequeueReusableAnnotationView(withIdentifier: RouteStartMarkerView.reuseIdentifier, for: annotation)
        default:
            nil  // the user location dot, drawn by MapKit
        }
    }

    func mapView(_ mapView: MKMapView, didSelect annotation: any MKAnnotation) {
        guard !isApplyingSelection, let door = annotation as? DoorAnnotation else { return }
        guard !isSelectionLocked else { return mapView.deselectAnnotation(annotation, animated: false) }
        clearHighlight()
        appliedSelection = .campus(.door(id: door.door.id))
        onSelect?(appliedSelection)
        keepVisible(door.door.coordinate)
    }

    func mapView(_ mapView: MKMapView, rendererFor overlay: any MKOverlay) -> MKOverlayRenderer {
        if let overlay = overlay as? RouteOverlay {
            let renderer = MKPolylineRenderer(polyline: overlay)
            renderer.strokeColor = overlay.isSelected ? PathMapView.routeColor : PathMapView.alternativeRouteColor
            renderer.lineWidth = PathMapView.routeWidth
            return renderer
        }
        guard let overlay = overlay as? MKMultiPolygon else { return MKOverlayRenderer(overlay: overlay) }
        let renderer = MKMultiPolygonRenderer(multiPolygon: overlay)
        renderer.fillColor = .tintColor.withAlphaComponent(0.18)
        // Beside a route, an outline would read as more route.
        renderer.strokeColor = appliedRoutePreview == nil && rig == nil ? .tintColor : nil
        renderer.lineWidth = 2
        return renderer
    }

    // MARK: Gestures

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }

    /// Path mode pans with this instead of MapKit: the ground point under the finger
    /// stays under it, and the map stops dead when the finger lifts. MapKit's own pan
    /// glides on after a fling (with no public switch to stop it). Two fingers pause
    /// it, leaving pinch, rotate and tilt to MapKit.
    @objc private func handlePathPan(_ recognizer: UIPanGestureRecognizer) {
        let point = recognizer.location(in: self)
        switch recognizer.state {
        case .began, .changed:
            guard recognizer.numberOfTouches == 1 else {
                pathPanAnchor = nil
                return
            }
            let projector = projector(for: MapCameraState(mapView.camera))
            guard let under = projector.unproject(SIMD2(Double(point.x), Double(point.y))) else { return }
            guard let anchor = pathPanAnchor else {
                pathPanAnchor = SIMD2(under.x, under.y)
                return
            }
            // Moving the camera across the flat map moves every ground point equally.
            guard let camera = mapView.camera.copy() as? MKMapCamera else { return }
            let center = plane.planar(GeoCoordinate(camera.centerCoordinate)) + anchor - SIMD2(under.x, under.y)
            camera.centerCoordinate = plane.coordinate(fromPlanar: center).clCoordinate
            mapView.setCamera(camera, animated: false)
        default:
            pathPanAnchor = nil
            snapPickerIntoPathIfNeeded()
        }
    }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        guard !isPicking, !isSelectionLocked else { return }
        let point = recognizer.location(in: mapView)
        var ground: SIMD2<Double>? = plane.planar(GeoCoordinate(mapView.convert(point, toCoordinateFrom: mapView)))
        if mode == .path {
            // Path Map doors never take touches (so drags that start on one still move
            // the map): hit-test them here.
            if let id = pathMap.door(at: recognizer.location(in: pathMap)), let door = campus.door(id: id) {
                onSelect?(.campus(.door(id: id)))
                keepVisible(door.coordinate)
                return
            }
            // What's drawn is flat, and may not be where MapKit's terrain would put the tap.
            ground = projector(for: MapCameraState(mapView.camera)).unproject(SIMD2(Double(point.x), Double(point.y))).map { SIMD2($0.x, $0.y) }
        } else {
            // Taps on markers (and the location dot) belong to MapKit's own selection.
            var hit = mapView.hitTest(point, with: nil)
            while let view = hit {
                if view is MKAnnotationView { return }
                hit = view.superview
            }
        }
        let code = ground.flatMap { ground in outlines.first { PolygonGeometry.contains($0.rings, ground) }?.code }
        let selection = code.map { Place.campus(.building(code: $0)) }
        guard selection != appliedSelection else { return }
        onSelect?(selection)
        if let code, let building = campus.building(code: code) {
            keepVisible(building.center)
        }
    }

    // MARK: Helpers

    private static let pinReuseIdentifier = "pin"

    /// MapKit's door markers are the Street Map's, and only zoomed in: above that
    /// they'd clutter the map. A route on show has the map to itself. The Path Map
    /// draws its own.
    private func updateDoorVisibility() {
        let shouldShow = mode == .street && appliedRoutePreview == nil && rig == nil && mapView.camera.centerCoordinateDistance < Self.doorsVisibleBelowDistance
        guard shouldShow != doorsShown else { return }
        doorsShown = shouldShow
        if shouldShow {
            let alreadyShown = Set(mapView.annotations.compactMap { ($0 as? DoorAnnotation)?.door.id })
            mapView.addAnnotations(doorAnnotations.values.filter { !alreadyShown.contains($0.door.id) })
        } else {
            let selected = Set(mapView.selectedAnnotations.compactMap { ($0 as? DoorAnnotation)?.door.id })
            mapView.removeAnnotations(doorAnnotations.values.filter { !selected.contains($0.door.id) })
        }
    }

    /// Shows and selects the selected door's Street Map marker, at any zoom.
    private func showSelectedDoor() {
        guard mode == .street, case .campus(.door(let id)) = appliedSelection, let annotation = doorAnnotations[id] else { return }
        let wasApplying = isApplyingSelection
        isApplyingSelection = true
        defer { isApplyingSelection = wasApplying }
        if !mapView.annotations.contains(where: { $0 === annotation }) { mapView.addAnnotation(annotation) }
        mapView.selectAnnotation(annotation, animated: true)
    }

    private func dropPin(at coordinate: GeoCoordinate, title: String) {
        let annotation = MKPointAnnotation()
        annotation.coordinate = coordinate.clCoordinate
        annotation.title = title
        mapView.addAnnotation(annotation)
        mapView.selectAnnotation(annotation, animated: true)
        pin = annotation
    }

    /// Where the selected place is.
    private var selectionCoordinate: GeoCoordinate? {
        appliedSelection?.summary(in: campus)?.coordinate
    }

    private func reportAnchor() {
        let anchor = CGPoint(x: bounds.midX + cameraAnchor.x, y: bounds.midY + cameraAnchor.y)
        Task { @MainActor [weak self] in self?.onAnchorChange?(anchor) }
    }

    private static func polygons(of building: Building) -> MKMultiPolygon {
        MKMultiPolygon(building.parts.map(polygon))
    }

    private static func polygon(_ part: BuildingPart) -> MKPolygon {
        let holes = part.holes.map { ring in
            let coordinates = ring.map(\.clCoordinate)
            return MKPolygon(coordinates: coordinates, count: coordinates.count)
        }
        let outline = part.outline.map(\.clCoordinate)
        return MKPolygon(coordinates: outline, count: outline.count, interiorPolygons: holes)
    }

    private static func campusCenter(_ campus: CampusBundle) -> GeoCoordinate {
        let centers = campus.buildings.filter { $0.group == .core }.map(\.center)
        let latitudes = centers.map(\.latitude), longitudes = centers.map(\.longitude)
        return GeoCoordinate(
            latitude: ((latitudes.min() ?? 0) + (latitudes.max() ?? 0)) / 2,
            longitude: ((longitudes.min() ?? 0) + (longitudes.max() ?? 0)) / 2
        )
    }
}

private func length(_ v: SIMD2<Double>) -> Double {
    (v * v).sum().squareRoot()
}
