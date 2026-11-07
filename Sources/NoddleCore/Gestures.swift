import Foundation

/// Identifies a gesture. Built-ins are the static constants; recorded ones are `custom.<uuid>`.
public struct GestureID: RawRepresentable, Hashable, Codable, Sendable {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ raw: String) { rawValue = raw }

    public static let nod = GestureID("nod")
    public static let doubleNod = GestureID("doubleNod")
    public static let flickUp = GestureID("flickUp")
    public static let shake = GestureID("shake")
    public static let tiltLeft = GestureID("tiltLeft")
    public static let tiltRight = GestureID("tiltRight")
    public static let tiltLeftHold = GestureID("tiltLeftHold")
    public static let tiltRightHold = GestureID("tiltRightHold")
    public static let turnLeft = GestureID("turnLeft")
    public static let turnRight = GestureID("turnRight")
    public static let lookUp = GestureID("lookUp")
    public static let lookDown = GestureID("lookDown")
    public static let stemSingle = GestureID("stemSingle")
    public static let stemDouble = GestureID("stemDouble")
    public static let stemTriple = GestureID("stemTriple")
    public static let budTap = GestureID("budTap")
    public static let budDoubleTap = GestureID("budDoubleTap")

    public static let headBuiltins: [GestureID] = [
        .nod, .doubleNod, .flickUp, .shake, .tiltLeft, .tiltRight, .tiltLeftHold, .tiltRightHold,
        .turnLeft, .turnRight, .lookUp, .lookDown,
    ]
    public static let stems: [GestureID] = [.stemSingle, .stemDouble, .stemTriple]
    public static let taps: [GestureID] = [.budTap, .budDoubleTap]

    public var isStem: Bool { Self.stems.contains(self) }
    public var isTap: Bool { Self.taps.contains(self) }
    public var isCustom: Bool { rawValue.hasPrefix("custom.") }

    /// Turns and held looks collide with steering the pointer, so they only exist in other modes.
    public var conflictsWithPointer: Bool {
        [.turnLeft, .turnRight, .lookUp, .lookDown].contains(self)
    }

    public var builtinName: String? {
        switch self {
        case .nod: L("点头", "Nod")
        case .doubleNod: L("连续点头两次", "Double nod")
        case .flickUp: L("快速抬头", "Chin flick")
        case .shake: L("摇头", "Shake")
        case .tiltLeft: L("向左歪头", "Tilt left")
        case .tiltRight: L("向右歪头", "Tilt right")
        case .tiltLeftHold: L("向左歪头并停住", "Tilt left and hold")
        case .tiltRightHold: L("向右歪头并停住", "Tilt right and hold")
        case .turnLeft: L("向左转头", "Turn left")
        case .turnRight: L("向右转头", "Turn right")
        case .lookUp: L("抬头并停住", "Look up and hold")
        case .lookDown: L("低头并停住", "Look down and hold")
        case .stemSingle: L("轻点一下耳机柄", "Press stem once")
        case .stemDouble: L("轻点两下耳机柄", "Press stem twice")
        case .stemTriple: L("轻点三下耳机柄", "Press stem three times")
        case .budTap: L("轻敲耳机外壳", "Tap the earbud")
        case .budDoubleTap: L("连敲两下耳机外壳", "Double-tap the earbud")
        default: nil
        }
    }
}

public struct GestureEvent: Equatable, Sendable {
    public var gesture: GestureID
    /// When the movement began; clicks land where the pointer was at this moment.
    public var startTime: Double
    public var time: Double
    public var magnitude: Double

    public init(gesture: GestureID, startTime: Double, time: Double, magnitude: Double = 0) {
        self.gesture = gesture
        self.startTime = startTime
        self.time = time
        self.magnitude = magnitude
    }
}

public struct GestureSettings: Codable, Equatable, Sendable {
    /// Minimum nod depth, degrees.
    public var nodDepth = 9.0
    /// Longest a nod may take, seconds.
    public var nodWindow = 0.8
    /// Gap allowed between the two nods of a double nod.
    public var doubleNodGap = 0.45
    public var shakeSwing = 8.0
    public var tiltAngle = 14.0
    public var tiltDwell = 0.16
    public var holdTime = 0.85
    public var turnAngle = 24.0
    public var lookAngle = 16.0
    public var zoneDwell = 0.3
    /// Quiet time after any gesture.
    public var cooldown = 0.35
    /// For headphones that report roll the other way round.
    public var swapTilt = false
    public init() {}
}

/// A dip-and-return on the pitch axis. `direction` -1 = nod (down first), +1 = chin flick.
struct FlickDetector: Sendable {
    let direction: Double
    private var start: (t: Double, pitch: Double)?
    private var extreme = 0.0
    private var yawLow = 0.0
    private var yawHigh = 0.0
    private var peakRate = 0.0
    private var previous: (t: Double, pitch: Double)?

