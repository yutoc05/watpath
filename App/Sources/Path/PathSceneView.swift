import CampusGeo
import Combine
import RealityKit
import UIKit

/// The Path Map's 3D view: RealityKit drawing the campus from MapKit's camera
/// (docs/adr/001-camera-architecture.md). It never takes touches; gestures fall
/// through to the map underneath, which stays in charge of the camera.
final class PathSceneView: UIView {
    let plane: MapPlane
    var cameraModel = MapKitCameraModel.measured
    /// Frames RealityKit has rendered since launch (frame-rate probes diff this).
    private(set) var renderedFrames = 0
    private(set) var scene: CampusScene?

    private let arView = ARView(frame: .zero, cameraMode: .nonAR, automaticallyConfigureSession: false)
    private let renderCamera = PerspectiveCamera()
    private let world = AnchorEntity(world: .zero)
    private var renderSubscription: (any Cancellable)?
    private var highlightedBuilding: String?
    /// Camera distance at the last sync, for lifting the highlighted building.
    private var cameraDistance: Float = 1_000
    /// How far the highlighted building is lifted, per meter of camera distance.
    /// Where outlines overlap (EV3 was built over part of EV2) both floors lie in
    /// one plane, and the depth buffer can't tell which is in front, so the orange
    /// one flickers through the grey one as you zoom. A lift well above what the
    /// depth buffer can resolve at that distance, but far below a pixel, puts it
    /// cleanly on top.
    private static let highlightLiftPerMeter: Float = 0.0005
    /// Building code → index of the one floor shown; buildings not listed show none.
    private var displayedFloors: [String: Int] = [:]

    init(plane: MapPlane) {
        self.plane = plane
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        arView.environment.background = .color(.black)
        arView.renderOptions = [.disableMotionBlur, .disableDepthOfField, .disableGroundingShadows, .disableCameraGrain, .disableAREnvironmentLighting]
        renderCamera.camera.fieldOfViewOrientation = .vertical
        world.addChild(renderCamera)
        arView.scene.addAnchor(world)
        addSubview(arView)
        renderSubscription = arView.scene.subscribe(to: SceneEvents.Update.self) { [weak self] _ in
            MainActor.assumeIsolated { self?.renderedFrames += 1 }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        arView.frame = bounds  // MapKit's optical axis is the view's center, like RealityKit's
    }

    func load(_ newScene: CampusScene) {
        scene?.entities.forEach { $0.removeFromParent() }
        for entity in newScene.entities { world.addChild(entity) }
        scene = newScene
        let highlighted = highlightedBuilding
        highlightedBuilding = nil
        setHighlightedBuilding(highlighted)
        setDisplayedFloors(displayedFloors)
    }

    /// Points the RealityKit camera exactly where MapKit's is. `anchor` is where
    /// MapKit keeps its center: the safe-area middle, as an offset from the view's middle.
    func sync(to state: MapCameraState, anchor: SIMD2<Double>) {
        guard bounds.height > 0 else { return }
        let pose = CameraPose(state: state, plane: plane, model: cameraModel, viewportSize: SIMD2(Double(bounds.width), Double(bounds.height)), anchor: anchor)
        // The camera looks down its local -z with +y up, so its z axis points backward.
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
        if distance != cameraDistance {
            cameraDistance = distance
            liftHighlightedBuilding()
        }
    }

    private func liftHighlightedBuilding() {
        guard let code = highlightedBuilding else { return }
        let lift = max(0.02, cameraDistance * Self.highlightLiftPerMeter)
        for floor in scene?.entities(of: code) ?? [] {
            floor.position = SIMD3(0, lift, 0)  // RenderSpace y is up
        }
    }

    /// Where RealityKit actually drew `point` (for checking the camera math).
    func renderedPoint(_ point: SIMD3<Double>) -> CGPoint? {
        arView.project(RenderSpace.point(point)).map { arView.convert($0, to: self) }
    }

    func setHighlightedBuilding(_ code: String?) {
        guard code != highlightedBuilding else { return }
        for (oldOrNew, highlighted) in [(highlightedBuilding, false), (code, true)] {
            guard let oldOrNew, let floors = scene?.entities(of: oldOrNew) else { continue }
            let materials = CampusSceneBuilder.buildingMaterials(highlighted: highlighted)
            for floor in floors {
                floor.model?.materials = materials
                floor.position = .zero
            }
        }
        highlightedBuilding = code
        liftHighlightedBuilding()
    }

    /// Shows exactly one floor of each building with Path Map floors: `floors[code]`
    /// indexes `Building.floors`. Footprints always show.
    func setDisplayedFloors(_ floors: [String: Int]) {
        displayedFloors = floors
        for (code, entities) in scene?.buildingFloors ?? [:] {
            for (index, entity) in entities {
                entity.isEnabled = index == floors[code]
            }
        }
    }
}

/// RealityKit is y-up with -z forward; the map plane is z-up. (east, north, up)
/// maps to RealityKit (x, y, z) = (east, up, -north), a proper rotation.
enum RenderSpace {
    static func point(_ p: SIMD3<Double>) -> SIMD3<Float> {
        SIMD3(Float(p.x), Float(p.z), Float(-p.y))
    }
}
