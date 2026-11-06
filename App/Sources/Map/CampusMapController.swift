import CampusGeo
import CampusModel
import MapKit
import UIKit
import os

/// The campus map in both modes. MapKit owns gestures and the camera, so switching
/// modes never moves it. Path mode draws its ground on the map itself, with lines and
/// labels floating above it, re-placed from MapKit's camera every frame (ADR-002).
///
/// It reports user actions through closures and takes app state through `apply…`;
/// it never owns app state itself.
final class CampusMapController: UIView, MKMapViewDelegate, UIGestureRecognizerDelegate {
    /// Doors appear once the camera is closer than this; above it they'd clutter the map.
    private static let doorsVisibleBelowDistance = PathAnnotationLayer.doorsVisibleBelowDistance
    /// How long Street and Path take to cross-fade.
    private static let fadeSeconds = 0.25
    /// Search field plus padding at the top of the map.
    private static let searchFieldClearance = 66.0
    private static let logger = Logger(subsystem: "ca.yutochau.watpath", category: "map")
    /// How far inside a building "choose location inside the path" puts the pin.
    private static let snapInset = 3.0

    let mapView = MKMapView()
    var onSelect: ((Place?) -> Void)?
    /// While picking a location: the coordinate under the pin, as the map moves.
    var onPickerCoordinateChange: ((GeoCoordinate) -> Void)?
    /// Screen point (in this view) where MapKit keeps the camera center.
    var onAnchorChange: ((CGPoint) -> Void)?
    /// Height of the place card over the bottom of the map; selections are framed above it.
    var cardHeight = 300.0
    var isPicking = false {
        didSet {
            guard isPicking, !oldValue else { return }
            snapPickerIntoPathIfNeeded()
            let center = GeoCoordinate(mapView.centerCoordinate)
            Task { @MainActor [weak self] in self?.onPickerCoordinateChange?(center) }
        }
    }

    private let campus: CampusBundle
    private let plane: MapPlane
    private lazy var controls = MapControlsView(mapView: mapView)
    private let pathOverlays: PathOverlays
    private let annotationLayer: PathAnnotationLayer
    private var mode = AppModel.MapMode.street
    private var displayLink: CADisplayLink?
    private let pathPan = UIPanGestureRecognizer()
    /// While panning the Path Map: the map-plane point the finger is holding.
    private var pathPanAnchor: SIMD2<Double>?
    private let doorAnnotations: [String: DoorAnnotation]
    /// Building outlines on the map plane, for hit-testing taps and snapping.
    private let outlines: [(code: String, rings: [[SIMD2<Double>]])]
    private var doorsShown = false
    private var highlight: MKMultiPolygon?
    private var pin: MKPointAnnotation?
    private var appliedSelection: Place?
    private var appliedCameraRequest: UUID?
    /// Set while we change MapKit's selection ourselves, so delegate callbacks
    /// don't echo it back as a user action.
    private var isApplyingSelection = false

    init(campus: CampusBundle) {
        let plane = MapPlane(origin: campus.origin)
        self.campus = campus
        self.plane = plane
        pathOverlays = PathOverlays(campus: campus, polygons: Self.polygons(of:))
        annotationLayer = PathAnnotationLayer(campus: campus, plane: plane)
        doorAnnotations = Dictionary(uniqueKeysWithValues: campus.doors.map { ($0.id, DoorAnnotation(door: $0)) })
        outlines = campus.buildings.map { building in
            (building.code, building.parts.flatMap { part in ([part.outline] + part.holes).map { $0.map(plane.planar) } })
        }
        super.init(frame: .zero)

        mapView.delegate = self
        mapView.preferredConfiguration = MKStandardMapConfiguration(elevationStyle: .realistic)
        mapView.showsUserLocation = true
        mapView.register(DoorMarkerView.self, forAnnotationViewWithReuseIdentifier: DoorMarkerView.reuseIdentifier)
        mapView.register(MKMarkerAnnotationView.self, forAnnotationViewWithReuseIdentifier: Self.pinReuseIdentifier)
        mapView.camera = MKMapCamera(lookingAtCenter: Self.campusCenter(campus).clCoordinate, fromDistance: 2_400, pitch: 0, heading: 0)
        addSubview(mapView)

        annotationLayer.alpha = 0
        annotationLayer.isHidden = true
        addSubview(annotationLayer)

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
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        for view in [mapView, annotationLayer] as [UIView] { view.frame = bounds }
        reportAnchor()
        syncPathMap()
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
    }

