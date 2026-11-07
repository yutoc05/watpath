import SwiftUI

/// Bridges `CampusMapController` into SwiftUI. Reading the model in
/// `updateUIView` subscribes it to exactly the state the map needs.
struct CampusMapView: UIViewRepresentable {
    let model: AppModel

    func makeUIView(context: Context) -> CampusMapController {
        let controller = CampusMapController(campus: model.campus)
        controller.onSelect = { [model] place in model.select(place) }
        controller.onPickerCoordinateChange = { [model] coordinate in model.pickerCoordinate = coordinate }
        controller.onAnchorChange = { [model] anchor in model.mapAnchor = anchor }
        controller.onNavigationStatus = { [model] status, isAtEnd in model.updateNavigation(status, isAtEnd: isAtEnd) }
        return controller
    }

    func updateUIView(_ controller: CampusMapController, context: Context) {
        controller.apply(mode: model.mapMode, animated: true)
        controller.pickerSnapsToLines = model.directions.step == .pickingOriginInPath
        controller.isPicking = model.activity == .pickingLocation
        controller.isSelectionLocked = model.activity != .browsing
        controller.cardHeight = model.cardHeight
        controller.apply(selection: model.selection)
        controller.apply(cameraRequest: model.cameraRequest)
        controller.apply(routePreview: model.routePreview)
        controller.apply(navigation: model.directions.activeRoute)
    }
}
