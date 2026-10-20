import CampusGeo
import CampusModel
import MapKit
import UIKit

/// Street Map: Apple's map plus campus doors, tap-to-select buildings, and the
/// selection highlight. It reports user actions through closures and applies
/// state from `AppModel` via `apply(…)`; it never owns app state itself.
final class StreetMapController: UIView, MKMapViewDelegate, UIGestureRecognizerDelegate {
    /// Doors appear once the camera is closer than this; above it they'd clutter the map.
    static let doorsVisibleBelowDistance = 1_400.0
    /// Search field plus padding at the top of the map.
    private static let searchFieldClearance = 66.0

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
            let center = GeoCoordinate(mapView.centerCoordinate)
            Task { @MainActor [weak self] in self?.onPickerCoordinateChange?(center) }
        }
    }

    private let campus: CampusBundle
    private let plane: MapPlane
    private lazy var controls = MapControlsView(mapView: mapView)
    private let doorAnnotations: [String: DoorAnnotation]
    /// Building outlines on the map plane, for hit-testing taps.
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
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        mapView.frame = bounds
        reportAnchor()
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        reportAnchor()
    }

    // MARK: Applying app state

    func apply(selection: Place?) {
        guard selection != appliedSelection else { return }
        appliedSelection = selection
        isApplyingSelection = true
        defer { isApplyingSelection = false }

        if let highlight { mapView.removeOverlay(highlight) }
        if let pin { mapView.removeAnnotation(pin) }
        highlight = nil
        pin = nil
        for annotation in mapView.selectedAnnotations {
            mapView.deselectAnnotation(annotation, animated: true)
        }

        switch selection {
        case .campus(.building(let code)):
            guard let building = campus.building(code: code) else { return }
            let overlay = MKMultiPolygon(building.parts.map(Self.polygon))
            mapView.addOverlay(overlay, level: .aboveRoads)
            highlight = overlay
        case .campus(.door(let id)):
            guard let annotation = doorAnnotations[id] else { return }
            if !doorsShown { mapView.addAnnotation(annotation) }
            mapView.selectAnnotation(annotation, animated: true)
        case .mapItem(let item):
            dropPin(at: item.coordinate, title: item.name)
        case .droppedPin(let coordinate):
            dropPin(at: coordinate, title: "Dropped Pin")
        case nil:
            break
        }
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
            viewportSize: SIMD2(Double(bounds.width), Double(bounds.height)),
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

    /// Where MapKit keeps its center: the middle of the safe area, as an offset from
    /// the view's middle (ADR-001).
    private var cameraAnchor: SIMD2<Double> {
        let insets = mapView.safeAreaInsets
        return SIMD2(Double(insets.left - insets.right) / 2, Double(insets.top - insets.bottom) / 2)
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

    // MARK: MKMapViewDelegate

    func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) {
        controls.updatePitchButton()
        updateDoorVisibility()
        if isPicking {
            onPickerCoordinateChange?(GeoCoordinate(mapView.centerCoordinate))
        }
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
        appliedSelection = .campus(.door(id: door.door.id))
        onSelect?(appliedSelection)
        keepVisible(door.door.coordinate)
    }

    func mapView(_ mapView: MKMapView, rendererFor overlay: any MKOverlay) -> MKOverlayRenderer {
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

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        guard !isPicking else { return }
        let point = recognizer.location(in: mapView)
        // Taps on markers (and the location dot) belong to MapKit's own selection.
        var hit = mapView.hitTest(point, with: nil)
        while let view = hit {
            if view is MKAnnotationView { return }
            hit = view.superview
        }
        let tapped = plane.planar(GeoCoordinate(mapView.convert(point, toCoordinateFrom: mapView)))
        let code = outlines.first { Self.contains($0.rings, tapped) }?.code
        let selection = code.map { Place.campus(.building(code: $0)) }
        guard selection != appliedSelection else { return }
        onSelect?(selection)
        if let code, let building = campus.building(code: code) {
            keepVisible(building.center)
        }
    }

    // MARK: Helpers

    private static let pinReuseIdentifier = "pin"

    private func updateDoorVisibility() {
        let shouldShow = mapView.camera.centerCoordinateDistance < Self.doorsVisibleBelowDistance
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

    private static func polygon(_ part: BuildingPart) -> MKPolygon {
        let holes = part.holes.map { ring in
            let coordinates = ring.map(\.clCoordinate)
            return MKPolygon(coordinates: coordinates, count: coordinates.count)
        }
        let outline = part.outline.map(\.clCoordinate)
        return MKPolygon(coordinates: outline, count: outline.count, interiorPolygons: holes)
    }

    /// Even-odd point-in-polygon over outline and holes together.
    private static func contains(_ rings: [[SIMD2<Double>]], _ point: SIMD2<Double>) -> Bool {
        var inside = false
        for ring in rings {
            var j = ring.count - 1
            for i in ring.indices {
                let a = ring[i], b = ring[j]
                if (a.y > point.y) != (b.y > point.y), point.x < a.x + (point.y - a.y) * (b.x - a.x) / (b.y - a.y) {
                    inside.toggle()
                }
                j = i
            }
        }
        return inside
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
