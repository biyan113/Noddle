import Foundation

/// A finished movement: from when the head started moving until it settled.
public struct MotionSegment: Codable, Equatable, Sendable {
    public var startTime: Double
    public var duration: Double
    /// Fixed-length path relative to where the movement began.
    public var frames: [HeadPose]

    public init(startTime: Double, duration: Double, frames: [HeadPose]) {
        self.startTime = startTime
        self.duration = duration
        self.frames = frames
    }

    /// Largest excursion on any axis, degrees.
    public var amplitude: Double { frames.map(\.peak).max() ?? 0 }
}

/// Cuts a continuous pose stream into discrete movements. Recording and matching both go
/// through here, so a live gesture is measured exactly the way its template was.
public struct MotionSegmenter: Sendable {
    public static let frameCount = 24
    public static let startSpeed = 28.0
    public static let endSpeed = 14.0
    public static let settleTime = 0.2
    public static let minDuration = 0.15
    public static let maxDuration = 3.5
    public static let minAmplitude = 6.0

    private var preroll: [TrackedPose] = []
    private var active: [TrackedPose] = []
    private var quietSince: Double?

    public init() {}

    public var isMoving: Bool { !active.isEmpty }

    public mutating func reset() {
        preroll = []
        active = []
        quietSince = nil
    }

    public mutating func push(_ p: TrackedPose) -> MotionSegment? {
        if p.rebased { reset(); return nil }
        let speed = p.rate.peak
        if active.isEmpty {
            preroll.append(p)
            if preroll.count > 3 { preroll.removeFirst() }
            if speed >= Self.startSpeed {
                active = preroll
                preroll = []
                quietSince = nil
            }
            return nil
        }
        active.append(p)
        if p.t - active[0].t > Self.maxDuration {
            reset()
            return nil
        }
        if speed >= Self.endSpeed { quietSince = nil; return nil }
        let since = quietSince ?? p.t
        quietSince = since
        guard p.t - since >= Self.settleTime else { return nil }

        let moving = active.filter { $0.t <= since }
        let result = Self.segment(from: moving)
        reset()
        return result
    }

    static func segment(from poses: [TrackedPose]) -> MotionSegment? {
        guard poses.count >= 3, let first = poses.first, let last = poses.last else { return nil }
        let duration = last.t - first.t
        guard duration >= minDuration else { return nil }
        let frames = (0..<frameCount).map { i -> HeadPose in
            let target = first.t + duration * Double(i) / Double(frameCount - 1)
            let upper = poses.firstIndex { $0.t >= target } ?? poses.count - 1
            let lower = max(upper - 1, 0)
            let a = poses[lower]
            let b = poses[upper]
            let t = b.t > a.t ? (target - a.t) / (b.t - a.t) : 0
            return a.pose.mixed(with: b.pose, clamp(t, 0, 1)) - first.pose
        }
        let segment = MotionSegment(startTime: first.t, duration: duration, frames: frames)
        return segment.amplitude >= minAmplitude ? segment : nil
    }
}

public struct TemplateMatch: Equatable, Sendable {
    public var gesture: GestureID
    public var distance: Double
    public var threshold: Double

    public init(gesture: GestureID, distance: Double, threshold: Double) {
        self.gesture = gesture
        self.distance = distance
        self.threshold = threshold
    }

    public var accepted: Bool { distance <= threshold }
    /// 1 = perfect, 0 = at the acceptance limit or beyond.
    public var confidence: Double { clamp(1 - distance / max(threshold, 0.001), 0, 1) }
}

/// A gesture learned from the user's own movement.
public struct GestureTemplate: Codable, Equatable, Sendable {
    public var takes: [MotionSegment]
    /// The most representative take.
    public var reference: MotionSegment
    public var threshold: Double
    /// User bias: <1 stricter, >1 more forgiving.
    public var tolerance: Double = 1

    public static let requiredTakes = 3

