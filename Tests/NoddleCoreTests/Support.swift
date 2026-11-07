import Foundation
@testable import NoddleCore

/// Synthesises a tracked stream at the ~25 Hz headphones actually report.
func stream(duration: Double, hz: Double = 25, start: Double = 0, _ pose: (Double) -> HeadPose) -> [TrackedPose] {
    var out: [TrackedPose] = []
    var previous = pose(0)
    let dt = 1 / hz
    var t = 0.0
    while t <= duration {
        let current = pose(t)
        out.append(TrackedPose(t: start + t, pose: current, rate: (current - previous) * (1 / dt)))
        previous = current
        t += dt
    }
    return out
}

func bump(_ t: Double, from a: Double, to b: Double) -> Double {
    guard t > a, t < b else { return 0 }
    return (1 - cos((t - a) / (b - a) * 2 * .pi)) / 2
}

func detect(_ poses: [TrackedPose], enabled: Set<GestureID>,
            settings: GestureSettings = GestureSettings()) -> [GestureID] {
    var detector = BuiltinGestureDetector(settings: settings)
    return poses.flatMap { detector.process($0, enabled: enabled) }.map(\.gesture)
}