    init(direction: Double) { self.direction = direction }

    mutating func reset() { start = nil; previous = nil }

    var inProgress: Bool { start != nil }

    mutating func update(_ p: TrackedPose, depth: Double, window: Double) -> (start: Double, depth: Double)? {
        defer { previous = (p.t, p.pose.pitch) }
        let travel = p.rate.pitch * direction
        guard let begin = start else {
            if travel > 30 {
                let origin = previous ?? (p.t, p.pose.pitch)
                start = origin
                extreme = 0
                yawLow = p.pose.yaw
                yawHigh = p.pose.yaw
                peakRate = travel
            }
            return nil
        }
        guard p.t - begin.t <= window else { start = nil; return nil }

        let displacement = (p.pose.pitch - begin.pitch) * direction
        extreme = max(extreme, displacement)
        peakRate = max(peakRate, travel)
        yawLow = min(yawLow, p.pose.yaw)
        yawHigh = max(yawHigh, p.pose.yaw)

        guard extreme >= depth, displacement <= extreme * 0.45 else { return nil }
        let result = (begin.t, extreme)
        let cleanAxis = yawHigh - yawLow <= max(extreme * 0.7, 4)
        start = nil
        return cleanAxis && peakRate >= 40 ? result : nil
    }
}

/// Side-to-side swings. Needs four: three happens naturally when glancing around.
struct ShakeDetector: Sendable {
    static let requiredSwings = 4
    private var pivot: Double?
    private var extreme = 0.0
    private var heading = 0.0
    private var reversals: [Double] = []
    private var startedAt = 0.0

    mutating func reset() {
        pivot = nil
        heading = 0
        reversals = []
    }

    /// Returns when the shake began, once it is complete.
    mutating func update(_ p: TrackedPose, swing: Double) -> Double? {
        let yaw = p.pose.yaw
        guard let origin = pivot else { pivot = yaw; return nil }

        if let last = reversals.last, p.t - last > 0.55 {
            reversals = []
            heading = 0
            pivot = yaw
            return nil
        }
        if heading == 0 {
            if abs(yaw - origin) >= swing * 0.5 {
                heading = yaw > origin ? 1 : -1
                extreme = yaw
                startedAt = p.t
            } else if p.rate.yaw == 0 {
                pivot = yaw
            }
            return nil
        }
        if (yaw - extreme) * heading > 0 { extreme = yaw; return nil }
        guard (extreme - yaw) * heading >= swing * 0.4 else { return nil }

        // A turning point: the swing that just ended only counts if it was big enough.
        if abs(extreme - origin) >= swing {
            reversals.append(p.t)
        } else {
            reversals = []
            startedAt = p.t
        }
        pivot = extreme
        heading = -heading
        extreme = yaw

        guard reversals.count >= Self.requiredSwings - 1, p.t - startedAt <= 1.6 else { return nil }
        let start = startedAt
        reset()
        return start
    }
}

/// Moving past an angle and staying there. Optional second stage: staying there *longer*.
struct ZoneDetector: Sendable {
    let short: GestureID
    let hold: GestureID?
    private var enteredAt: Double?
    private var latched = false

    init(short: GestureID, hold: GestureID? = nil) {
        self.short = short
        self.hold = hold
    }

    mutating func reset() { enteredAt = nil; latched = false }

    mutating func update(value: Double, t: Double, angle: Double, dwell: Double, holdTime: Double,
                         enabled: Set<GestureID>) -> (GestureID, Double)? {
        let release = angle * 0.45
        guard let since = enteredAt else {
            if value >= angle { enteredAt = t; latched = false }
            return nil
        }
        let elapsed = t - since
        if value < release {
            enteredAt = nil
            let wasLatched = latched
            latched = false
            // With a hold variant in play the short gesture waits for release, so we know which it was.
            if !wasLatched, let hold, enabled.contains(hold), enabled.contains(short), elapsed >= dwell {
                return (short, since)
            }
            return nil
        }
        guard !latched else { return nil }
        if let hold, enabled.contains(hold) {
            if elapsed >= holdTime { latched = true; return (hold, since) }
            return nil
        }
        if enabled.contains(short), elapsed >= dwell { latched = true; return (short, since) }
        return nil
    }
}

/// Recognises every built-in head gesture from a tracked pose stream.
public struct BuiltinGestureDetector: Sendable {
    public var settings: GestureSettings
    private var nod = FlickDetector(direction: -1)
    private var flick = FlickDetector(direction: 1)
    private var shake = ShakeDetector()
    private var tiltLeft = ZoneDetector(short: .tiltLeft, hold: .tiltLeftHold)
    private var tiltRight = ZoneDetector(short: .tiltRight, hold: .tiltRightHold)
    private var turnLeft = ZoneDetector(short: .turnLeft)
    private var turnRight = ZoneDetector(short: .turnRight)
    private var lookUp = ZoneDetector(short: .lookUp)
    private var lookDown = ZoneDetector(short: .lookDown)
    private var pendingNod: GestureEvent?
    private var cooldownUntil = -Double.infinity

