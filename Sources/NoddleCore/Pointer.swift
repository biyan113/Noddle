import Foundation

public struct PointerSettings: Codable, Equatable, Sendable {
    /// Overall speed multiplier.
    public var speed: Double = 1.0
    /// 0 = linear; higher = slow head stays precise while a fast turn crosses the screen.
    public var acceleration: Double = 0.7
    /// Head speed (deg/s) below which the pointer does not move.
    public var deadzone: Double = 3.0
    /// 0 = raw, 1 = heavy.
    public var smoothing: Double = 0.55
    public var invertX = false
    public var invertY = false
    public init() {}
}

/// Head angular velocity → pointer velocity. Rate mapping needs no absolute reference, so
/// sensor drift cannot move the pointer, and the head can "ratchet" across big displays.
public struct PointerEngine: Sendable {
    public static let pointsPerDegree = 24.0
    /// With no fresh sample for this long the pointer stops by itself.
    public static let staleAfter = 0.14

    public var settings: PointerSettings
    private var yawFilter = OneEuroFilter(minCutoff: 2.5, beta: 0.03)
    private var pitchFilter = OneEuroFilter(minCutoff: 2.5, beta: 0.03)
    private var target = Vec2.zero
    private var targetTime = -Double.infinity
    private var velocity = Vec2.zero

    public init(settings: PointerSettings = PointerSettings()) { self.settings = settings }

    public mutating func reset() {
        yawFilter.reset()
        pitchFilter.reset()
        target = .zero
        velocity = .zero
        targetTime = -.infinity
    }

    public func axisSpeed(_ rate: Double) -> Double {
        let excess = abs(rate) - settings.deadzone
        guard excess > 0 else { return 0 }
        let boost = 1 + settings.acceleration * min(excess / 60, 3)
        let speed = excess * Self.pointsPerDegree * settings.speed * boost
        return rate < 0 ? -speed : speed
    }

    public mutating func update(_ tracked: TrackedPose) {
        guard !tracked.rebased else {
            target = .zero
            targetTime = tracked.t
            return
        }
        let yaw = yawFilter.filter(tracked.rate.yaw, at: tracked.t)
        let pitch = pitchFilter.filter(tracked.rate.pitch, at: tracked.t)
        var x = -axisSpeed(yaw)     // +yaw = head left = pointer left
        var y = -axisSpeed(pitch)   // +pitch = look up = pointer up (screen y grows down)
        if settings.invertX { x = -x }
        if settings.invertY { y = -y }
        target = Vec2(x, y)
        targetTime = tracked.t
    }

    /// Advances one display frame and returns the pointer displacement.
    public mutating func step(now: Double, dt: Double) -> Vec2 {
        guard dt > 0 else { return .zero }
        let goal = now - targetTime > Self.staleAfter ? Vec2.zero : target
        let retention = lerp(0.35, 0.9, clamp(settings.smoothing, 0, 1))
        let alpha = 1 - pow(retention, dt * 60)
        velocity = velocity + (goal - velocity) * alpha
        if velocity.length < 0.5, goal == .zero { velocity = .zero }
        return velocity * dt
    }
}

public struct ScrollSettings: Codable, Equatable, Sendable {
    /// Angle from the anchor (degrees) before scrolling starts.
    public var deadzone: Double = 5
    /// Points per second per degree beyond the dead zone.
    public var speed: Double = 28
    public var horizontal = false
    public var natural = true
    public init() {}
}

/// Scroll works like a joystick: hold your head away from where you entered the mode.
public struct ScrollEngine: Sendable {
    public var settings: ScrollSettings
    private var anchor: HeadPose?
    private var offset = HeadPose.zero
    private var offsetTime = -Double.infinity

    public init(settings: ScrollSettings = ScrollSettings()) { self.settings = settings }

    public mutating func reset() { anchor = nil; offset = .zero; offsetTime = -.infinity }

    public mutating func update(_ tracked: TrackedPose) {
        let a = anchor ?? tracked.pose
        anchor = a
        offset = tracked.pose - a
        offsetTime = tracked.t
    }

    private func axis(_ degrees: Double) -> Double {
        let excess = abs(degrees) - settings.deadzone
        guard excess > 0 else { return 0 }
        let speed = excess * settings.speed * (1 + min(excess / 12, 2))
        return degrees < 0 ? -speed : speed
    }

    /// Scroll delta for this frame; +y scrolls the content down (reveals what is above).
    public func step(now: Double, dt: Double) -> Vec2 {
        guard now - offsetTime <= PointerEngine.staleAfter else { return .zero }
        var y = axis(offset.pitch)
        if !settings.natural { y = -y }
        let x = settings.horizontal ? axis(offset.yaw) : 0
        return Vec2(x, y) * dt
    }
}

/// Remembers where the pointer was, so a nod can click where you pointed *before* nodding.
public struct PointerHistory: Sendable {
    private var entries: [(t: Double, position: Vec2)] = []
    public init() {}

    public mutating func record(_ position: Vec2, at t: Double) {
        entries.append((t, position))
        if let first = entries.first, t - first.t > 3 {
            entries.removeFirst(min(entries.count / 4 + 1, entries.count - 1))
        }
    }

    public func position(at t: Double) -> Vec2? {
        entries.last { $0.t <= t }?.position ?? entries.first?.position
    }

    public mutating func clear() { entries.removeAll() }
}

public struct DwellSettings: Codable, Equatable, Sendable {
    public var enabled = false
    public var duration = 1.0
    public var radius = 16.0
    public init() {}
}

/// Hover-to-click. Re-arms only after the pointer has really moved away.
public struct DwellDetector: Sendable {
    public var settings: DwellSettings
    private var anchor: Vec2?
    private var since = 0.0
    private var spent = false

    public init(settings: DwellSettings = DwellSettings()) { self.settings = settings }

    public mutating func reset() { anchor = nil; spent = false }

    /// Returns progress in 0...1 and whether the dwell just completed.
    public mutating func update(position: Vec2, at t: Double) -> (progress: Double, fired: Bool) {
        guard let a = anchor, (position - a).length <= settings.radius else {
            let farAway = anchor.map { (position - $0).length > settings.radius * 2 } ?? true
            if !spent || farAway {
                spent = false
                anchor = position
                since = t
            }
            return (0, false)
        }
        guard !spent else { return (0, false) }
        let progress = clamp((t - since) / settings.duration, 0, 1)
        if progress >= 1 {
            spent = true
            return (1, true)
        }
        // A short grace period, so ordinary pauses never show a ring.
        return (progress < 0.25 ? 0 : progress, false)
    }
}
