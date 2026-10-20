import SwiftUI

/// "Choose location on map": a pin fixed where the map keeps its center, with the
/// live coordinate underneath. The map moves; the pin doesn't.
struct LocationPickerOverlay: View {
    let model: AppModel
    private let pinHeight = 44.0

    var body: some View {
        ZStack {
            if let anchor = model.mapAnchor {
                pin
                    // Put the pin's tip, not its middle, on the anchor point.
                    .position(x: anchor.x, y: anchor.y - pinHeight / 2)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            }
            VStack {
                VStack(spacing: 4) {
                    Text("Choose location on map").font(.headline)
                    Text(model.pickerCoordinate?.formatted ?? " ")
                        .accessibilityIdentifier("pickerCoordinate")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
                .padding(.vertical, 12)
                .padding(.horizontal, 20)
                .glassEffect(.regular, in: .rect(cornerRadius: 22))
                .padding(.top, 8)

                Spacer()

                HStack(spacing: 12) {
                    Button("Cancel") { model.cancelPickingLocation() }
                        .buttonStyle(.glass)
                    Button("Set Location") { model.finishPickingLocation() }
                        .buttonStyle(.glassProminent)
                        .disabled(model.pickerCoordinate == nil)
                }
                .controlSize(.large)
                .padding(.bottom, 12)
            }
        }
    }

    private var pin: some View {
        Image(systemName: "mappin")
            .font(.system(size: 40, weight: .semibold))
            .foregroundStyle(.red)
            .shadow(radius: 3, y: 2)
            .frame(height: pinHeight, alignment: .bottom)
            .background(alignment: .bottom) {
                Ellipse().fill(.black.opacity(0.25)).frame(width: 12, height: 5).offset(y: 2)
            }
    }
}