    // MARK: Applying app state

    func apply(mode newMode: AppModel.MapMode, animated: Bool) {
        guard newMode != mode else { return }
        mode = newMode
        mapView.isScrollEnabled = mode == .street
        pathPan.isEnabled = mode == .path
        crossFade(animated: animated) {
            if mode == .path {
                pathOverlays.show(on: mapView)
            } else {
                pathOverlays.hide()
            }
        }
        if mode == .path {
            annotationLayer.isHidden = false
            syncPathMap()
        }
        UIView.animate(withDuration: animated ? Self.fadeSeconds : 0, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.annotationLayer.alpha = newMode == .path ? 1 : 0
        } completion: { _ in
            if self.mode == .street { self.annotationLayer.isHidden = true }
        }
        updateDoorVisibility()
        if mode == .path {
            mapView.removeAnnotations(Array(doorAnnotations.values))
        } else {
            showSelectedDoor()
        }
        if isPicking { snapPickerIntoPathIfNeeded() }
    }

    /// Makes `change` to the map under a snapshot of how it looks now, then fades the
    /// snapshot away, since MapKit can't animate adding and removing overlays.
    private func crossFade(animated: Bool, change: () -> Void) {
        guard animated, let snapshot = mapView.snapshotView(afterScreenUpdates: false) else { return change() }
        snapshot.isUserInteractionEnabled = false
        insertSubview(snapshot, aboveSubview: mapView)
        change()
        UIView.animate(withDuration: Self.fadeSeconds, delay: 0, options: [.allowUserInteraction]) {
            snapshot.alpha = 0
        } completion: { _ in
            snapshot.removeFromSuperview()
        }
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
        var highlightedBuilding: String?

        switch selection {
        case .campus(.building(let code)):
            guard let building = campus.building(code: code) else { break }
            let overlay = Self.polygons(of: building)
            mapView.addOverlay(overlay, level: .aboveRoads)
            highlight = overlay
            highlightedBuilding = code
        case .campus(.door):
            showSelectedDoor()
        case .mapItem(let item):
            dropPin(at: item.coordinate, title: item.name)
        case .droppedPin(let coordinate):
            dropPin(at: coordinate, title: "Dropped Pin")
        case nil:
            break
        }
        pathOverlays.select(highlightedBuilding.flatMap(campus.building(code:)))
    }

    private func clearHighlight() {
        if let highlight { mapView.removeOverlay(highlight) }
        highlight = nil
        pathOverlays.select(nil)
    }

    func apply(cameraRequest: AppModel.CameraRequest?) {
        guard let cameraRequest, cameraRequest.id != appliedCameraRequest else { return }
        appliedCameraRequest = cameraRequest.id
        guard let summary = cameraRequest.place.summary(in: campus) else { return }
        let distance = switch cameraRequest.place {
        case .campus(.building(let code)): campus.building(code: code).map(framingDistance) ?? 400
        case .campus(.door): 280.0
        case .mapItem, .droppedPin: 700.0
        }
        mapView.setCamera(camera(showing: summary.coordinate, distance: distance), animated: true)
    }

    // MARK: Path Map

    @objc private func displayFrame() {
        syncPathMap()
    }

    /// Re-places the lines and labels from MapKit's current camera.
    private func syncPathMap() {
        guard !annotationLayer.isHidden, bounds.height > 0 else { return }
        let state = MapCameraState(mapView.camera)
        annotationLayer.update(projector: projector(for: state), distance: state.distance, selection: appliedSelection)
    }

