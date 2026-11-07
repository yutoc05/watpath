import Foundation

/// Where the walker is along a route, moved by a finger: dragged directly, or flicked
/// and left to slow down as a `UIScrollView` does. It never leaves the route.
public struct ScrubMotion: Sendable {
    /// Meters along the route.
    public private(set) var position = 0.0
    /// Meters per second, from a flick.
    public private(set) var velocity = 0.0
    public let length: Double
    private let tuning: NavigationTuning

    public init(length: Double, tuning: NavigationTuning = .standard) {
        self.length = length
        self.tuning = tuning
    }

    public var isAtEnd: Bool { position >= length }

    /// Moves by `meters`, and ends any flick: the finger is in charge now.
    public mutating func drag(by meters: Double) {
        velocity = 0
        moveTo(position + meters)
    }

    public mutating func flick(metersPerSecond speed: Double) {
        velocity = min(max(speed, -tuning.flickTopSpeed), tuning.flickTopSpeed)
        if abs(velocity) < tuning.flickStopSpeed { velocity = 0 }
    }

    /// A finger came down, which catches a flick the way it does in a scroll view.
    public mutating func hold() {
        velocity = 0
    }

    /// Advances a flick by `seconds`. Exact rather than stepped, so a dropped frame
    /// doesn't change how far it goes.
    public mutating func advance(seconds: Double) {
        guard velocity != 0 else { return }
        let decay = pow(tuning.flickDeceleration, seconds * 1_000)
        // The integral of v·r^(1000t) from 0 to `seconds`.
        moveTo(position + velocity * (1 - decay) / -(1_000 * log(tuning.flickDeceleration)))
        velocity *= decay
        if abs(velocity) < tuning.flickStopSpeed || position <= 0 || position >= length { velocity = 0 }
    }

    private mutating func moveTo(_ target: Double) {
        position = min(max(target, 0), length)
    }
}
