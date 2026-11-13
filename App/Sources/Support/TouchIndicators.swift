#if DEBUG
import UIKit
import UIKit.UIGestureRecognizerSubclass

/// Draws a soft circle under every finger, so a screen recording shows what the hands are
/// doing. Debug builds only, and only when launched with `-showTouches`: the demo video
/// turns it on.
enum TouchIndicators {
    /// The window the circles are drawn in. It sits above everything, sheets included,
    /// and never takes a touch.
    private static var overlay: UIWindow?

    static func installIfRequested() {
        guard overlay == nil, ProcessInfo.processInfo.arguments.contains("-showTouches") else { return }
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
              let window = scene.windows.first(where: \.isKeyWindow) ?? scene.windows.first
        else { return }
        let overlay = UIWindow(windowScene: scene)
        overlay.windowLevel = .alert + 1
        overlay.isUserInteractionEnabled = false
        overlay.backgroundColor = .clear
        overlay.isHidden = false
        self.overlay = overlay
        window.addGestureRecognizer(TouchWatcher(drawingIn: overlay))
    }
}

/// Follows every touch in the window without ever recognizing anything, so the app's own
/// gestures behave exactly as they would without it.
private final class TouchWatcher: UIGestureRecognizer, UIGestureRecognizerDelegate {
    private static let diameter = 44.0
    private let canvas: UIView
    private var circles: [ObjectIdentifier: UIView] = [:]

    init(drawingIn canvas: UIView) {
        self.canvas = canvas
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        delegate = self
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        for touch in touches {
            let circle = UIView(frame: CGRect(x: 0, y: 0, width: Self.diameter, height: Self.diameter))
            circle.layer.cornerRadius = Self.diameter / 2
            circle.backgroundColor = UIColor.white.withAlphaComponent(0.55)
            circle.layer.borderColor = UIColor.black.withAlphaComponent(0.25).cgColor
            circle.layer.borderWidth = 1.5
            circle.center = touch.location(in: nil)
            circle.transform = CGAffineTransform(scaleX: 0.6, y: 0.6)
            canvas.addSubview(circle)
            circles[ObjectIdentifier(touch)] = circle
            UIView.animate(withDuration: 0.12) { circle.transform = .identity }
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        for touch in touches {
            circles[ObjectIdentifier(touch)]?.center = touch.location(in: nil)
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        lift(touches)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        lift(touches)
    }

    private func lift(_ touches: Set<UITouch>) {
        for touch in touches {
            guard let circle = circles.removeValue(forKey: ObjectIdentifier(touch)) else { continue }
            UIView.animate(withDuration: 0.25, animations: {
                circle.alpha = 0
                circle.transform = CGAffineTransform(scaleX: 1.4, y: 1.4)
            }, completion: { _ in circle.removeFromSuperview() })
        }
        if circles.isEmpty { state = .failed }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }
}
#endif
