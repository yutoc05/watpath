import CampusGeo
import CampusModel
import Combine
import MapKit
import RealityKit
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
    let pathView = ARView(frame: .zero, cameraMode: .nonAR, automaticallyConfigureSession: false)
    let plane: MapPlane
    let campus: CampusBundle
    /// Where scripted spike runs point the camera: the middle of MC.
    let spikeCenter: GeoCoordinate

    var cameraModel: MapKitCameraModel
    var onStats: ((SpikeStats) -> Void)?
    /// Called every display frame with MapKit's current camera (used by probes).
    var frameObserver: ((MKMapCamera) -> Void)?
    private(set) var mode: Mode = .street

    private let renderCamera = PerspectiveCamera()
    private let world = AnchorEntity(world: .zero)
    private var shellEntities: [Entity] = []
    private var displayLink: CADisplayLink?
    private var renderSubscription: (any Cancellable)?
    private var renderFrames = 0
    /// Frames RealityKit has updated since launch (frame-rate probes diff this).
    private(set) var totalRenderFrames = 0
    private var statsWindowStart = CACurrentMediaTime()
    private(set) var stats = SpikeStats()
    private let alignmentOutline: [GeoCoordinate]
    private let compassButton: MKCompassButton
    private let trackingButton: MKUserTrackingButton
    private let pitchButton = UIButton(type: .system)
    private let controlsBackground = UIVisualEffectView(effect: UIBlurEffect(style: .systemThickMaterial))

    init(campus: CampusBundle, cameraModel: MapKitCameraModel) {
        self.campus = campus
        self.cameraModel = cameraModel
        plane = MapPlane(origin: campus.origin)
        var outline = campus.building(code: "MC")?.parts.first?.outline ?? []
        if outline.count > 1, outline.first == outline.last { outline.removeLast() }
        alignmentOutline = outline
        spikeCenter = outline.isEmpty ? campus.origin : plane.coordinate(fromPlanar: outline.map(plane.planar).reduce(.zero, +) / Double(outline.count))
        compassButton = MKCompassButton(mapView: mapView)
        trackingButton = MKUserTrackingButton(mapView: mapView)
        super.init(frame: .zero)
        clipsToBounds = true
        backgroundColor = .black

        mapView.delegate = self
        setElevation(.realistic)
        // MapKit's built-in controls live inside the map view, so the Path overlay
        // would cover them. Standalone controls are added above the overlay instead.
        mapView.showsCompass = false
        mapView.showsUserTrackingButton = false
        mapView.pitchButtonVisibility = .hidden
        mapView.showsUserLocation = true
        mapView.camera = MKMapCamera(lookingAtCenter: spikeCenter.clCoordinate, fromDistance: 900, pitch: 45, heading: 0)
        addSubview(mapView)

        pathView.isUserInteractionEnabled = false
        pathView.environment.background = .color(.black)
        pathView.renderOptions = [.disableMotionBlur, .disableDepthOfField, .disableGroundingShadows, .disableCameraGrain, .disableAREnvironmentLighting]
        pathView.alpha = 0
        pathView.isHidden = true
        renderCamera.camera.fieldOfViewOrientation = .vertical
        world.addChild(renderCamera)
        pathView.scene.addAnchor(world)
        addSubview(pathView)
        renderSubscription = pathView.scene.subscribe(to: SceneEvents.Update.self) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.renderFrames += 1
                self?.totalRenderFrames += 1
            }
        }

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

    func loadShells(_ complexity: ShellMeshFactory.Complexity) {
        shellEntities.forEach { $0.removeFromParent() }
        do {
            let start = CACurrentMediaTime()
            let result = try ShellMeshFactory(plane: plane).makeEntities(for: campus, complexity: complexity, highlight: "MC")
            for entity in result.entities { world.addChild(entity) }
            shellEntities = result.entities
            stats.triangles = result.triangles
            stats.entities = result.entities.count
            SpikeLog.emit("shells", ShellReport(
                complexity: complexity.rawValue,
                entities: result.entities.count,
                triangles: result.triangles,
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
            stats.renderFPS = Double(renderFrames) / (now - statsWindowStart)
            renderFrames = 0
            statsWindowStart = now
            measureAlignment()
            onStats?(stats)
        }
    }

    func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) {
        // Also sync here: during gestures this fires as soon as MapKit moves.
        syncRenderCamera()
        updatePitchButton()
    }

    private func syncRenderCamera() {
        let state = MapCameraState(mapView.camera)
        guard bounds.height > 0 else { return }
        let pose = CameraPose(state: state, plane: plane, model: cameraModel, viewportSize: viewportSize, anchor: cameraAnchor)
        // Camera looks down its local -z with +y up, so its z axis points backward.
        renderCamera.transform = Transform(matrix: float4x4(
            SIMD4(RenderSpace.point(pose.right), 0),
            SIMD4(RenderSpace.point(pose.up), 0),
            SIMD4(RenderSpace.point(-pose.forward), 0),
            SIMD4(RenderSpace.point(pose.eye), 1)
        ))
        let distance = Float(state.distance)
        renderCamera.camera.near = max(0.25, distance * 0.02)
        renderCamera.camera.far = distance * 40 + 5_000
        renderCamera.camera.fieldOfViewInDegrees = Float(cameraModel.verticalFieldOfView)
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
            if let rendered = pathView.project(RenderSpace.point(point)) {
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
        compassButton.compassVisibility = .adaptive
        pitchButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        pitchButton.addTarget(self, action: #selector(togglePitch), for: .touchUpInside)
        updatePitchButton()

        let stack = UIStackView(arrangedSubviews: [trackingButton, pitchButton])
        stack.axis = .vertical
        stack.translatesAutoresizingMaskIntoConstraints = false
        controlsBackground.layer.cornerRadius = 10
        controlsBackground.clipsToBounds = true
        controlsBackground.contentView.addSubview(stack)
        controlsBackground.translatesAutoresizingMaskIntoConstraints = false
        compassButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(controlsBackground)
        addSubview(compassButton)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: controlsBackground.contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: controlsBackground.contentView.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: controlsBackground.contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: controlsBackground.contentView.trailingAnchor),
            trackingButton.widthAnchor.constraint(equalToConstant: 44),
            trackingButton.heightAnchor.constraint(equalToConstant: 44),
            pitchButton.heightAnchor.constraint(equalToConstant: 44),
            controlsBackground.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 56),
            controlsBackground.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -10),
            compassButton.topAnchor.constraint(equalTo: controlsBackground.bottomAnchor, constant: 10),
            compassButton.centerXAnchor.constraint(equalTo: controlsBackground.centerXAnchor),
        ])
    }

    @objc private func togglePitch() {
        guard let camera = mapView.camera.copy() as? MKMapCamera else { return }
        camera.pitch = mapView.camera.pitch < 1 ? 60 : 0
        mapView.setCamera(camera, animated: true)
    }

    private func updatePitchButton() {
        // Like Apple Maps: the button names the mode you'd switch to.
        pitchButton.setTitle(mapView.camera.pitch < 1 ? "3D" : "2D", for: .normal)
    }
}
