import Foundation

public enum Suspension: String, Codable, Sendable, CaseIterable {
    case noHeadphones
    case noMotionData
    case noAccessibility
    case screenLocked
    case appExcluded

    public var label: String {
        switch self {
        case .noHeadphones: L("未连接耳机", "Headphones not connected")
        case .noMotionData: L("运动数据中断", "Motion data stopped")
        case .noAccessibility: L("缺少辅助功能权限", "Accessibility permission missing")
        case .screenLocked: L("屏幕已锁定", "Screen locked")
        case .appExcluded: L("当前应用已排除", "Excluded in this app")
        }
    }
}

/// The single place that decides whether Noddle may touch the mouse or keyboard.
/// It starts disabled: head movement does nothing until the user turns control on.
public struct ControlGate: Equatable, Sendable {
    public private(set) var enabled = false
    public private(set) var suspensions: Set<Suspension> = []
    public private(set) var yieldedUntil = -Double.infinity

    public init() {}

    public mutating func setEnabled(_ on: Bool) { enabled = on }

    public mutating func suspend(_ reason: Suspension) { suspensions.insert(reason) }
    public mutating func resume(_ reason: Suspension) { suspensions.remove(reason) }

    /// The user touched a real mouse, trackpad or keyboard.
    public mutating func yield(until t: Double) { yieldedUntil = max(yieldedUntil, t) }

    public func isYielding(at t: Double) -> Bool { t < yieldedUntil }

    public func allowsInput(at t: Double) -> Bool {
        enabled && suspensions.isEmpty && !isYielding(at: t)
    }

    /// Controls that must keep working while yielding (pause, recenter) only need this.
    public var isLive: Bool { enabled && suspensions.isEmpty }
}
