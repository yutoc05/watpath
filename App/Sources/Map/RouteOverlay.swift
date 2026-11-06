import MapKit
import Routing

/// A route on the Street Map.
nonisolated final class RouteOverlay: MKPolyline {
    private(set) var isSelected = false

    convenience init(route: Route, isSelected: Bool) {
        let coordinates = route.points.map(\.clCoordinate)
        self.init(coordinates: coordinates, count: coordinates.count)
        self.isSelected = isSelected
    }
}

/// The dot where a route starts, the same on both maps.
final class RouteStartMarkerView: MKAnnotationView {
    static let reuseIdentifier = "routeStart"

    static let image = UIGraphicsImageRenderer(size: CGSize(width: 18, height: 18)).image { context in
        let box = CGRect(x: 1.5, y: 1.5, width: 15, height: 15)
        UIColor.white.setFill()
        context.cgContext.fillEllipse(in: box)
        PathMapView.routeColor.setStroke()
        context.cgContext.setLineWidth(3)
        context.cgContext.strokeEllipse(in: box)
    }

    override init(annotation: (any MKAnnotation)?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        image = Self.image
        isEnabled = false
        displayPriority = .required
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}
