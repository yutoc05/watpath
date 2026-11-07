import CampusGeo
import CampusModel
import CoreLocation
import Routing
import UIKit

/// The Path Map: an opaque view over the street map, with everything in it placed from
/// MapKit's camera every frame. Buildings are flat footprints on black, with thin lines
/// for corridors, bridges and tunnels, and on top of those labels, the floor numbers at
/// each end of a bridge or tunnel, door markers, the pin and the user's location.
/// Everything lies on one level, and moves together in one Core Animation transaction.
///
/// It never takes touches, so every gesture reaches the map underneath, even one that
/// starts on a door marker; the map controller asks `door(at:)` when it sees a tap.
final class PathMapView: UIView {
    /// Doors appear below this camera distance, as in Street Map.
    static let doorsVisibleBelowDistance = 1_400.0
    static let routeColor = UIColor.systemBlue
    static let alternativeRouteColor = UIColor(red: 0.55, green: 0.65, blue: 0.8, alpha: 1)
    /// Routes are the widest thing on either map, in points.
    static let routeWidth = 5.0
    /// The white edge around the picked route, which sets it apart from a blue bridge.
    private static let routeEdgeWidth = 7.5
    /// The width of every line, in points, at any zoom or tilt.
    private static let lineWidth = 1.5
    private static let dividerWidth = 0.5
    private static let buildingColor = UIColor(white: 0.25, alpha: 1)
    private static let selectedColor = UIColor(red: 1, green: 0.62, blue: 0.2, alpha: 1)
    /// Building names join the codes below this camera distance.
    private static let namesVisibleBelowDistance = 450.0
    /// Floor numbers at bridge and tunnel ends appear below this camera distance.
    private static let floorBadgesVisibleBelowDistance = 900.0
    /// Gap between a floor badge and its line, in points.
    private static let lineClearance = 5.0
    private static let doorMarkerRadius = 13.0
    /// Taps this close to a door marker's center (in points) select the door.
    private static let doorTapRadius = 22.0

    private struct BuildingLabel {
        let code: String
        let priority: Int
        let anchor: SIMD2<Double>
        let view: UILabel
        let shortText: Text
        /// Code and name.
        let longText: Text
    }

    private struct Text {
        let string: NSAttributedString
        let size: CGSize

        init(_ string: NSAttributedString) {
            self.string = string
            let bounds = string.boundingRect(with: CGSize(width: 170, height: 100), options: [.usesLineFragmentOrigin], context: nil)
            // Room around the text for its shadow.
            size = CGSize(width: ceil(bounds.width) + 8, height: ceil(bounds.height) + 6)
        }
    }

    /// The floor(s) a bridge or tunnel meets one building at, like "2,3".
    private struct FloorBadge {
        let point: SIMD2<Double>
        /// A point a little way along the line, which says which way it runs on screen.
        let inward: SIMD2<Double>
        let view: UILabel
    }

    /// Lines of one color on the ground.
    private struct LineSet {
        let shape: CAShapeLayer
        let lines: [[SIMD2<Double>]]
    }

    private let footprints = CAShapeLayer()
    private let selectedFootprint = CAShapeLayer()
    /// Every building's rings, wound for a non-zero fill, so outlines that overlap
    /// (EV3 over EV2) fill as one shape.
    private var rings: [String: [[SIMD2<Double>]]] = [:]
    private var allRings: [[SIMD2<Double>]] = []
    private var lineSets: [LineSet] = []
    private var labels: [BuildingLabel] = []
    /// The text each label shows now, so it's only reset when it changes.
    private var shownLabelTexts: [String: NSAttributedString] = [:]
    private var badges: [FloorBadge] = []
    private var doorMarkers: [(door: Door, point: SIMD2<Double>, view: DoorMarkerDot)] = []
    private let alternativeRoutes = CAShapeLayer()
    private let selectedRouteEdge = CAShapeLayer()
    private let selectedRoute = CAShapeLayer()
    private var alternativeLines: [[SIMD2<Double>]] = []
    private var selectedLine: [SIMD2<Double>] = []
    private let routeStartDot = UIImageView(image: RouteStartMarkerView.image)
    private let userDot = UserLocationDot()
    private let pin = UIImageView(image: UIImage(systemName: "mappin", withConfiguration: UIImage.SymbolConfiguration(pointSize: 34, weight: .semibold)))

