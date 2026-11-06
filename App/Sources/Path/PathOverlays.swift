import CampusModel
import MapKit
import UIKit

/// The ground of the Path Map: black over the street map, with flat building
/// footprints. MapKit draws these on the map itself, so they can't drift from the
/// camera. Nothing has a height or a floor: the whole campus lies on one level.
/// The lines are in `PathAnnotationLayer` (ADR-002 says why).
final class PathOverlays {
    private static let buildingColor = UIColor(white: 0.25, alpha: 1)
    private static let selectedColor = UIColor(red: 1, green: 0.62, blue: 0.2, alpha: 1)

    private let backdrop: MKPolygon
    private let buildings: MKMultiPolygon
    private var selection: (building: String, overlay: MKMultiPolygon)?
    private let polygons: (Building) -> MKMultiPolygon
    private weak var mapView: MKMapView?

    init(campus: CampusBundle, polygons: @escaping (Building) -> MKMultiPolygon) {
        self.polygons = polygons
        let world = MKMapRect.world
        let corners = [
            MKMapPoint(x: world.minX, y: world.minY), MKMapPoint(x: world.maxX, y: world.minY),
            MKMapPoint(x: world.maxX, y: world.maxY), MKMapPoint(x: world.minX, y: world.maxY),
        ]
        backdrop = MKPolygon(points: corners, count: corners.count)
        buildings = MKMultiPolygon(campus.buildings.flatMap { polygons($0).polygons })
    }

    func show(on mapView: MKMapView) {
        self.mapView = mapView
        // In this order, bottom to top.
        var overlays: [any MKOverlay] = [backdrop, buildings]
        if let selection { overlays.append(selection.overlay) }
        for overlay in overlays { mapView.addOverlay(overlay, level: .aboveLabels) }
    }

    func hide() {
        guard let mapView else { return }
        mapView.removeOverlays([backdrop, buildings] + (selection.map { [$0.overlay] } ?? []))
        self.mapView = nil
    }

    /// Turns `building` orange, solidly, even where its outline overlaps another's.
    func select(_ building: Building?) {
        guard building?.code != selection?.building else { return }
        if let selection { mapView?.removeOverlay(selection.overlay) }
        selection = building.map { ($0.code, polygons($0)) }
        if let selection, let mapView {
            mapView.insertOverlay(selection.overlay, above: buildings)
        }
    }

    /// The renderer for one of these overlays, or nil if it's someone else's.
    func renderer(for overlay: any MKOverlay) -> MKOverlayRenderer? {
        switch overlay {
        case let polygon as MKPolygon where polygon === backdrop:
            let renderer = MKPolygonRenderer(polygon: polygon)
            renderer.fillColor = .black
            return renderer
        case let polygons as MKMultiPolygon where polygons === buildings:
            return Self.footprints(polygons, color: Self.buildingColor)
        case let polygons as MKMultiPolygon where polygons === selection?.overlay:
            return Self.footprints(polygons, color: Self.selectedColor)
        default:
            return nil
        }
    }

    private static func footprints(_ polygons: MKMultiPolygon, color: UIColor) -> MKOverlayRenderer {
        let renderer = MKMultiPolygonRenderer(multiPolygon: polygons)
        renderer.fillColor = color
        // A hairline of background keeps buildings that touch apart.
        renderer.strokeColor = .black
        renderer.lineWidth = 0.5
        return renderer
    }
}
