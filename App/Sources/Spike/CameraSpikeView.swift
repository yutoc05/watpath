import CampusModel
import SwiftUI

/// Debug screen for Spikes S1/S2: switch Street/Blend/Path, calibrate the camera
/// model against MapKit, and load heavier geometry to check frame rate.
struct CameraSpikeView: View {
    @State private var model = SpikeModel()
    @State private var showsPanel = true

    var body: some View {
        ZStack {
            if let campus = model.campus {
                MapOverlayRepresentable(model: model, campus: campus)
                    .ignoresSafeArea()
            } else {
                ContentUnavailableView("No campus data", systemImage: "map", description: Text(model.loadError ?? ""))
            }
        }
        .overlay(alignment: .top) {
            Picker("Mode", selection: $model.mode) {
                ForEach(MapOverlayContainerView.Mode.allCases) { Text($0.rawValue.capitalized).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 260)
            .padding(.top, 8)
        }
        .overlay(alignment: .bottom) {
            panel
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
        }
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.snappy) { showsPanel.toggle() }
            } label: {
                Label(model.status, systemImage: showsPanel ? "chevron.down" : "chevron.up")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            if showsPanel {
                Text(statsText)
                    .font(.caption2.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack {
                    Picker("Geometry", selection: $model.complexity) {
                        ForEach(CampusSceneBuilder.Complexity.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Picker("Elevation", selection: $model.elevation) {
                        ForEach(SpikeModel.Elevation.allCases) { Text($0.rawValue).tag($0) }
                    }
                }
                .pickerStyle(.segmented)

                HStack {
                    action("Auto") { await model.runAll() }
                    action("Calibrate") { await model.runCalibration() }
                    Button("Sample \(model.manualSampleCount)") { model.addManualSample() }
                    action("Solve") { await model.solveManualSamples() }
                    Button("Reset", role: .destructive) { model.resetCalibration() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(model.isBusy)
            }
        }
        .padding(12)
        .background(.regularMaterial, in: .rect(cornerRadius: 16))
    }

    private func action(_ title: String, _ work: @escaping () async -> Void) -> some View {
        Button(title) { Task { await work() } }
    }

    private var statsText: String {
        let stats = model.stats
        let cameraModel = model.cameraModel
        var lines: [String] = []
        if let camera = stats.camera {
            lines.append(String(format: "dist %7.1f m  pitch %4.1f°  heading %5.1f°", camera.distance, camera.pitch, camera.heading))
        }
        lines.append(String(
            format: "MapKit↔model %@  RealityKit↔model %@",
            stats.mapKitError.map { String(format: "%.2f pt", $0) } ?? "–",
            stats.renderError.map { String(format: "%.2f pt", $0) } ?? "–"
        ))
        lines.append(String(format: "FOV %.3f°  altitude scale %.4f", cameraModel.verticalFieldOfView, cameraModel.altitudeScale))
        lines.append(String(format: "render %.0f fps  %d entities  %d tris", stats.renderFPS, stats.entities, stats.triangles))
        return lines.joined(separator: "\n")
    }
}

private struct MapOverlayRepresentable: UIViewRepresentable {
    let model: SpikeModel
    let campus: CampusBundle

    func makeUIView(context: Context) -> MapOverlayContainerView {
        let view = MapOverlayContainerView(campus: campus, cameraModel: model.cameraModel)
        model.attach(view)
        return view
    }

    func updateUIView(_ view: MapOverlayContainerView, context: Context) {}
}