    init(campus: CampusBundle, plane: MapPlane) {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        backgroundColor = .black
        for building in campus.buildings {
            rings[building.code] = building.parts.flatMap { part in
                PolygonGeometry.wound(outline: part.outline.map(plane.planar), holes: part.holes.map { $0.map(plane.planar) })
            }
        }
        allRings = rings.values.flatMap { $0 }
        footprints.fillColor = Self.buildingColor.cgColor
        selectedFootprint.fillColor = Self.selectedColor.cgColor
        layer.addSublayer(footprints)
        layer.addSublayer(selectedFootprint)
        addLines(campus.dividers, color: .black, width: Self.dividerWidth, plane: plane)
        // Tunnels and bridges over the corridors they join.
        addLines(campus.corridors, color: .white, width: Self.lineWidth, plane: plane)
        for kind in [Connection.Kind.tunnel, .bridge] {
            addLines(campus.connections.filter { $0.kind == kind }.flatMap { $0.paths.map(\.points) }, color: kind.color, width: Self.lineWidth, plane: plane)
        }
        for (route, color, width) in [
            (alternativeRoutes, Self.alternativeRouteColor, Self.routeWidth),
            (selectedRouteEdge, UIColor.white, Self.routeEdgeWidth),
            (selectedRoute, Self.routeColor, Self.routeWidth),
        ] {
            style(route, color: color, width: width)
            layer.addSublayer(route)
        }
        for connection in campus.connections {
            addBadges(for: connection, plane: plane)
        }
        for building in campus.buildings {
            addLabel(for: building, plane: plane)
        }
        for door in campus.doors {
            let marker = DoorMarkerDot(door: door)
            marker.isHidden = true
            addSubview(marker)
            doorMarkers.append((door, plane.planar(door.coordinate), marker))
        }
        pin.tintColor = .systemRed
        pin.isHidden = true
        routeStartDot.isHidden = true
        addSubview(userDot)
        addSubview(routeStartDot)
        addSubview(pin)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The door whose marker is under `point` (in this view), if any.
    func door(at point: CGPoint) -> String? {
        doorMarkers
            .filter { !$0.view.isHidden }
            .map { ($0.door.id, hypot($0.view.center.x - point.x, $0.view.center.y - point.y)) }
            .filter { $0.1 <= Self.doorTapRadius }
            .min { $0.1 < $1.1 }?.0
    }

    /// Door markers step aside while navigating, as they do for a route preview.
    var hidesDoors = false

    /// The routes to draw: the picked one over the others.
    func show(route: Route?, alternatives: [Route], plane: MapPlane) {
        selectedLine = route?.points.map(plane.planar) ?? []
        alternativeLines = alternatives.map { $0.points.map(plane.planar) }
        routeStartDot.isHidden = selectedLine.isEmpty
        if selectedLine.isEmpty {
            for shape in [alternativeRoutes, selectedRouteEdge, selectedRoute] { shape.path = nil }
        }
    }

    /// Repositions everything for the current camera.
    func update(projector: PinholeProjector, plane: MapPlane, distance: Double, selection: Place?, userLocation: CLLocation?) {
        let selectedBuilding: String? = if case .campus(.building(let code)) = selection { code } else { nil }
        let selectedDoor: String? = if case .campus(.door(let id)) = selection { id } else { nil }

        CATransaction.begin()
        CATransaction.setDisableActions(true)  // a shape layer would animate between paths
        defer { CATransaction.commit() }
        let ground = GroundProjection(projector)
        footprints.path = Self.filledPath(of: allRings, ground: ground)
        selectedFootprint.path = selectedBuilding.flatMap { rings[$0] }.map { Self.filledPath(of: $0, ground: ground) }
        for set in lineSets {
            set.shape.path = Self.strokedPath(of: set.lines, ground: ground)
        }

        if let start = selectedLine.first {
            let path = Self.strokedPath(of: [selectedLine], ground: ground)
            selectedRoute.path = path
            selectedRouteEdge.path = path
            alternativeRoutes.path = Self.strokedPath(of: alternativeLines, ground: ground)
            if let screen = projector.project(SIMD3(start.x, start.y, 0)) {
                routeStartDot.isHidden = false
                routeStartDot.center = CGPoint(x: screen.x, y: screen.y)
            } else {
                routeStartDot.isHidden = true
            }
        }

        // Labels: selected building first, then by importance; drop any that would overlap.
        let showNames = distance < Self.namesVisibleBelowDistance
        var placed: [CGRect] = []
        let ordered = labels.sorted { a, b in
            if (a.code == selectedBuilding) != (b.code == selectedBuilding) { return a.code == selectedBuilding }
            return a.priority < b.priority
        }
        for label in ordered {
            guard let screen = projector.project(SIMD3(label.anchor.x, label.anchor.y, 0)) else {
                label.view.isHidden = true
                continue
            }
            let text = showNames ? label.longText : label.shortText
            let frame = CGRect(x: screen.x - text.size.width / 2, y: screen.y - text.size.height / 2, width: text.size.width, height: text.size.height)
            let fits = bounds.intersects(frame) && !placed.contains { $0.insetBy(dx: -4, dy: -2).intersects(frame) }
            label.view.isHidden = !fits
            guard fits else { continue }
            placed.append(frame)
            if shownLabelTexts[label.code] !== text.string {
                label.view.attributedText = text.string
                shownLabelTexts[label.code] = text.string
            }
            label.view.frame = frame
            label.view.alpha = label.code == selectedBuilding || selectedBuilding == nil ? 1 : 0.75
        }

        // The selected door always shows, ahead of everything else.
        if let selected = doorMarkers.first(where: { $0.door.id == selectedDoor }) {
            let screen = projector.project(SIMD3(selected.point.x, selected.point.y, 0))
            selected.view.isHidden = screen == nil
            selected.view.isSelectedMarker = true
            if let screen {
                selected.view.center = CGPoint(x: screen.x, y: screen.y)
                placed.append(selected.view.frame)
            }
        }

        // Floor badges beside each end of a line,
        // kept clear of labels and each other.
        let showBadges = distance < Self.floorBadgesVisibleBelowDistance
        for badge in badges {
            guard showBadges,
                  let end = projector.project(SIMD3(badge.point.x, badge.point.y, 0)),
                  let inward = projector.project(SIMD3(badge.inward.x, badge.inward.y, 0))
            else {
                badge.view.isHidden = true
                continue
            }
            var along = inward - end
            let length = (along * along).sum().squareRoot()
            along = length > 0.01 ? along / length : SIMD2(1, 0)
            // Beside the line, on its upper side (its right side if it runs straight up and down).
            var beside = SIMD2(along.y, -along.x)
            if beside.y > 0.05 || (abs(beside.y) <= 0.05 && beside.x < 0) { beside = -beside }
            let size = badge.view.bounds.size
            let center = end + along * Double(size.width / 2) + beside * Double(size.height / 2 + Self.lineClearance)
            let frame = CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
            let fits = bounds.intersects(frame) && !placed.contains { $0.intersects(frame) }
            badge.view.isHidden = !fits
            guard fits else { continue }
            placed.append(frame)
            badge.view.center = CGPoint(x: center.x, y: center.y)
        }

        // Doors last: like Apple Maps' markers, they give way to labels and to each other.
        let showDoors = distance < Self.doorsVisibleBelowDistance && selectedLine.isEmpty && !hidesDoors
        for (door, point, marker) in doorMarkers where door.id != selectedDoor {
            marker.isSelectedMarker = false
            guard showDoors, let screen = projector.project(SIMD3(point.x, point.y, 0)) else {
                marker.isHidden = true
                continue
            }
            let frame = CGRect(x: screen.x - Self.doorMarkerRadius, y: screen.y - Self.doorMarkerRadius, width: 2 * Self.doorMarkerRadius, height: 2 * Self.doorMarkerRadius)
            let fits = bounds.intersects(frame) && !placed.contains { $0.intersects(frame) }
            marker.isHidden = !fits
            guard fits else { continue }
            placed.append(frame)
            marker.center = CGPoint(x: screen.x, y: screen.y)
        }

        if let userLocation, let screen = projector.project(plane.point(GeoCoordinate(userLocation.coordinate))) {
            // Accuracy halo: project a point `accuracy` meters east to get its radius on screen.
            let east = plane.point(GeoCoordinate(userLocation.coordinate)) + SIMD3(max(userLocation.horizontalAccuracy, 0), 0, 0)
            let edge = projector.project(east) ?? screen
            userDot.isHidden = false
            userDot.update(center: CGPoint(x: screen.x, y: screen.y), haloRadius: hypot(edge.x - screen.x, edge.y - screen.y))
        } else {
            userDot.isHidden = true
        }

        switch selection {
        case .mapItem(let item):
            placePin(at: item.coordinate, projector: projector, plane: plane)
        case .droppedPin(let coordinate), .currentLocation(let coordinate):
            placePin(at: coordinate, projector: projector, plane: plane)
        default:
            pin.isHidden = true
        }
    }

    private func placePin(at coordinate: GeoCoordinate, projector: PinholeProjector, plane: MapPlane) {
        guard let screen = projector.project(plane.point(coordinate)) else {
            pin.isHidden = true
            return
        }
        pin.isHidden = false
        pin.sizeToFit()
        // The symbol's tip, not its middle, marks the spot.
        pin.center = CGPoint(x: screen.x, y: screen.y - pin.bounds.height / 2)
    }

    private static func filledPath(of rings: [[SIMD2<Double>]], ground: GroundProjection) -> CGPath {
        let path = CGMutablePath()
        for ring in rings {
            let points = ground.project(ring: ring)
            guard points.count >= 3 else { continue }
            path.addLines(between: points.map { CGPoint(x: $0.x, y: $0.y) })
            path.closeSubpath()
        }
        return path
    }

    private static func strokedPath(of lines: [[SIMD2<Double>]], ground: GroundProjection) -> CGPath {
        let path = CGMutablePath()
        for line in lines {
            for piece in ground.project(line: line) {
                path.addLines(between: piece.map { CGPoint(x: $0.x, y: $0.y) })
            }
        }
        return path
    }

    // MARK: Building

    private func style(_ shape: CAShapeLayer, color: UIColor, width: CGFloat) {
        shape.strokeColor = color.cgColor
        shape.fillColor = nil
        shape.lineWidth = width
        shape.lineCap = .round
        shape.lineJoin = .round
    }

    private func addLines(_ lines: [[GeoCoordinate]], color: UIColor, width: CGFloat, plane: MapPlane) {
        let shape = CAShapeLayer()
        style(shape, color: color, width: width)
        layer.addSublayer(shape)
        lineSets.append(LineSet(shape: shape, lines: lines.map { $0.map(plane.planar) }))
    }

    private func addLabel(for building: Building, plane: MapPlane) {
        let rings = building.parts.flatMap { part in ([part.outline] + part.holes).map { $0.map(plane.planar) } }
        let largest = building.parts.max { $0.outline.count < $1.outline.count }
        // The widest point inside sits in a thick wing of T- and cross-shaped
        // buildings, so the data can place the label by hand instead.
        let anchor = building.label.map(plane.planar)
            ?? largest.map { part in PolygonGeometry.labelPoint(([part.outline] + part.holes).map { $0.map(plane.planar) }) }
            ?? PolygonGeometry.labelPoint(rings)
        let view = UILabel()
        view.numberOfLines = 0
        view.textAlignment = .center
        view.isHidden = true
        view.accessibilityIdentifier = "pathLabel-\(building.code)"
        addSubview(view)
        labels.append(BuildingLabel(
            code: building.code,
            priority: building.priority,
            anchor: anchor,
            view: view,
            shortText: Text(Self.labelText(code: building.code, details: nil)),
            longText: Text(Self.labelText(code: building.code, details: building.name))
        ))
    }

    private static func labelText(code: String, details: String?) -> NSAttributedString {
        // The shadow is part of the text, not the layer: a layer shadow on every label
        // is an offscreen render pass each, every frame the map moves.
        let shadow = NSShadow()
        shadow.shadowColor = UIColor.black.withAlphaComponent(0.9)
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = .zero
        let text = NSMutableAttributedString(string: code, attributes: [
            .font: UIFont.systemFont(ofSize: 15, weight: .heavy),
            .foregroundColor: UIColor.white,
            .shadow: shadow,
        ])
        if let details {
            text.append(NSAttributedString(string: "\n\(details)", attributes: [
                .font: UIFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: UIColor(white: 0.85, alpha: 1),
                .shadow: shadow,
            ]))
        }
        return text
    }

    // MARK: Connections

    private func addBadges(for connection: Connection, plane: MapPlane) {
        for path in connection.paths {
            let points = path.points.map(plane.planar)
            if let end = path.from { addBadge(for: connection, end: end, at: points[0], toward: points[1]) }
            if let end = path.to { addBadge(for: connection, end: end, at: points[points.count - 1], toward: points[points.count - 2]) }
        }
    }

    private func addBadge(for connection: Connection, end index: Int, at point: SIMD2<Double>, toward next: SIMD2<Double>) {
        let end = connection.ends[index]
        guard !end.floors.isEmpty else { return }
        let step = next - point
        let view = UILabel()
        view.text = end.floors.joined(separator: ",")
        view.font = .systemFont(ofSize: 11, weight: .bold)
        view.textColor = .white
        view.textAlignment = .center
        // On the layer with no clipping, which would be an offscreen render pass per badge.
        view.layer.backgroundColor = connection.kind.color.cgColor
        view.layer.cornerRadius = 8
        view.layer.borderColor = UIColor.white.withAlphaComponent(0.85).cgColor
        view.layer.borderWidth = 1
        view.sizeToFit()
        view.bounds.size = CGSize(width: max(16, view.bounds.width + 8), height: 16)
        view.isHidden = true
        view.accessibilityLabel = "\(end.building) floor \(view.text ?? "")"
        view.accessibilityIdentifier = "floorBadge-\(connection.id)-\(index)"
        addSubview(view)
        badges.append(FloorBadge(point: point, inward: point + step / max((step * step).sum().squareRoot(), 0.01), view: view))
    }
}

/// A round door marker, styled like the Street Map's door pins.
private final class DoorMarkerDot: UIView {
    var isSelectedMarker = false {
        didSet {
            guard isSelectedMarker != oldValue else { return }
            transform = isSelectedMarker ? CGAffineTransform(scaleX: 1.4, y: 1.4) : .identity
            layer.borderWidth = isSelectedMarker ? 2.5 : 1.5
        }
    }

