import SwiftUI

/// Bridges `StreetMapController` into SwiftUI. Reading the model in
/// `updateUIView` subscribes it to exactly the state the map needs.
struct StreetMapView: UIViewRepresentable {
    let model: AppModel

    func makeUIView(context: Context) -> StreetMapController {
        let controller = StreetMapController(campus: model.campus)
        controller.onSelect = { [model] place in model.select(place) }
        controller.onPickerCoordinateChange = { [model] coordinate in model.pickerCoordinate = coordinate }
        controller.onAnchorChange = { [model] anchor in model.mapAnchor = anchor }
        return controller
    }

    func updateUIView(_ controller: StreetMapController, context: Context) {
        controller.isPicking = model.activity == .pickingLocation
        controller.cardHeight = model.cardHeight
        controller.apply(selection: model.selection)
        controller.apply(cameraRequest: model.cameraRequest)
    }
}
