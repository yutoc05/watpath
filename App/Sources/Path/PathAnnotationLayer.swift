import CampusGeo
import CampusModel
import CoreLocation
import UIKit

/// Everything drawn on top of the Path Map in 2D: bridge and tunnel lines, building
/// labels, door markers, the floor numbers at each end of a bridge or tunnel, the
/// user's location and the selected place's pin. Positions come from projecting with
/// the same camera model the 3D view uses, every frame.
///
/// It never takes touches, so every gesture reaches the map, even one that starts
/// on a door marker; the map controller asks `door(at:)` when it sees a tap.
final class PathAnnotationLayer: UIView {
    /// Doors appear below this camera distance, as in Street Map.
    static let doorsVisibleBelowDistance = 1_400.0
    /// Building names join the codes below this camera distance.
    private static let namesVisibleBelowDistance = 450.0
    /// Floor numbers at bridge and tunnel ends appear below this camera distance.
    private static let floorBadgesVisibleBelowDistance = 900.0
    /// Labels float this far above the floor they name, clear of its walls.
    private static let labelLift = 1.5
    /// Gap between a floor badge and the walkway's center line, in points.
    private static let walkwayClearance = 8.0
    private static let doorMarkerRadius = 13.0
    /// Taps this close to a door marker's center (in points) select the door.
    private static let doorTapRadius = 22.0

    private struct BuildingLabel {
        let code: String
        let priority: Int
        let floors: [Floor]
        /// Where the label sits when no Path Map floor is shown: the footprint.
        let footprintHeight: Double
        let anchor: SIMD2<Double>
        let view: UILabel
        let shortText: Text
        /// Code, name and floor, per Path Map floor (by index into `floors`).
        let longTexts: [Int: Text]
        /// Code and name, for a building drawn as a footprint.
        let footprintText: Text
    }

    private struct Text {
        let string: NSAttributedString
        let size: CGSize

        init(_ string: NSAttributedString) {
            self.string = string
            let bounds = string.boundingRect(with: CGSize(width: 170, height: 100), options: [.usesLineFragmentOrigin], context: nil)
            size = CGSize(width: ceil(bounds.width) + 4, height: ceil(bounds.height) + 2)
        }
    }

    /// The floor(s) a bridge or tunnel meets one building at, like "2,3".
    private struct FloorBadge {
        let point: SIMD3<Double>
        /// A point a little way along the walkway, which says which way it runs on screen.
        let inward: SIMD3<Double>
        let view: UILabel
    }

    /// Bridges (blue) and tunnels (red) as lines over everything:
    /// a 3 m walkway is a hairline from across campus, and a tunnel below the floor
    /// shown would otherwise be hidden under it.
    private let walkwayLines: [(kind: Connection.Kind, layer: CAShapeLayer, polylines: [[SIMD3<Double>]])]
    private var labels: [BuildingLabel] = []
    /// The text each label shows now, so it's only reset when it changes.
    private var shownLabelTexts: [String: NSAttributedString] = [:]
    private var badges: [FloorBadge] = []
    private var doorMarkers: [(door: Door, point: SIMD3<Double>, view: DoorMarkerDot)] = []
    private let userDot = UserLocationDot()
    private let pin = UIImageView(image: UIImage(systemName: "mappin", withConfiguration: UIImage.SymbolConfiguration(pointSize: 34, weight: .semibold)))

