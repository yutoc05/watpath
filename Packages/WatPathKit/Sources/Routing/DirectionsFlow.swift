/// Getting directions, one step at a time. Every step and every way between them is
/// here, as plain values, so the flow can be tested without a screen. An event that
/// makes no sense in the current step is ignored.
///
/// ```
/// idle → originPrompt → pickingOriginInPath ──────────────┐
///                     → searchingOrigin ──────────────────┤→ findingRoutes → routes | noRoutes
///                         → pickingOriginOnMap ───────────┘
/// routes → navigating ⇄ arrived
/// ```
public struct DirectionsFlow<Place: Hashable & Sendable>: Sendable, Equatable {
    public enum Step: Sendable, Equatable {
        case idle
        /// "I'm in the PATH" or "I'm Outside".
        case originPrompt
        /// A pin in the Path Map, dropped where you are.
        case pickingOriginInPath
        case searchingOrigin
        /// "Choose location on map", from the origin search.
        case pickingOriginOnMap
        case findingRoutes
        case routes([Route], selected: Route.ID)
        case noRoutes
        /// Scrubbing along a route.
        case navigating(Route)
        /// At the end of it. Scrubbing back is still allowed.
        case arrived(Route)
    }

    public enum Event: Sendable {
        case chooseDestination(Place)
        case chooseInPath
        case chooseOutside
        case chooseOriginOnMap
        case setOrigin(Place)
        /// Routes from `origin`, however long ago they were asked for.
        case found([Route], from: Place)
        case selectRoute(Route.ID)
        case startRoute(Route.ID)
        case reachedEnd
        case leftEnd
        /// One step back.
        case back
        /// All the way out.
        case cancel
    }

    public private(set) var step = Step.idle
    public private(set) var destination: Place?
    public private(set) var origin: Place?

    public init() {}

    public var isActive: Bool { step != .idle }

    /// The route on show, if any.
    public var selectedRoute: Route? {
        guard case .routes(let routes, let selected) = step else { return nil }
        return routes.first { $0.id == selected }
    }

    /// The route being walked, if any.
    public var activeRoute: Route? {
        switch step {
        case .navigating(let route), .arrived(let route): route
        default: nil
        }
    }

    public mutating func send(_ event: Event) {
        switch (step, event) {
        case (.idle, .chooseDestination(let place)):
            destination = place
            step = .originPrompt
        case (.originPrompt, .chooseInPath):
            step = .pickingOriginInPath
        case (.originPrompt, .chooseOutside):
            step = .searchingOrigin
        case (.searchingOrigin, .chooseOriginOnMap):
            step = .pickingOriginOnMap
        case (.pickingOriginInPath, .setOrigin(let place)), (.searchingOrigin, .setOrigin(let place)), (.pickingOriginOnMap, .setOrigin(let place)):
            origin = place
            step = .findingRoutes
        case (.findingRoutes, .found(let routes, let from)) where from == origin:
            step = routes.first.map { .routes(routes, selected: $0.id) } ?? .noRoutes
        case (.routes(let routes, _), .selectRoute(let id)) where routes.contains(where: { $0.id == id }):
            step = .routes(routes, selected: id)
        case (.routes(let routes, _), .startRoute(let id)):
            if let route = routes.first(where: { $0.id == id }) { step = .navigating(route) }
        case (.navigating(let route), .reachedEnd):
            step = .arrived(route)
        case (.arrived(let route), .leftEnd):
            step = .navigating(route)
        case (.idle, .back), (.idle, .cancel), (.navigating, .back), (.arrived, .back):
            break
        case (.originPrompt, .back), (_, .cancel):
            self = DirectionsFlow()
        case (.pickingOriginOnMap, .back):
            step = .searchingOrigin
        case (_, .back):
            origin = nil
            step = .originPrompt
        default:
            break
        }
    }
}
