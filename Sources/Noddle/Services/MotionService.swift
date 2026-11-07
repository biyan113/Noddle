import CoreMotion
import Foundation
import NoddleCore

/// Anything that produces head samples: real headphones, or the built-in simulator.
@MainActor
protocol MotionSource: AnyObject {
    var onSample: ((MotionSample) -> Void)? { get set }
    var onConnection: ((Bool) -> Void)? { get set }
    func start()
    func stop()
}

/// Streams head attitude from AirPods through CoreMotion.
@MainActor
final class HeadphoneMotionSource: NSObject, MotionSource, CMHeadphoneMotionManagerDelegate {
    var onSample: ((MotionSample) -> Void)?
    var onConnection: ((Bool) -> Void)?
    private let manager = CMHeadphoneMotionManager()
    private var running = false

    override init() {
        super.init()
        manager.delegate = self
    }

    static var authorization: CMAuthorizationStatus { CMHeadphoneMotionManager.authorizationStatus() }

    func start() {
        guard !running else { return }
        running = true
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, error in
            MainActor.assumeIsolated {
                if let error { Log.write("motion error: \(error.localizedDescription)") }
                guard let self, let motion else { return }
                let a = motion.attitude
                let r = motion.rotationRate
                let gyro = Angle.degrees((r.x * r.x + r.y * r.y + r.z * r.z).squareRoot())
                let u = motion.userAcceleration
                self.onSample?(MotionSample(t: motion.timestamp, yaw: a.yaw, pitch: a.pitch, roll: a.roll, gyro: gyro,
                                            acceleration: Vec3(u.x, u.y, u.z)))
            }
        }
    }

    func stop() {
        guard running else { return }
        running = false
        manager.stopDeviceMotionUpdates()
    }

    /// A stream can stall after an audio route change; a clean restart recovers it.
    func restart() {
        stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.start() }
    }

    nonisolated func headphoneMotionManagerDidConnect(_ manager: CMHeadphoneMotionManager) {
        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.onConnection?(true) } }
    }

    nonisolated func headphoneMotionManagerDidDisconnect(_ manager: CMHeadphoneMotionManager) {
        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.onConnection?(false) } }
    }
}

/// Plays a scripted head so the app can be explored and screenshotted without headphones.
@MainActor
final class SimulatedMotionSource: MotionSource {
    var onSample: ((MotionSample) -> Void)?
    var onConnection: ((Bool) -> Void)?
    private var timer: Timer?
    private let script: [GestureID] = [.nod, .tiltLeft, .shake, .tiltRight, .doubleNod, .turnLeft]
    private let began = ProcessInfo.processInfo.systemUptime

    func start() {
        guard timer == nil else { return }
        onConnection?(true)
        timer = Timer.scheduledTimer(withTimeInterval: 1 / 25.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = now - began
        let slot = 4.0
        let gesture = script[Int(elapsed / slot) % script.count]
        let local = elapsed.truncatingRemainder(dividingBy: slot)
        let wander = HeadPose(yaw: 3 * sin(elapsed * 0.7), pitch: 1.5 * sin(elapsed * 0.5), roll: 1 * sin(elapsed * 0.4))
        let demo = local < GestureDemo.duration(of: gesture) ? GestureDemo.pose(of: gesture, elapsed: local) : .zero
        let pose = demo + wander
        onSample?(MotionSample(t: now, yaw: Angle.radians(pose.yaw), pitch: Angle.radians(pose.pitch),
                               roll: Angle.radians(pose.roll)))
    }
}
