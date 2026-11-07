import Foundation

/// An angle easing toward a target with a critically damped spring: as fast as it can
/// go without overshooting, so the camera swings into a corner and settles. It's the
/// spring's exact solution, not a numerical step, so it's stable at any frame rate.
public struct HeadingSpring: Sendable, Equatable {
    /// Radians clockwise from north.
    public private(set) var angle: Double
    /// Radians per second.
    public private(set) var rate = 0.0
    private let stiffness: Double

    /// `stiffness` is the spring's natural frequency, in radians per second.
    public init(angle: Double, stiffness: Double) {
        self.angle = Self.wrapped(angle)
        self.stiffness = stiffness
    }

    public mutating func advance(toward target: Double, seconds: Double) {
        // Always the short way around: 350° to 10° is 20°, not 340°.
        let offset = Self.wrapped(angle - target)
        let drift = rate + stiffness * offset
        let decay = exp(-stiffness * seconds)
        let moved = (offset + drift * seconds) * decay
        rate = (drift - stiffness * (offset + drift * seconds)) * decay
        angle = Self.wrapped(target + moved)
    }

    /// Into -π...π.
    static func wrapped(_ angle: Double) -> Double {
        let turned = fmod(angle + .pi, 2 * .pi)
        return (turned < 0 ? turned + 2 * .pi : turned) - .pi
    }
}
