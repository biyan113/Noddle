import Foundation

/// A 2-D vector in screen points (CoreGraphics global space: +y is down).
public struct Vec2: Equatable, Sendable, Codable {
    public var x: Double
    public var y: Double
    public init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
    public static let zero = Vec2(0, 0)
    public var length: Double { (x * x + y * y).squareRoot() }
    public static func + (a: Vec2, b: Vec2) -> Vec2 { Vec2(a.x + b.x, a.y + b.y) }
    public static func - (a: Vec2, b: Vec2) -> Vec2 { Vec2(a.x - b.x, a.y - b.y) }
    public static func * (a: Vec2, s: Double) -> Vec2 { Vec2(a.x * s, a.y * s) }
}

public enum Angle {
    public static func degrees(_ radians: Double) -> Double { radians * 180 / .pi }
    public static func radians(_ degrees: Double) -> Double { degrees * .pi / 180 }

    /// Shortest signed difference `a - b`, in degrees, in (-180, 180].
    public static func delta(_ a: Double, _ b: Double) -> Double {
        var d = (a - b).truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 }
        if d <= -180 { d += 360 }
        return d
    }
}

public func clamp<T: Comparable>(_ value: T, _ low: T, _ high: T) -> T { min(max(value, low), high) }

public func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
    let t = clamp((x - edge0) / (edge1 - edge0), 0, 1)
    return t * t * (3 - 2 * t)
}

public func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }

/// Picks the UI language once; Noddle ships Chinese and English strings inline.
public let preferChinese: Bool = {
    let first = Locale.preferredLanguages.first ?? "en"
    return first.hasPrefix("zh")
}()

/// Inline localisation: `L("暂停", "Pause")`.
public func L(_ zh: String, _ en: String) -> String { preferChinese ? zh : en }

/// One Euro filter: little smoothing when slow (kills jitter), little lag when fast.
public struct OneEuroFilter: Sendable {
    public var minCutoff: Double
    public var beta: Double
    public var derivativeCutoff: Double
    private var lastValue: Double?
    private var lastDerivative = 0.0
    private var lastTime: Double?

    public init(minCutoff: Double = 1.5, beta: Double = 0.02, derivativeCutoff: Double = 1.0) {
        self.minCutoff = minCutoff
        self.beta = beta
        self.derivativeCutoff = derivativeCutoff
    }

    public mutating func reset() { lastValue = nil; lastTime = nil; lastDerivative = 0 }

    private static func alpha(cutoff: Double, dt: Double) -> Double {
        let tau = 1 / (2 * .pi * cutoff)
        return 1 / (1 + tau / dt)
    }

    public mutating func filter(_ value: Double, at time: Double) -> Double {
        guard let previous = lastValue, let previousTime = lastTime, time > previousTime else {
            lastValue = value
            lastTime = time
            return value
        }
        let dt = time - previousTime
        let derivative = (value - previous) / dt
        let a = Self.alpha(cutoff: derivativeCutoff, dt: dt)
        lastDerivative = a * derivative + (1 - a) * lastDerivative
        let cutoff = minCutoff + beta * abs(lastDerivative)
        let b = Self.alpha(cutoff: cutoff, dt: dt)
        let result = b * value + (1 - b) * previous
        lastValue = result
        lastTime = time
        return result
    }
}
