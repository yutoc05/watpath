import CampusGeo
import MapKit

/// Scripted measurements for Spike S1 (docs/PLAN.md §4.2). Each one drives the
/// real MapKit camera and reports what MapKit actually did, since MapKit silently
/// clamps cameras it doesn't like.
struct SpikeRunner {
    let view: MapOverlayContainerView

    struct LimitsReport: Encodable {
        /// "requestedDistance@requestedPitch" → [actual distance, actual pitch].
        var closeRange: [String: [Double]] = [:]
        /// Distance requested → steepest pitch MapKit allowed.
        var maxPitchByDistance: [String: Double] = [:]
        var distanceAtMaxPitchByDistance: [String: Double] = [:]
    }

    struct AnimationReport: Encodable {
        var frames: Int
        var distinctDistances: Int
        var firstDistance: Double
        var lastDistance: Double
        /// True if `mapView.camera` moves during `setCamera(_:animated: true)`. If
        /// false, the overlay would jump to the end of every MapKit animation.
        var reportsIntermediateCameras: Bool
    }

    func probeLimits() async -> LimitsReport {
        var report = LimitsReport()
        // Requesting an impossible camera can make MapKit give up on the pitch too,
        // so walk the distance down and record what it actually keeps.
        for pitch in [0.0, 30, 45, 60, 75] {
            for distance in [20.0, 30, 45, 60, 90, 150] {
                let actual = await settle(distance: distance, pitch: pitch)
                report.closeRange["\(key(distance))@\(key(pitch))"] = [actual.centerCoordinateDistance, Double(actual.pitch)]
            }
        }
        for distance in [40.0, 80, 150, 300, 600, 1200, 2500] {
            let actual = await settle(distance: distance, pitch: 89)
            report.maxPitchByDistance[key(distance)] = Double(actual.pitch)
            report.distanceAtMaxPitchByDistance[key(distance)] = actual.centerCoordinateDistance
        }
        return report
    }

    func probeAnimation() async -> AnimationReport {
        _ = await settle(distance: 1500, pitch: 0)
        final class Recorder { var distances: [Double] = [] }
        let recorder = Recorder()
        view.frameObserver = { recorder.distances.append($0.centerCoordinateDistance) }
        let target = MKMapCamera(lookingAtCenter: view.spikeCenter.clCoordinate, fromDistance: 300, pitch: 50, heading: 30)
        view.mapView.setCamera(target, animated: true)
        try? await Task.sleep(for: .seconds(2))
        view.frameObserver = nil
        let distinct = Set(recorder.distances.map { ($0 * 10).rounded() }).count
        return AnimationReport(
            frames: recorder.distances.count,
            distinctDistances: distinct,
            firstDistance: recorder.distances.first ?? 0,
            lastDistance: recorder.distances.last ?? 0,
            reportsIntermediateCameras: distinct > 3
        )
    }

    struct PerformanceReport: Encodable {
        var complexity: String
        var entities: Int
        var triangles: Int
        var renderFPS: Double
        var displayFPS: Double
        /// Display frames that took over 1.5× the screen's refresh interval.
        var droppedFramePercent: Double
    }

    /// Spike S2: orbits the camera in Path mode for each geometry level and measures
    /// how often RealityKit and the main thread keep up.
    func probePerformance() async -> [PerformanceReport] {
        final class Recorder { var timestamps: [CFTimeInterval] = [] }
        let previousMode = view.mode
        view.setMode(.path, animated: false)
        var reports: [PerformanceReport] = []
        for complexity in ShellMeshFactory.Complexity.allCases {
            view.loadShells(complexity)
            _ = await settle(distance: 600, pitch: 60)
            let recorder = Recorder()
            let renderStart = view.totalRenderFrames
            view.frameObserver = { [view] camera in
                recorder.timestamps.append(CACurrentMediaTime())
                guard let next = camera.copy() as? MKMapCamera else { return }
                next.heading += 0.75
                view.mapView.setCamera(next, animated: false)
            }
            try? await Task.sleep(for: .seconds(4))
            view.frameObserver = nil

            let stamps = recorder.timestamps
            let duration = max((stamps.last ?? 0) - (stamps.first ?? 0), 1e-3)
            let intervals = zip(stamps.dropFirst(), stamps).map { $0 - $1 }
            let refresh = 1 / Double(view.window?.screen.maximumFramesPerSecond ?? 60)
            reports.append(PerformanceReport(
                complexity: complexity.rawValue,
                entities: view.stats.entities,
                triangles: view.stats.triangles,
                renderFPS: Double(view.totalRenderFrames - renderStart) / duration,
                displayFPS: Double(intervals.count) / duration,
                droppedFramePercent: 100 * Double(intervals.filter { $0 > refresh * 1.5 }.count) / Double(max(intervals.count, 1))
            ))
        }
        view.loadShells(.shells)
        view.setMode(previousMode, animated: false)
        return reports
    }

    /// 24 camera states mixing distance, pitch and heading, one sample each.
    func collectCalibrationSamples() async -> [CalibrationSample] {
        var samples: [CalibrationSample] = []
        for distance in [200.0, 500, 1200] {
            for pitch in [0.0, 30, 50, 70] {
                for heading in [0.0, 135] {
                    _ = await settle(distance: distance, pitch: pitch, heading: heading)
                    samples.append(view.calibrationSample())
                }
            }
        }
        return samples
    }

    /// Sets the camera without animation and waits for MapKit to settle (and clamp).
    @discardableResult
    func settle(distance: Double, pitch: Double, heading: Double = 0) async -> MKMapCamera {
        let camera = MKMapCamera(lookingAtCenter: view.spikeCenter.clCoordinate, fromDistance: distance, pitch: pitch, heading: heading)
        view.mapView.setCamera(camera, animated: false)
        try? await Task.sleep(for: .milliseconds(450))
        return view.mapView.camera
    }

    private func key(_ value: Double) -> String { String(Int(value)) }
}
