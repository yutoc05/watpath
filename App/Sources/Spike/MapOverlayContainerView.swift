import CampusGeo
import CampusModel
import MapKit
import UIKit

/// Live numbers for the spike HUD.
struct SpikeStats: Equatable {
    var camera: MapCameraState?
    var renderFPS = 0.0
    /// RMS distance (points) over MC's outline between where MapKit draws it and
    /// where our camera model puts it. Near zero means the overlay lines up.
    var mapKitError: Double?
    /// Same, between RealityKit's own projection and our model. Should be ~0; if
    /// not, the RealityKit camera setup disagrees with the math.
    var renderError: Double?
    var triangles = 0
    var entities = 0
}

/// Spike S1 (docs/PLAN.md §4.2, Option A): MapKit owns gestures and the camera;
/// a RealityKit view on top, which touches pass straight through, re-renders the
/// campus from MapKit's camera on every display frame.
final class MapOverlayContainerView: UIView, MKMapViewDelegate {
    enum Mode: String, CaseIterable, Identifiable {
        case street, blend, path
        var id: Self { self }
    }

    let mapView = MKMapView()
    let pathView: PathSceneView
    let plane: MapPlane
    let campus: CampusBundle
    /// Where scripted spike runs point the camera: the middle of MC.
    let spikeCenter: GeoCoordinate

    var cameraModel: MapKitCameraModel {
        didSet { pathView.cameraModel = cameraModel }
    }
    var onStats: ((SpikeStats) -> Void)?
    /// Called every display frame with MapKit's current camera (used by probes).
    var frameObserver: ((MKMapCamera) -> Void)?
    private(set) var mode: Mode = .street

    private var displayLink: CADisplayLink?
    private var renderedFramesAtWindowStart = 0
    private var statsWindowStart = CACurrentMediaTime()
    private(set) var stats = SpikeStats()
    private let alignmentOutline: [GeoCoordinate]
    private lazy var controls = MapControlsView(mapView: mapView)

    init(campus: CampusBundle, cameraModel: MapKitCameraModel) {
        self.campus = campus
        self.cameraModel = cameraModel
        plane = MapPlane(origin: campus.origin)
        pathView = PathSceneView(plane: plane)
        pathView.cameraModel = cameraModel
        var outline = campus.building(code: "MC")?.parts.first?.outline ?? []
        if outline.count > 1, outline.first == outline.last { outline.removeLast() }
        alignmentOutline = outline
        spikeCenter = outline.isEmpty ? campus.origin : plane.coordinate(fromPlanar: outline.map(plane.planar).reduce(.zero, +) / Double(outline.count))
        super.init(frame: .zero)
        clipsToBounds = true
        backgroundColor = .black

        mapView.delegate = self
        setElevation(.realistic)
        mapView.showsUserLocation = true
        mapView.camera = MKMapCamera(lookingAtCenter: spikeCenter.clCoordinate, fromDistance: 900, pitch: 45, heading: 0)
        addSubview(mapView)

        pathView.alpha = 0
        pathView.isHidden = true
        addSubview(pathView)

        setUpControls()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: Modes and content

    func setMode(_ newMode: Mode, animated: Bool) {
        mode = newMode
        let alpha: CGFloat = switch newMode {
        case .street: 0
        case .blend: 0.55
        case .path: 1
        }
        if alpha > 0 { pathView.isHidden = false }
        UIView.animate(withDuration: animated ? 0.25 : 0, delay: 0, options: [.beginFromCurrentState]) {
            self.pathView.alpha = alpha
        } completion: { _ in
            if self.mode == .street { self.pathView.isHidden = true }
        }
    }

    /// Realistic elevation drapes the map over real terrain; our model assumes a
    /// flat campus, so the spike compares both.
    func setElevation(_ style: MKMapConfiguration.ElevationStyle) {
        mapView.preferredConfiguration = MKStandardMapConfiguration(elevationStyle: style)
    }

    /// Where MapKit keeps the center coordinate on screen: the middle of the safe
    /// area, as an offset from the view's middle. Calibration recovers it independently.
    var cameraAnchor: SIMD2<Double> {
        let insets = mapView.safeAreaInsets
        return SIMD2(Double(insets.left - insets.right) / 2, Double(insets.top - insets.bottom) / 2)
    }

    func loadShells(_ complexity: CampusSceneBuilder.Complexity) {
        do {
            let start = CACurrentMediaTime()
            let scene = try CampusSceneBuilder(plane: plane).build(campus, complexity: complexity)
            pathView.load(scene)
            pathView.setHighlightedBuilding("MC")
            stats.triangles = scene.triangles
            stats.entities = scene.entities.count
            SpikeLog.emit("shells", ShellReport(
                complexity: complexity.rawValue,
                entities: scene.entities.count,
                triangles: scene.triangles,
                buildMilliseconds: (CACurrentMediaTime() - start) * 1000
            ))
        } catch {
            SpikeLog.emit("shellsFailed", ["error": "\(error)"])
        }
    }

    private struct ShellReport: Encodable {
        var complexity: String
        var entities: Int
        var triangles: Int
        var buildMilliseconds: Double
    }

    // MARK: Camera sync

    override func didMoveToWindow() {
        super.didMoveToWindow()
        displayLink?.invalidate()
        displayLink = nil
        guard window != nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(displayFrame))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        mapView.frame = bounds
        pathView.frame = bounds  // MapKit's optical axis is the view's center, like RealityKit's
        syncRenderCamera()
    }

