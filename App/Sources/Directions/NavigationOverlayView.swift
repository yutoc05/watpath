import CampusGeo
import Routing
import UIKit

/// What navigation draws over either map: the dotted route, the goose, and the progress
/// bar. It sits above both maps, so it looks the same on each and MapKit's 3D buildings
/// can't dim it, and it never takes touches, so a drag anywhere reaches the map below.
final class NavigationOverlayView: UIView {
    private static let dotSize = 6.5
    private static let gooseSize = CGSize(width: 58, height: 56)
    /// One more dot is skipped for each time the camera is this many meters farther out.
    private static let metersPerDotSkipped = 130.0

    private let upcoming = CAShapeLayer()
    private let passed = CAShapeLayer()
    private let walker = UIImageView(image: UIImage(named: "Goose"))
    private let flag = UIImageView(image: UIImage(systemName: "flag.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 30, weight: .semibold)))
    private let progressBar = NavigationProgressBar()
    private var dots: [(distance: Double, point: SIMD2<Double>)] = []
    private var end = SIMD2<Double>.zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isHidden = true
        for (layer, color) in [(passed, PathMapView.alternativeRouteColor), (upcoming, PathMapView.routeColor)] {
            layer.strokeColor = color.cgColor
            layer.fillColor = nil
            layer.lineWidth = Self.dotSize
            layer.lineCap = .round
            self.layer.addSublayer(layer)
        }
        flag.tintColor = .systemGreen
        // The foot of the flag's pole marks the spot.
        flag.layer.anchorPoint = CGPoint(x: 0.1, y: 0.95)
        addSubview(flag)
        walker.bounds.size = Self.gooseSize
        walker.contentMode = .scaleAspectFit
        // It stands on the route: the spot is between its feet, not in its middle.
        walker.layer.anchorPoint = CGPoint(x: 0.43, y: 0.89)
        addSubview(walker)

        progressBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(progressBar)
        NSLayoutConstraint.activate([
            progressBar.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 8),
            progressBar.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 16),
            progressBar.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -16),
            progressBar.heightAnchor.constraint(equalToConstant: 44),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(track: RouteTrack, dotSpacing: Double) {
        dots = track.dots(every: dotSpacing)
        end = track.point(at: track.length)
        isHidden = false
    }

    func hide() {
        isHidden = true
        dots = []
    }

    /// Redraws for the current camera. Each dot is projected from its place on the
    /// ground, so the dots stay put as the camera moves. A dash pattern is measured along
    /// the line on screen, which would send them sliding along it.
    func update(projector: PinholeProjector, pose: NavigationRig.Pose) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        let ahead = CGMutablePath(), behind = CGMutablePath()
        let visible = bounds.insetBy(dx: -Self.dotSize, dy: -Self.dotSize)
        for index in stride(from: 0, to: dots.count, by: max(1, Int(pose.cameraDistance / Self.metersPerDotSkipped))) {
            let dot = dots[index]
            guard let screen = projector.project(SIMD3(dot.point.x, dot.point.y, 0)) else { continue }
            let point = CGPoint(x: screen.x, y: screen.y)
            guard visible.contains(point) else { continue }
            // A line of no length with round caps is a dot, and strokes faster than ellipses.
            let path = dot.distance < pose.distance ? behind : ahead
            path.move(to: point)
            path.addLine(to: point)
        }
        upcoming.path = ahead
        passed.path = behind

        if let screen = projector.project(SIMD3(pose.walker.x, pose.walker.y, 0)) {
            walker.isHidden = false
            walker.layer.position = CGPoint(x: screen.x, y: screen.y)
        } else {
            walker.isHidden = true
        }
        if let screen = projector.project(SIMD3(end.x, end.y, 0)) {
            flag.isHidden = false
            flag.layer.position = CGPoint(x: screen.x, y: screen.y)
        } else {
            flag.isHidden = true
        }
        progressBar.progress = pose.progress
    }
}

/// A goose moving along a track toward a green flag.
private final class NavigationProgressBar: UIView {
    private static let inset = 20.0
    /// The figure stops this far short of the flag, rather than standing on it.
    private static let flagClearance = 34.0
    private static let gooseSize = CGSize(width: 33, height: 32)

    private let background = UIVisualEffectView(effect: UIGlassEffect())
    private let track = CALayer()
    private let fill = CALayer()
    private let flag = UIImageView(image: UIImage(systemName: "flag.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)))
    private let figure = UIImageView(image: UIImage(named: "Goose"))
    private var shownPercent = -1

    var progress = 0.0 {
        didSet { setNeedsLayout() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        background.layer.cornerRadius = 22
        background.clipsToBounds = true
        addSubview(background)
        track.backgroundColor = UIColor.systemGray3.cgColor
        track.cornerRadius = 2
        fill.backgroundColor = PathMapView.routeColor.cgColor
        fill.cornerRadius = 2
        layer.addSublayer(track)
        layer.addSublayer(fill)
        flag.tintColor = .systemGreen
        figure.bounds.size = Self.gooseSize
        figure.contentMode = .scaleAspectFit
        addSubview(flag)
        addSubview(figure)
        isAccessibilityElement = true
        accessibilityIdentifier = "navigationProgress"
        accessibilityLabel = "Progress along the route"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        background.frame = bounds
        let start = Self.inset, end = bounds.width - Self.inset, last = end - Self.flagClearance
        let at = start + (last - start) * min(max(progress, 0), 1)
        track.frame = CGRect(x: start, y: bounds.midY - 2, width: end - start, height: 4)
        fill.frame = CGRect(x: start, y: bounds.midY - 2, width: at - start, height: 4)
        flag.center = CGPoint(x: end, y: bounds.midY - 2)
        figure.center = CGPoint(x: at, y: bounds.midY - 2)

        let percent = Int((progress * 100).rounded())
        if percent != shownPercent {
            shownPercent = percent
            accessibilityValue = "\(percent)%"
        }
    }
}
