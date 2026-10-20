import CampusGeo
import CampusModel
import CoreLocation
import Foundation
import MapKit
import Observation

/// State and actions for the camera-sync spike screen.
@Observable
final class SpikeModel {
    var mode: MapOverlayContainerView.Mode = .street {
        didSet { view?.setMode(mode, animated: true) }
    }
    var complexity: ShellMeshFactory.Complexity = .shells {
        didSet { view?.loadShells(complexity) }
    }
    /// Launch with `-mapElevation flat` to start flat.
    var elevation = Elevation(rawValue: UserDefaults.standard.string(forKey: "mapElevation") ?? "") ?? .realistic {
        didSet { view?.setElevation(elevation.style) }
    }
    /// Starts from the constants measured in Spike S1; "Calibrate" refits it live.
    var cameraModel = MapKitCameraModel.measured {
        didSet { view?.cameraModel = cameraModel }
    }
    private(set) var stats = SpikeStats()
    private(set) var status = "Ready"
    private(set) var isBusy = false
    private(set) var manualSampleCount = 0
    let campus: CampusBundle?
    let loadError: String?

    @ObservationIgnored private weak var view: MapOverlayContainerView?
    @ObservationIgnored private var manualSamples: [CalibrationSample] = []
    @ObservationIgnored private let locationManager = CLLocationManager()

    init() {
        do {
            guard let url = Bundle.main.url(forResource: "CampusBundle", withExtension: nil) else {
                throw CocoaError(.fileNoSuchFile)
            }
            campus = try CampusBundle.load(from: url)
            loadError = nil
        } catch {
            campus = nil
            loadError = "Couldn't load the campus bundle: \(error.localizedDescription)"
        }
    }

    func attach(_ view: MapOverlayContainerView) {
        self.view = view
        view.onStats = { [weak self] in self?.stats = $0 }
        view.loadShells(complexity)
        view.setElevation(elevation.style)
        view.setMode(mode, animated: false)
        if ProcessInfo.processInfo.arguments.contains("-autoSpike") {
            Task { await runAll() }  // unattended: skip the location prompt so it can't cover the map
        } else {
            locationManager.requestWhenInUseAuthorization()
        }
    }

    // MARK: Actions

    /// Every scripted measurement in order, then leaves the calibrated view in Blend mode.
    func runAll() async {
        guard let view, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        let runner = SpikeRunner(view: view)
        status = "Probing camera limits…"
        SpikeLog.emit("limits", await runner.probeLimits())
        status = "Probing animation sampling…"
        SpikeLog.emit("animation", await runner.probeAnimation())
        await calibrate(using: runner)
        status = "Measuring frame rate…"
        SpikeLog.emit("performance", await runner.probePerformance())
        status = "Spike complete"
        _ = await runner.settle(distance: 450, pitch: 50, heading: 20)
        // `-spikeFinalMode path` ends in Path mode instead (handy for screenshots).
        mode = MapOverlayContainerView.Mode(rawValue: UserDefaults.standard.string(forKey: "spikeFinalMode") ?? "") ?? .blend
        SpikeLog.emit("done", ["status": status])
    }

    func runCalibration() async {
        guard let view, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        await calibrate(using: SpikeRunner(view: view))
    }

    func addManualSample() {
        guard let view else { return }
        manualSamples.append(view.calibrationSample())
        manualSampleCount = manualSamples.count
        status = "\(manualSampleCount) manual samples"
    }

    func solveManualSamples() async {
        guard !manualSamples.isEmpty, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        await solve(manualSamples, label: "manual")
    }

    func resetCalibration() {
        cameraModel = .measured
        manualSamples = []
        manualSampleCount = 0
        status = "Using measured camera model"
    }

    // MARK: Calibration

    private func calibrate(using runner: SpikeRunner) async {
        status = "Sampling 24 camera states…"
        let samples = await runner.collectCalibrationSamples()
        if let path = SpikeLog.save(samples, as: "calibration-samples-\(elevation.rawValue).json") {
            SpikeLog.emit("samplesSaved", ["path": path, "count": "\(samples.count)"])
        }
        await solve(samples, label: "auto")
    }

    private func solve(_ samples: [CalibrationSample], label: String) async {
        guard let campus, let view else { return }
        status = "Solving (\(samples.reduce(0) { $0 + $1.points.count }) points)…"
        let plane = MapPlane(origin: campus.origin)
        let anchor = view.cameraAnchor
        // How well the built-in constants predict this device's MapKit, before refitting.
        let measured = CameraCalibrator.evaluate(model: .measured, anchor: anchor, samples: samples, plane: plane)
        let result = await Task.detached(priority: .userInitiated) {
            CameraCalibrator.solve(samples: samples, plane: plane, initialAnchor: anchor)
        }.value
        cameraModel = result.model

        // Error broken down by pitch shows whether one model fits every tilt.
        var byPitch: [String: Double] = [:]
        for pitch in Set(samples.map { Int($0.camera.pitch.rounded()) }).sorted() {
            let subset = samples.filter { Int($0.camera.pitch.rounded()) == pitch }
            byPitch[String(pitch)] = CameraCalibrator.evaluate(model: result.model, anchor: result.anchor, samples: subset, plane: plane).rmsError
        }
        SpikeLog.emit("calibration", CalibrationReport(
            label: label,
            elevation: elevation.rawValue,
            safeAreaAnchor: anchor,
            samples: samples.count,
            measuredModel: measured,
            fitted: result,
            fittedRMSByPitch: byPitch
        ))
        status = String(
            format: "built-in model %.2f pt · refit FOV %.3f° alt %.4f → %.2f pt",
            measured.rmsError, result.model.verticalFieldOfView, result.model.altitudeScale, result.rmsError
        )
    }

    private struct CalibrationReport: Encodable {
        var label: String
        var elevation: String
        /// The anchor predicted from safe-area insets, to compare with the fitted one.
        var safeAreaAnchor: SIMD2<Double>
        var samples: Int
        /// Error of `MapKitCameraModel.measured` (the built-in constants) on these samples.
        var measuredModel: CalibrationResult
        var fitted: CalibrationResult
        var fittedRMSByPitch: [String: Double]
    }

    enum Elevation: String, CaseIterable, Identifiable {
        case realistic, flat
        var id: Self { self }
        var style: MKMapConfiguration.ElevationStyle { self == .flat ? .flat : .realistic }
    }
}
