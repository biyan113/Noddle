import Foundation

/// One raw reading from the headphones, exactly as CoreMotion reports it.
public struct MotionSample: Codable, Equatable, Sendable {
    public var t: Double
    /// Radians. +yaw = head turns left, +pitch = looks up, +roll = tilts right.
    public var yaw: Double
    public var pitch: Double
    public var roll: Double
    /// Gyro magnitude in deg/s, when known. Used to tell real motion from a re-centred reference.
    public var gyro: Double?
    /// Acceleration in g with gravity removed. Taps on the earbud show up here.
    public var acceleration: Vec3?

    public init(t: Double, yaw: Double, pitch: Double, roll: Double, gyro: Double? = nil, acceleration: Vec3? = nil) {
        self.t = t
        self.yaw = yaw
        self.pitch = pitch
        self.roll = roll
        self.gyro = gyro
        self.acceleration = acceleration
    }
}

/// A head orientation or angular rate, in degrees (or deg/s).
public struct HeadPose: Codable, Equatable, Sendable {
    public var yaw: Double
    public var pitch: Double
    public var roll: Double

    public init(yaw: Double = 0, pitch: Double = 0, roll: Double = 0) {
        self.yaw = yaw
        self.pitch = pitch
        self.roll = roll
    }

    public static let zero = HeadPose()
    public var peak: Double { max(abs(yaw), abs(pitch), abs(roll)) }

    public static func + (a: HeadPose, b: HeadPose) -> HeadPose {
        HeadPose(yaw: a.yaw + b.yaw, pitch: a.pitch + b.pitch, roll: a.roll + b.roll)
    }
    public static func - (a: HeadPose, b: HeadPose) -> HeadPose {
        HeadPose(yaw: a.yaw - b.yaw, pitch: a.pitch - b.pitch, roll: a.roll - b.roll)
    }
    public static func * (a: HeadPose, s: Double) -> HeadPose {
        HeadPose(yaw: a.yaw * s, pitch: a.pitch * s, roll: a.roll * s)
    }
    public func mixed(with other: HeadPose, _ t: Double) -> HeadPose { self + (other - self) * t }
}

/// A sample after tracking: continuous, relative to the user's neutral pose.
public struct TrackedPose: Equatable, Sendable {
    public var t: Double
    public var pose: HeadPose
    public var rate: HeadPose
    /// True when this sample absorbed a gap or a reference jump instead of real motion.
    public var rebased: Bool

    public init(t: Double, pose: HeadPose, rate: HeadPose, rebased: Bool = false) {
        self.t = t
        self.pose = pose
        self.rate = rate
        self.rebased = rebased
    }
}

/// Turns raw attitude into a continuous pose relative to neutral.
///
/// CoreMotion's reference frame is not stable: yaw re-centres when Spatial Audio starts, and
/// Bluetooth gaps skip samples. Noddle integrates *plausible* deltas only, so neither
/// event can ever reach the cursor as a jump.
public struct PoseTracker: Sendable {
    /// Longest gap treated as continuous motion.
    public static let maxGap = 0.25
    /// Neutral follows a resting head with this time constant, so posture shifts and drift
    /// never turn into a false tilt. Zero disables it.
    public var neutralTimeConstant: Double = 40

    private var last: MotionSample?
    private var continuous = HeadPose.zero
    private var neutral = HeadPose.zero
    /// Neutral is taken from the first time the head settles, not the first sample: that one
    /// may arrive mid-movement, and every pose after it would look crooked.
    private var hasSettled = false
    private var stillSince: Double?
    static let settleTime = 0.4

    public init() {}

    public mutating func reset() {
        last = nil
        continuous = .zero
        neutral = .zero
        hasSettled = false
        stillSince = nil
    }

    /// Makes the current orientation the new neutral.
    public mutating func recenter() {
        neutral = continuous
        hasSettled = true
    }

    public mutating func push(_ sample: MotionSample) -> TrackedPose? {
        guard let previous = last else {
            last = sample
            return TrackedPose(t: sample.t, pose: continuous - neutral, rate: .zero, rebased: true)
        }
        let dt = sample.t - previous.t
        guard dt > 0.001 else { return nil }
        last = sample

        let raw = HeadPose(
            yaw: Angle.delta(Angle.degrees(sample.yaw), Angle.degrees(previous.yaw)),
            pitch: Angle.delta(Angle.degrees(sample.pitch), Angle.degrees(previous.pitch)),
            roll: Angle.delta(Angle.degrees(sample.roll), Angle.degrees(previous.roll))
        )

        guard dt <= Self.maxGap else {
            return TrackedPose(t: sample.t, pose: continuous - neutral, rate: .zero, rebased: true)
        }

        // The most the head could really have turned in dt.
        let plausible = (sample.gyro ?? 450) * dt * 1.8 + 6
        var delta = raw
        var rebased = false
        if abs(delta.yaw) > plausible { delta.yaw = 0; rebased = true }
        if abs(delta.pitch) > plausible { delta.pitch = 0; rebased = true }
        if abs(delta.roll) > plausible { delta.roll = 0; rebased = true }

        continuous = continuous + delta
        let rate = delta * (1 / dt)

        if !hasSettled {
            if rate.peak < 6 {
                let since = stillSince ?? sample.t
                stillSince = since
                if sample.t - since >= Self.settleTime { recenter() }
            } else {
                stillSince = nil
            }
        }

        if neutralTimeConstant > 0, rate.peak < 8 {
            let offset = continuous - neutral
            if offset.peak < 20 {
                neutral = neutral + offset * min(dt / neutralTimeConstant, 1)
            }
        }
        return TrackedPose(t: sample.t, pose: continuous - neutral, rate: rate, rebased: rebased)
    }
}