    @objc private func displayFrame() {
        syncRenderCamera()
        frameObserver?(mapView.camera)
        let now = CACurrentMediaTime()
        if now - statsWindowStart >= 0.5 {
            stats.renderFPS = Double(pathView.renderedFrames - renderedFramesAtWindowStart) / (now - statsWindowStart)
            renderedFramesAtWindowStart = pathView.renderedFrames
            statsWindowStart = now
            measureAlignment()
            onStats?(stats)
        }
    }

    func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) {
        // Also sync here: during gestures this fires as soon as MapKit moves.
        syncRenderCamera()
        controls.updatePitchButton()
    }

    private func syncRenderCamera() {
        let state = MapCameraState(mapView.camera)
        pathView.sync(to: state, anchor: cameraAnchor)
        stats.camera = state
    }

    private var viewportSize: SIMD2<Double> {
        SIMD2(Double(bounds.width), Double(bounds.height))
    }

    private func measureAlignment() {
        guard let state = stats.camera, bounds.width > 0 else { return }
        let projector = PinholeProjector(state: state, plane: plane, model: cameraModel, viewportSize: viewportSize, anchor: cameraAnchor)
        var mapKitSquares: [Double] = []
        var renderSquares: [Double] = []
        for coordinate in alignmentOutline {
            let point = plane.point(coordinate)
            guard let model = projector.project(point), bounds.contains(CGPoint(x: model.x, y: model.y)) else { continue }
            let drawn = mapView.convert(coordinate.clCoordinate, toPointTo: self)
            mapKitSquares.append(squaredDistance(drawn, model))
            if let rendered = pathView.renderedPoint(point) {
                renderSquares.append(squaredDistance(pathView.convert(rendered, to: self), model))
            }
        }
        stats.mapKitError = rootMeanSquare(mapKitSquares)
        stats.renderError = rootMeanSquare(renderSquares)
    }

    private func squaredDistance(_ point: CGPoint, _ model: SIMD2<Double>) -> Double {
        let dx = Double(point.x) - model.x, dy = Double(point.y) - model.y
        return dx * dx + dy * dy
    }

    private func rootMeanSquare(_ squares: [Double]) -> Double? {
        squares.isEmpty ? nil : (squares.reduce(0, +) / Double(squares.count)).squareRoot()
    }

    // MARK: Calibration sampling

    /// Records where MapKit draws a grid of ground points for the current camera.
    /// Points near the horizon are skipped: tiny screen moves there span huge
    /// distances, so they'd dominate the fit with noise.
    func calibrationSample(columns: Int = 9, rows: Int = 17) -> CalibrationSample {
        let state = MapCameraState(mapView.camera)
        let center = plane.planar(state.center)
        var points: [Correspondence] = []
        for row in 0..<rows {
            for column in 0..<columns {
                let screen = CGPoint(
                    x: bounds.width * (0.06 + 0.88 * CGFloat(column) / CGFloat(columns - 1)),
                    y: bounds.height * (0.06 + 0.88 * CGFloat(row) / CGFloat(rows - 1))
                )
                let coordinate = mapView.convert(screen, toCoordinateFrom: self)
                guard CLLocationCoordinate2DIsValid(coordinate) else { continue }
                let ground = GeoCoordinate(coordinate)
                let offset = plane.planar(ground) - center
                guard (offset * offset).sum().squareRoot() < state.distance * 6 else { continue }
                points.append(Correspondence(coordinate: ground, screen: SIMD2(Double(screen.x), Double(screen.y))))
            }
        }
        return CalibrationSample(camera: state, viewportSize: viewportSize, points: points)
    }

    // MARK: Controls

    private func setUpControls() {
        controls.translatesAutoresizingMaskIntoConstraints = false
        addSubview(controls)
        NSLayoutConstraint.activate([
            controls.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 56),
            controls.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -10),
        ])
    }
}