    /// Builds a template from several takes, or returns nil if they disagree too much.
    public init?(takes: [MotionSegment]) {
        guard takes.count >= 2 else { return nil }
        var best = 0
        var bestTotal = Double.infinity
        var worst = 0.0
        for (i, a) in takes.enumerated() {
            var total = 0.0
            for (j, b) in takes.enumerated() where i != j {
                let d = Self.distance(a, b)
                total += d
                worst = max(worst, d)
            }
            if total < bestTotal { bestTotal = total; best = i }
        }
        self.takes = takes
        reference = takes[best]
        // The takes define how much this person naturally varies.
        threshold = clamp(worst * 1.6 + 2.5, 4, 16)
        guard worst <= reference.amplitude * 0.9 + 3 else { return nil }
    }

    public var effectiveThreshold: Double { threshold * tolerance }

    /// Dynamic time warping over a fixed-length path, after matching the movement's size, so
    /// a smaller or slower version of the same shape still counts.
    public static func distance(_ a: MotionSegment, _ b: MotionSegment) -> Double {
        let scale = a.amplitude > 0 && b.amplitude > 0 ? clamp(a.amplitude / b.amplitude, 0.6, 1.6) : 1
        let x = a.frames
        let y = b.frames.map { $0 * scale }
        guard !x.isEmpty, !y.isEmpty else { return .infinity }
        let n = x.count, m = y.count
        let band = max(6, abs(n - m))
        var previous = [Double](repeating: .infinity, count: m + 1)
        previous[0] = 0
        for i in 1...n {
            var row = [Double](repeating: .infinity, count: m + 1)
            let low = max(1, i - band), high = min(m, i + band)
            if low <= high {
                for j in low...high {
                    let d = x[i - 1] - y[j - 1]
                    let cost = (d.yaw * d.yaw + d.pitch * d.pitch + d.roll * d.roll).squareRoot()
                    row[j] = cost + min(previous[j], previous[j - 1], row[j - 1])
                }
            }
            previous = row
        }
        return previous[m] / Double(n + m) * 2
    }

    public func compare(_ segment: MotionSegment) -> Double {
        let ratio = segment.duration / max(reference.duration, 0.01)
        guard (0.45...2.2).contains(ratio) else { return .infinity }
        let size = segment.amplitude / max(reference.amplitude, 0.01)
        guard (0.55...1.9).contains(size) else { return .infinity }
        return Self.distance(reference, segment)
    }

    public static func bestMatch(for segment: MotionSegment,
                                 among templates: [GestureID: GestureTemplate]) -> TemplateMatch? {
        var best: TemplateMatch?
        for (id, template) in templates {
            let d = template.compare(segment)
            guard d.isFinite else { continue }
            if best == nil || d / template.effectiveThreshold < best!.distance / best!.threshold {
                best = TemplateMatch(gesture: id, distance: d, threshold: template.effectiveThreshold)
            }
        }
        return best
    }

    /// True for a plain one-way sweep of yaw/pitch, which pointing produces all the time.
    public var looksLikePointing: Bool {
        let f = reference.frames
        guard let end = f.last else { return false }
        let rollSpan = (f.map(\.roll).max() ?? 0) - (f.map(\.roll).min() ?? 0)
        let travel = (end.yaw * end.yaw + end.pitch * end.pitch).squareRoot()
        return rollSpan < 8 && travel > reference.amplitude * 0.7
    }

    /// True when two templates are close enough to be confused.
    public func isConfusable(with other: GestureTemplate) -> Bool {
        Self.distance(reference, other.reference) <= max(effectiveThreshold, other.effectiveThreshold)
    }
}

/// Collects takes during recording.
public struct GestureRecorder: Sendable {
    public private(set) var takes: [MotionSegment] = []
    private var segmenter = MotionSegmenter()

    public init() {}

    public var isMoving: Bool { segmenter.isMoving }
    public var isComplete: Bool { takes.count >= GestureTemplate.requiredTakes }

    /// Returns the take just captured, if this sample finished one.
    public mutating func push(_ p: TrackedPose) -> MotionSegment? {
        guard !isComplete, let segment = segmenter.push(p) else { return nil }
        takes.append(segment)
        return segment
    }

    public mutating func discardLast() { if !takes.isEmpty { takes.removeLast() } }
    public mutating func restart() { takes = []; segmenter.reset() }
    public func makeTemplate() -> GestureTemplate? { GestureTemplate(takes: takes) }
}
