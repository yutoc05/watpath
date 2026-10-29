import CampusModel
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

/// Path Map floor picker, like Apple Maps' indoor one: the focused building's Path
/// Map floors (those a bridge, tunnel or link meets), top first. Each building
/// shows one floor at a time, so this picks which; it only appears when there are
/// at least two to pick from.
struct FloorPicker: View {
    let model: AppModel
    let building: Building

    var body: some View {
        let shown = model.displayedFloorIndex(of: building)
        VStack(spacing: 2) {
            Text(building.code)
                .font(.caption.weight(.heavy))
                .foregroundStyle(.secondary)
                .frame(width: 40, height: 22)
                .accessibilityIdentifier("floorPickerBuilding")
            ForEach(building.mappedFloorIndices.reversed(), id: \.self) { index in
                floorButton(index, isSelected: index == shown)
            }
        }
        .padding(4)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
        .animation(.snappy, value: building.code)
    }

    private func floorButton(_ index: Int, isSelected: Bool) -> some View {
        let name = building.floors[index].name
        return Button {
            model.showFloor(index, of: building)
        } label: {
            Text(name)
                .font(.subheadline.weight(.semibold))
                .frame(width: 40, height: 32)
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .background(isSelected ? Color.accentColor : .clear, in: .capsule)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(building.code) floor \(name)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
