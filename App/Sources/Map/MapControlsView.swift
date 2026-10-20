import MapKit
import UIKit

/// Apple Maps-style controls (locate me, 2D/3D, compass) that work above an
/// overlay. MapKit's built-in buttons live inside the map view, where the Path
/// Map overlay would cover them (docs/adr/001-camera-architecture.md).
final class MapControlsView: UIView {
    private let mapView: MKMapView
    private let trackingButton: MKUserTrackingButton
    private let pitchButton = UIButton(type: .system)
    private let compassButton: MKCompassButton
    private let buttonBackground = UIVisualEffectView(effect: UIGlassEffect())

    init(mapView: MKMapView) {
        self.mapView = mapView
        trackingButton = MKUserTrackingButton(mapView: mapView)
        compassButton = MKCompassButton(mapView: mapView)
        super.init(frame: .zero)

        mapView.showsCompass = false
        mapView.showsUserTrackingButton = false
        mapView.pitchButtonVisibility = .hidden

        compassButton.compassVisibility = .adaptive
        pitchButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        pitchButton.accessibilityHint = "Switches between a flat map and a tilted 3D view"
        pitchButton.addTarget(self, action: #selector(togglePitch), for: .touchUpInside)
        updatePitchButton()

        let stack = UIStackView(arrangedSubviews: [trackingButton, pitchButton])
        stack.axis = .vertical
        buttonBackground.layer.cornerRadius = 22
        buttonBackground.clipsToBounds = true
        buttonBackground.contentView.addSubview(stack)
        addSubview(buttonBackground)
        addSubview(compassButton)

        for view in [stack, buttonBackground, compassButton] as [UIView] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: buttonBackground.contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: buttonBackground.contentView.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: buttonBackground.contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: buttonBackground.contentView.trailingAnchor),
            trackingButton.widthAnchor.constraint(equalToConstant: 44),
            trackingButton.heightAnchor.constraint(equalToConstant: 44),
            pitchButton.heightAnchor.constraint(equalToConstant: 44),
            buttonBackground.topAnchor.constraint(equalTo: topAnchor),
            buttonBackground.leadingAnchor.constraint(equalTo: leadingAnchor),
            buttonBackground.trailingAnchor.constraint(equalTo: trailingAnchor),
            compassButton.topAnchor.constraint(equalTo: buttonBackground.bottomAnchor, constant: 10),
            compassButton.centerXAnchor.constraint(equalTo: centerXAnchor),
            compassButton.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Call when the camera changes so the 2D/3D button shows the right mode.
    func updatePitchButton() {
        // Like Apple Maps: the button names the mode you'd switch to.
        pitchButton.setTitle(mapView.camera.pitch < 1 ? "3D" : "2D", for: .normal)
    }

    @objc private func togglePitch() {
        guard let camera = mapView.camera.copy() as? MKMapCamera else { return }
        camera.pitch = mapView.camera.pitch < 1 ? 60 : 0
        mapView.setCamera(camera, animated: true)
    }
}