    public init(settings: GestureSettings = GestureSettings()) { self.settings = settings }

    public mutating func reset() {
        nod.reset(); flick.reset(); shake.reset()
        tiltLeft.reset(); tiltRight.reset(); turnLeft.reset(); turnRight.reset()
        lookUp.reset(); lookDown.reset()
        pendingNod = nil
        cooldownUntil = -.infinity
    }

    public mutating func process(_ p: TrackedPose, enabled: Set<GestureID>) -> [GestureEvent] {
        var events: [GestureEvent] = []
        guard !p.rebased else { reset(); return [] }

        let s = settings
        let cooling = p.t < cooldownUntil
        let wantsNod = enabled.contains(.nod) || enabled.contains(.doubleNod)

        if let hit = nod.update(p, depth: s.nodDepth, window: s.nodWindow), wantsNod {
            let event = GestureEvent(gesture: .nod, startTime: hit.start, time: p.t, magnitude: hit.depth)
            if let first = pendingNod {
                pendingNod = nil
                events.append(GestureEvent(gesture: .doubleNod, startTime: first.startTime, time: p.t, magnitude: hit.depth))
            } else if !cooling {
                if enabled.contains(.doubleNod) {
                    pendingNod = event
                } else {
                    events.append(event)
                }
            }
        }
        // A nod held back to see whether a second follows: flushed once no second one has begun.
        if let pending = pendingNod, !nod.inProgress, p.t - pending.time > s.doubleNodGap {
            pendingNod = nil
            events.append(pending)
        }
        if let hit = flick.update(p, depth: s.nodDepth, window: s.nodWindow), enabled.contains(.flickUp), !cooling {
            events.append(GestureEvent(gesture: .flickUp, startTime: hit.start, time: p.t, magnitude: hit.depth))
        }
        if let start = shake.update(p, swing: s.shakeSwing), enabled.contains(.shake), !cooling {
            pendingNod = nil
            events.append(GestureEvent(gesture: .shake, startTime: start, time: p.t))
        }

        let roll = s.swapTilt ? -p.pose.roll : p.pose.roll
        func zone(_ detector: inout ZoneDetector, _ value: Double, _ angle: Double) {
            if let (gesture, since) = detector.update(value: value, t: p.t, angle: angle, dwell: gesture(for: angle),
                                                      holdTime: s.holdTime, enabled: enabled), !cooling {
                events.append(GestureEvent(gesture: gesture, startTime: since, time: p.t, magnitude: abs(value)))
            }
        }
        func gesture(for angle: Double) -> Double { angle == s.tiltAngle ? s.tiltDwell : s.zoneDwell }
        zone(&tiltLeft, -roll, s.tiltAngle)
        zone(&tiltRight, roll, s.tiltAngle)
        zone(&turnLeft, p.pose.yaw, s.turnAngle)
        zone(&turnRight, -p.pose.yaw, s.turnAngle)
        zone(&lookUp, p.pose.pitch, s.lookAngle)
        zone(&lookDown, -p.pose.pitch, s.lookAngle)

        if events.contains(where: { $0.gesture != .nod || !enabled.contains(.doubleNod) }) {
            cooldownUntil = p.t + s.cooldown
        }
        return events.filter { enabled.contains($0.gesture) }
    }
}

/// Built-in detectors plus recorded templates, behind one call.
public struct GestureEngine: Sendable {
    public var builtins: BuiltinGestureDetector
    private var segmenter = MotionSegmenter()
    /// Last comparison made, for the live tester and the debug page.
    public private(set) var lastMatch: TemplateMatch?

    public init(settings: GestureSettings = GestureSettings()) {
        builtins = BuiltinGestureDetector(settings: settings)
    }

    public mutating func reset() {
        builtins.reset()
        segmenter.reset()
    }

    public mutating func process(_ p: TrackedPose, enabled: Set<GestureID>,
                                 templates: [GestureID: GestureTemplate]) -> [GestureEvent] {
        var active = enabled
        // A recorded version replaces the stock detector for that gesture.
        for id in templates.keys { active.remove(id) }
        var events = builtins.process(p, enabled: active)

        if let segment = segmenter.push(p) {
            let candidates = templates.filter { enabled.contains($0.key) }
            if let match = GestureTemplate.bestMatch(for: segment, among: candidates) {
                lastMatch = match
                if match.accepted {
                    events.append(GestureEvent(gesture: match.gesture, startTime: segment.startTime,
                                               time: p.t, magnitude: match.distance))
                }
            }
        }
        return events
    }
}
