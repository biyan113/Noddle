import Foundation

/// A 3-D reading from the earbud's accelerometer, in g.
public struct Vec3: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var z: Double

    public init(_ x: Double, _ y: Double, _ z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }

    public static let zero = Vec3(0, 0, 0)
    public var length: Double { (x * x + y * y + z * z).squareRoot() }
    public static func - (a: Vec3, b: Vec3) -> Vec3 { Vec3(a.x - b.x, a.y - b.y, a.z - b.z) }
}

/// Finds a finger tapping the earbud's shell.
///
/// A tap is a sharp jump in acceleration while the head is nearly still. Walking and chewing
/// also shake the earbud, but they do it constantly, so a tap must stand clear of recent noise.
public struct BudTapDetector: Sendable {
    /// Head speed (deg/s) above which a jolt is movement rather than a tap.
    static let maxHeadSpeed = 45.0
    static let lookback = 0.14
    static let lookbackSkip = 0.03
    /// Long enough that one tap ringing on never counts twice.
    static let cooldown = 0.25
    static let doubleGap = 0.35
    /// A tap must be this many times the recent background shake.
    static let clearOfNoise = 4.0
    /// The sensor jumps as a stream starts. Measured at 0.48 g on real AirPods: a phantom click.
    static let warmUp = 1.0

    /// Jump in acceleration between two samples, in g, that counts as a tap.
    public var strength: Double
    /// Latest jump, and the head speed just before it. For the meter and the log.
    public private(set) var lastJolt = 0.0
    public private(set) var lastHeadSpeed = 0.0

    private var previous: (t: Double, acceleration: Vec3)?
    private var speeds: [(t: Double, speed: Double)] = []
    private var noise = 0.0
    private var quietUntil = -Double.infinity
    private var pending: GestureEvent?

    public init(strength: Double = 0.38) { self.strength = strength }

    public mutating func reset() {
        previous = nil
        speeds = []
        pending = nil
    }

    /// `wantsDouble` holds a single tap back briefly, to see whether a second one follows.
    public mutating func process(t: Double, acceleration: Vec3, headSpeed: Double, wantsDouble: Bool) -> [GestureEvent] {
        var events: [GestureEvent] = []
        if let held = pending, t - held.time > Self.doubleGap {
            pending = nil
            events.append(held)
        }

        var jolt = 0.0
        if let previous, t - previous.t <= PoseTracker.maxGap {
            jolt = (acceleration - previous.acceleration).length
        } else {
            quietUntil = max(quietUntil, t + Self.warmUp) // A new stream, or one back from a gap.
        }
        previous = (t, acceleration)
        lastJolt = jolt
        speeds.append((t, headSpeed))
        speeds.removeAll { t - $0.t > Self.lookback }

        // The tap's own kick is in the newest samples, so judge the head just before them.
        let before = speeds.filter { t - $0.t >= Self.lookbackSkip }.map(\.speed)
        lastHeadSpeed = before.isEmpty ? headSpeed : before.reduce(0, +) / Double(before.count)

        let isTap = jolt > strength && jolt > noise * Self.clearOfNoise
            && lastHeadSpeed < Self.maxHeadSpeed && t >= quietUntil
        // Learned after the check, and slowly, so a tap barely raises the bar for the next one.
        noise += (min(jolt, strength) - noise) * 0.02
        guard isTap else { return events }

        quietUntil = t + Self.cooldown
        let tap = GestureEvent(gesture: .budTap, startTime: t - Self.lookback, time: t, magnitude: jolt)
        if let first = pending {
            pending = nil
            events.append(GestureEvent(gesture: .budDoubleTap, startTime: first.startTime, time: t, magnitude: jolt))
        } else if wantsDouble {
            pending = tap
        } else {
            events.append(tap)
        }
        return events
    }
}