    init(door: Door) {
        super.init(frame: CGRect(x: 0, y: 0, width: 26, height: 26))
        backgroundColor = door.kind == .exit || door.kind == .stairwell ? .systemGray : .systemTeal
        let icon = UIImageView(image: UIImage(systemName: "door.left.hand.open", withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .bold)))
        icon.tintColor = .white
        icon.center = CGPoint(x: 13, y: 13)
        addSubview(icon)
        layer.cornerRadius = 13
        layer.borderColor = UIColor.white.cgColor
        layer.borderWidth = 1.5
        isAccessibilityElement = true
        accessibilityLabel = door.name
        accessibilityIdentifier = "door-\(door.id)"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}

/// Apple Maps' blue dot, with a translucent halo for horizontal accuracy.
private final class UserLocationDot: UIView {
    private let halo = UIView()
    private let dot = UIView(frame: CGRect(x: 0, y: 0, width: 18, height: 18))

    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        isHidden = true
        halo.backgroundColor = UIColor.systemBlue.withAlphaComponent(0.15)
        dot.backgroundColor = .systemBlue
        dot.layer.cornerRadius = 9
        dot.layer.borderColor = UIColor.white.cgColor
        dot.layer.borderWidth = 3
        addSubview(halo)
        addSubview(dot)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func update(center: CGPoint, haloRadius: CGFloat) {
        let radius = max(haloRadius, 12)
        frame = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        halo.frame = bounds
        halo.layer.cornerRadius = radius
        dot.center = CGPoint(x: radius, y: radius)
    }
}

extension Connection.Kind {
    /// Blue bridges, red tunnels.
    fileprivate var color: UIColor {
        switch self {
        case .bridge: UIColor(red: 0.2, green: 0.5, blue: 1, alpha: 1)
        case .tunnel: UIColor(red: 1, green: 0.27, blue: 0.23, alpha: 1)
        case .link: .white
        }
    }
}
