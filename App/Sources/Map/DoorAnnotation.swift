import CampusModel
import MapKit

final class DoorAnnotation: NSObject, MKAnnotation {
    let door: Door
    let coordinate: CLLocationCoordinate2D

    init(door: Door) {
        self.door = door
        coordinate = door.coordinate.clCoordinate
    }

    var title: String? { door.name }
}

/// A door marker styled like an Apple Maps point of interest. Its name shows only
/// while selected, so dozens of doors don't fill the map with labels.
final class DoorMarkerView: MKMarkerAnnotationView {
    static let reuseIdentifier = "door"

    override var annotation: (any MKAnnotation)? {
        didSet { configure() }
    }

    override init(annotation: (any MKAnnotation)?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        glyphImage = UIImage(systemName: "door.left.hand.open")
        displayPriority = .defaultHigh
        collisionMode = .circle
        titleVisibility = .hidden
        subtitleVisibility = .hidden
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func setSelected(_ selected: Bool, animated: Bool) {
        super.setSelected(selected, animated: animated)
        titleVisibility = selected ? .visible : .hidden
    }

    private func configure() {
        guard let door = (annotation as? DoorAnnotation)?.door else { return }
        // Exit-only and stairwell doors are grey: you can leave through them, not enter.
        markerTintColor = switch door.kind {
        case .main, .entrance: .systemTeal
        case .exit, .stairwell: .systemGray
        }
        accessibilityLabel = door.name
    }
}
