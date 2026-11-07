import Foundation

/// Scripted head movements that show what each gesture looks like.
public enum GestureDemo {
    private typealias Key = (t: Double, pose: HeadPose)

    private static func keys(for gesture: GestureID) -> (duration: Double, keys: [Key]) {
        func p(_ yaw: Double = 0, _ pitch: Double = 0, _ roll: Double = 0) -> HeadPose {
            HeadPose(yaw: yaw, pitch: pitch, roll: roll)
        }
        switch gesture {
        case .nod:
            return (1.8, [(0, p()), (0.22, p(0, -16)), (0.46, p()), (1, p())])
        case .doubleNod:
            return (2.2, [(0, p()), (0.16, p(0, -15)), (0.32, p()), (0.48, p(0, -15)), (0.64, p()), (1, p())])
        case .flickUp:
            return (1.8, [(0, p()), (0.2, p(0, 15)), (0.44, p()), (1, p())])
        case .shake:
            return (2.2, [(0, p()), (0.12, p(16)), (0.26, p(-16)), (0.4, p(14)), (0.54, p(-12)), (0.66, p()), (1, p())])
        case .tiltLeft:
            return (2.2, [(0, p()), (0.25, p(0, 0, -19)), (0.55, p(0, 0, -19)), (0.8, p()), (1, p())])
        case .tiltRight:
            return (2.2, [(0, p()), (0.25, p(0, 0, 19)), (0.55, p(0, 0, 19)), (0.8, p()), (1, p())])
        case .tiltLeftHold:
            return (3.0, [(0, p()), (0.18, p(0, 0, -19)), (0.72, p(0, 0, -20)), (0.88, p()), (1, p())])
        case .tiltRightHold:
            return (3.0, [(0, p()), (0.18, p(0, 0, 19)), (0.72, p(0, 0, 20)), (0.88, p()), (1, p())])
        case .turnLeft:
            return (2.4, [(0, p()), (0.25, p(32)), (0.6, p(32)), (0.85, p()), (1, p())])
        case .turnRight:
            return (2.4, [(0, p()), (0.25, p(-32)), (0.6, p(-32)), (0.85, p()), (1, p())])
        case .lookUp:
            return (2.4, [(0, p()), (0.25, p(0, 22)), (0.6, p(0, 22)), (0.85, p()), (1, p())])
        case .lookDown:
            return (2.4, [(0, p()), (0.25, p(0, -22)), (0.6, p(0, -22)), (0.85, p()), (1, p())])
        default:
            return (1.6, [(0, p()), (1, p())])
        }
    }

    public static func duration(of gesture: GestureID) -> Double { keys(for: gesture).duration }

    /// Pose at `elapsed` seconds, looping.
    public static func pose(of gesture: GestureID, elapsed: Double) -> HeadPose {
        let (duration, keys) = keys(for: gesture)
        let t = elapsed.truncatingRemainder(dividingBy: duration) / duration
        for (a, b) in zip(keys, keys.dropFirst()) where t <= b.t {
            let local = (t - a.t) / max(b.t - a.t, 0.0001)
            return a.pose.mixed(with: b.pose, smoothstep(0, 1, local))
        }
        return keys.last?.pose ?? .zero
    }

    /// Replays a recorded take at its real speed, then rests.
    public static func pose(of segment: MotionSegment, elapsed: Double) -> HeadPose {
        let rest = 0.9
        let t = elapsed.truncatingRemainder(dividingBy: segment.duration + rest)
        guard t < segment.duration, segment.frames.count > 1 else {
            // Glide home so the loop has no visible jump.
            let back = (t - segment.duration) / rest
            return (segment.frames.last ?? .zero).mixed(with: .zero, smoothstep(0, 0.6, back))
        }
        let position = t / segment.duration * Double(segment.frames.count - 1)
        let i = Int(position)
        let next = min(i + 1, segment.frames.count - 1)
        return segment.frames[i].mixed(with: segment.frames[next], position - Double(i))
    }
}