    private func projector(for state: MapCameraState) -> PinholeProjector {
        PinholeProjector(state: state, plane: plane, model: .measured, viewportSize: viewportSize, anchor: cameraAnchor)
    }

    /// "Choose location inside the path": if the pin is out in the black, slide the
    /// map so the pin lands just inside the nearest building.
    private func snapPickerIntoPathIfNeeded() {
        guard isPicking, mode == .path else { return }
        let center = plane.planar(GeoCoordinate(mapView.centerCoordinate))
        guard !outlines.contains(where: { PolygonGeometry.contains($0.rings, center) }) else { return }
        let candidates = outlines.map { PolygonGeometry.nearestPointInside($0.rings, center, inset: Self.snapInset) }
        guard let target = candidates.min(by: { length($0 - center) < length($1 - center) }) else { return }
        guard let camera = mapView.camera.copy() as? MKMapCamera else { return }
        camera.centerCoordinate = plane.coordinate(fromPlanar: target).clCoordinate
        mapView.setCamera(camera, animated: true)
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
    private func camera(showing coordinate: GeoCoordinate, distance: Double) -> MKMapCamera {
        let pitch = mapView.camera.pitch, heading = mapView.camera.heading
        let projector = PinholeProjector(
            state: MapCameraState(center: coordinate, distance: distance, heading: heading, pitch: Double(pitch)),
            plane: plane,
            model: .measured,
            viewportSize: viewportSize,
            anchor: cameraAnchor
        )
        var center = coordinate
        let band = visibleBand
        if let ground = projector.unproject(SIMD2(Double(band.midX), Double(band.midY))) {
            let target = plane.planar(coordinate)
            center = plane.coordinate(fromPlanar: target + (target - SIMD2(ground.x, ground.y)))
        }
        return MKMapCamera(lookingAtCenter: center.clCoordinate, fromDistance: distance, pitch: pitch, heading: heading)
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
        syncPathMap()  // as soon as MapKit moves, for the least lag behind the finger
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
        default:
            nil  // the user location dot, drawn by MapKit
        }
    }

    func mapView(_ mapView: MKMapView, didSelect annotation: any MKAnnotation) {
        guard !isApplyingSelection, let door = annotation as? DoorAnnotation else { return }
        clearHighlight()
        appliedSelection = .campus(.door(id: door.door.id))
        onSelect?(appliedSelection)
        keepVisible(door.door.coordinate)
    }

    func mapView(_ mapView: MKMapView, rendererFor overlay: any MKOverlay) -> MKOverlayRenderer {
        if let renderer = pathOverlays.renderer(for: overlay) { return renderer }
        guard let overlay = overlay as? MKMultiPolygon else { return MKOverlayRenderer(overlay: overlay) }
        let renderer = MKMultiPolygonRenderer(multiPolygon: overlay)
        renderer.fillColor = .tintColor.withAlphaComponent(0.18)
        renderer.strokeColor = .tintColor
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
        guard !isPicking else { return }
        // Path Map doors never take touches (so drags that start on one still move
        // the map): hit-test them here.
        if mode == .path, let id = annotationLayer.door(at: recognizer.location(in: annotationLayer)), let door = campus.door(id: id) {
            onSelect?(.campus(.door(id: id)))
            keepVisible(door.coordinate)
            return
        }
        let point = recognizer.location(in: mapView)
        // Taps on markers (and the location dot) belong to MapKit's own selection.
        var hit = mapView.hitTest(point, with: nil)
        while let view = hit {
            if view is MKAnnotationView { return }
            hit = view.superview
        }
        let tapped = plane.planar(GeoCoordinate(mapView.convert(point, toCoordinateFrom: mapView)))
        let code = outlines.first { PolygonGeometry.contains($0.rings, tapped) }?.code
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
    /// they'd clutter the map. The annotation layer draws the Path Map's.
    private func updateDoorVisibility() {
        let shouldShow = mode == .street && mapView.camera.centerCoordinateDistance < Self.doorsVisibleBelowDistance
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