    init(campus: CampusBundle, plane: MapPlane) {
        walkwayLines = [Connection.Kind.tunnel, .bridge].map { kind in
            let layer = CAShapeLayer()
            layer.strokeColor = kind.color.cgColor
            layer.fillColor = nil
            layer.lineWidth = 4
            layer.lineCap = .round
            layer.lineJoin = .round
            layer.shadowColor = UIColor.black.cgColor
            layer.shadowOpacity = 0.6
            layer.shadowRadius = 1.5
            layer.shadowOffset = .zero
            let polylines = campus.connections.filter { $0.kind == kind }.flatMap { Self.polylines(of: $0, campus: campus, plane: plane) }
            return (kind, layer, polylines)
        }
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        for line in walkwayLines { layer.addSublayer(line.layer) }
        for connection in campus.connections {
            addBadges(for: connection, campus: campus, plane: plane)
        }
        for building in campus.buildings {
            addLabel(for: building, plane: plane)
        }
        for door in campus.doors {
            let marker = DoorMarkerDot(door: door)
            marker.isHidden = true
            addSubview(marker)
            let building = campus.building(code: door.building)
            let floor = door.level.flatMap { building?.floor(named: $0) } ?? building?.groundFloor
            let ground = plane.point(door.coordinate)
            doorMarkers.append((door, SIMD3(ground.x, ground.y, floor?.elevation ?? 0), marker))
        }
        pin.tintColor = .systemRed
        pin.isHidden = true
        addSubview(userDot)
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

    /// Repositions everything for the current camera. `displayedFloors` matches the
    /// 3D view (building code → index into its floors), so labels sit on the floor shown.
    func update(
        projector: PinholeProjector,
        plane: MapPlane,
        distance: Double,
        displayedFloors: [String: Int],
        selection: Place?,
        userLocation: CLLocation?
    ) {
        let selectedBuilding: String? = if case .campus(.building(let code)) = selection { code } else { nil }
        let selectedDoor: String? = if case .campus(.door(let id)) = selection { id } else { nil }

        CATransaction.begin()
        CATransaction.setDisableActions(true)  // follow the camera exactly, no implicit animation
        for line in walkwayLines {
            let path = UIBezierPath()
            for polyline in line.polylines {
                var drawing = false
                for point in polyline {
                    guard let screen = projector.project(point) else {
                        drawing = false
                        continue
                    }
                    let cgPoint = CGPoint(x: screen.x, y: screen.y)
                    if drawing { path.addLine(to: cgPoint) } else { path.move(to: cgPoint) }
                    drawing = true
                }
            }
            line.layer.path = path.cgPath
        }
        CATransaction.commit()

        // Labels: selected building first, then by importance; drop any that would overlap.
        let showNames = distance < Self.namesVisibleBelowDistance
        var placed: [CGRect] = []
        let ordered = labels.sorted { a, b in
            if (a.code == selectedBuilding) != (b.code == selectedBuilding) { return a.code == selectedBuilding }
            return a.priority < b.priority
        }
        for label in ordered {
            let floorIndex = displayedFloors[label.code]
            let height = (floorIndex.map { label.floors[$0].elevation } ?? label.footprintHeight) + Self.labelLift
            guard let screen = projector.project(SIMD3(label.anchor.x, label.anchor.y, height)) else {
                label.view.isHidden = true
                continue
            }
            let text = showNames ? (floorIndex.flatMap { label.longTexts[$0] } ?? label.footprintText) : label.shortText
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
            let screen = projector.project(selected.point)
            selected.view.isHidden = screen == nil
            selected.view.isSelectedMarker = true
            if let screen {
                selected.view.center = CGPoint(x: screen.x, y: screen.y)
                placed.append(selected.view.frame)
            }
        }

        // Floor badges beside each walkway end,
        // kept clear of labels and each other.
        let showBadges = distance < Self.floorBadgesVisibleBelowDistance
        for badge in badges {
            guard showBadges, let end = projector.project(badge.point), let inward = projector.project(badge.inward) else {
                badge.view.isHidden = true
                continue
            }
            var along = inward - end
            let length = (along * along).sum().squareRoot()
            along = length > 0.01 ? along / length : SIMD2(1, 0)
            // Beside the walkway, on its upper side (its right side if it runs straight up and down).
            var beside = SIMD2(along.y, -along.x)
            if beside.y > 0.05 || (abs(beside.y) <= 0.05 && beside.x < 0) { beside = -beside }
            let size = badge.view.bounds.size
            let center = end + along * Double(size.width / 2) + beside * Double(size.height / 2 + Self.walkwayClearance)
            let frame = CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
            let fits = bounds.intersects(frame) && !placed.contains { $0.intersects(frame) }
            badge.view.isHidden = !fits
            guard fits else { continue }
            placed.append(frame)
            badge.view.center = CGPoint(x: center.x, y: center.y)
        }

        // Doors last: like Apple Maps' markers, they give way to labels and to each other.
        let showDoors = distance < Self.doorsVisibleBelowDistance
        for (door, point, marker) in doorMarkers where door.id != selectedDoor {
            marker.isSelectedMarker = false
            guard showDoors, let screen = projector.project(point) else {
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
        case .droppedPin(let coordinate):
            placePin(at: coordinate, projector: projector, plane: plane)
        default:
            pin.isHidden = true
        }
    }

    // MARK: Building

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
        view.layer.shadowColor = UIColor.black.cgColor
        view.layer.shadowOpacity = 0.9
        view.layer.shadowRadius = 3
        view.layer.shadowOffset = .zero
        view.isHidden = true
        view.accessibilityIdentifier = "pathLabel-\(building.code)"
        addSubview(view)
        labels.append(BuildingLabel(
            code: building.code,
            priority: building.priority,
            floors: building.floors,
            footprintHeight: building.groundFloor?.elevation ?? 0,
            anchor: anchor,
            view: view,
            shortText: Text(Self.labelText(code: building.code, details: nil)),
            longTexts: Dictionary(uniqueKeysWithValues: building.mappedFloorIndices.map { index in
                (index, Text(Self.labelText(code: building.code, details: "\(building.name)\n\(building.floors[index].title)")))
            }),
            footprintText: Text(Self.labelText(code: building.code, details: building.name))
        ))
    }

    private static func labelText(code: String, details: String?) -> NSAttributedString {
        let text = NSMutableAttributedString(string: code, attributes: [
            .font: UIFont.systemFont(ofSize: 15, weight: .heavy),
            .foregroundColor: UIColor.white,
        ])
        if let details {
            text.append(NSAttributedString(string: "\n\(details)", attributes: [
                .font: UIFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: UIColor(white: 0.85, alpha: 1),
            ]))
        }
        return text
    }

    // MARK: Connections

    private func addBadges(for connection: Connection, campus: CampusBundle, plane: MapPlane) {
        for (index, end) in connection.ends.enumerated() where !end.floors.isEmpty {
            // Where a path leaves this end, and which way it heads.
            guard let path = connection.paths.first(where: { $0.from == index || $0.to == index }), path.points.count >= 2 else { continue }
            let points = (path.from == index ? path.points : path.points.reversed()).map(plane.planar)
            let height = campus.elevation(of: connection, end: index, deck: 0)
            let step = points[1] - points[0]
            let stepLength = (step * step).sum().squareRoot()
            let inward = stepLength > 0.01 ? points[0] + step / stepLength : points[1]
            let view = UILabel()
            view.text = end.floors.joined(separator: ",")
            view.font = .systemFont(ofSize: 11, weight: .bold)
            view.textColor = .white
            view.textAlignment = .center
            view.backgroundColor = connection.kind.color
            view.layer.cornerRadius = 8
            view.layer.borderColor = UIColor.white.withAlphaComponent(0.85).cgColor
            view.layer.borderWidth = 1
            view.clipsToBounds = true
            view.sizeToFit()
            view.bounds.size = CGSize(width: max(16, view.bounds.width + 8), height: 16)
            view.isHidden = true
            view.accessibilityLabel = "\(end.building) floor \(view.text ?? "")"
            addSubview(view)
            badges.append(FloorBadge(point: SIMD3(points[0].x, points[0].y, height), inward: SIMD3(inward.x, inward.y, height), view: view))
        }
    }

    /// The walkway's center lines in 3D, one per storey, rising or falling between
    /// the floors its ends meet (as the 3D view draws them).
    private static func polylines(of connection: Connection, campus: CampusBundle, plane: MapPlane) -> [[SIMD3<Double>]] {
        (0..<connection.deckCount).flatMap { deck in
            connection.paths.map { path in
                let from = campus.elevation(of: connection, end: path.from, deck: deck)
                let to = campus.elevation(of: connection, end: path.to, deck: deck)
                let points = path.points.map(plane.planar)
                let lengths = zip(points, points.dropFirst()).map { a, b in ((b - a) * (b - a)).sum().squareRoot() }
                let total = max(lengths.reduce(0, +), 1e-6)
                var walked = 0.0
                return points.enumerated().map { index, point in
                    if index > 0 { walked += lengths[index - 1] }
                    return SIMD3(point.x, point.y, from + (to - from) * walked / total)
                }
            }
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
