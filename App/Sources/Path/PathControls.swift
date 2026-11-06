import SwiftUI

/// Street ↔ Path switch. The camera doesn't move when it changes.
struct MapModePicker: View {
    @Binding var mode: AppModel.MapMode

    var body: some View {
        Picker("Map", selection: $mode) {
            Text("Street").tag(AppModel.MapMode.street)
            Text("Path").tag(AppModel.MapMode.path)
        }
        .pickerStyle(.segmented)
        .frame(width: 150)
        .padding(4)
        .glassEffect(.regular, in: .capsule)
        .accessibilityIdentifier("mapModePicker")
    }
}
