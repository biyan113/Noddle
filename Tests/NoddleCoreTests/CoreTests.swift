import Foundation
import Testing
@testable import NoddleCore

@Suite struct PoseTrackerTests {
    private func sample(_ t: Double, yaw: Double, gyro: Double? = nil) -> MotionSample {
        MotionSample(t: t, yaw: Angle.radians(yaw), pitch: 0, roll: 0, gyro: gyro)
    }

    @Test func unwrapsAcrossPlusMinus180() {
        var tracker = PoseTracker()
        _ = tracker.push(sample(0, yaw: 178))
        let p = tracker.push(sample(0.04, yaw: -178))
        #expect(abs((p?.pose.yaw ?? 0) - 4) < 0.001)
    }

    @Test func absorbsSpatialAudioRecentre() {
        var tracker = PoseTracker()
        _ = tracker.push(sample(0, yaw: 10, gyro: 2))
        let p = tracker.push(sample(0.04, yaw: 75, gyro: 2))
        #expect(p?.rebased == true)
        #expect(p?.pose.yaw == 0)
        #expect(p?.rate.yaw == 0)
    }

    @Test func keepsFastRealTurns() {
        var tracker = PoseTracker()
        _ = tracker.push(sample(0, yaw: 0, gyro: 300))
        let p = tracker.push(sample(0.04, yaw: 12, gyro: 300))
        #expect(p?.rebased == false)
        #expect(abs((p?.rate.yaw ?? 0) - 300) < 0.001)
    }

    @Test func gapNeverBecomesMotion() {
        var tracker = PoseTracker()
        _ = tracker.push(sample(0, yaw: 0))
        let p = tracker.push(sample(1, yaw: 40))
        #expect(p?.rebased == true)
        #expect(p?.rate == .zero)
    }

    @Test func recenterZeroesPose() {
        var tracker = PoseTracker()
        tracker.neutralTimeConstant = 0
        _ = tracker.push(sample(0, yaw: 0))
        _ = tracker.push(sample(0.04, yaw: 5))
        tracker.recenter()
        let p = tracker.push(sample(0.08, yaw: 5))
        #expect(p?.pose.yaw == 0)
    }

    @Test func neutralIsWhereTheHeadFirstSettles() {
        var tracker = PoseTracker()
        tracker.neutralTimeConstant = 0
        // Starts mid-turn, comes to rest 30° away from the first sample.
        var last: TrackedPose?
        for i in 0...60 {
            let t = Double(i) * 0.02
            last = tracker.push(sample(t, yaw: min(t * 60, 30)))
        }
        #expect(abs(last?.pose.yaw ?? 9) < 0.01)
        // After that, real movement still reads as movement.
        let moved = tracker.push(sample(1.24, yaw: 40, gyro: 400))
        #expect(abs((moved?.pose.yaw ?? 0) - 10) < 0.01)
    }

    @Test func manualRecenterIsNotOverriddenBySettling() {
        var tracker = PoseTracker()
        tracker.neutralTimeConstant = 0
        _ = tracker.push(sample(0, yaw: 0))
        _ = tracker.push(sample(0.02, yaw: 3))
        tracker.recenter()
        _ = tracker.push(sample(0.1, yaw: 8, gyro: 100))
        var last: TrackedPose?
        for i in 0...40 { last = tracker.push(sample(0.12 + Double(i) * 0.02, yaw: 8)) }
        #expect(abs((last?.pose.yaw ?? 0) - 5) < 0.01)
    }

    @Test func neutralFollowsARestingHead() {
        var tracker = PoseTracker()
        tracker.neutralTimeConstant = 2
        _ = tracker.push(sample(0, yaw: 0))
        _ = tracker.push(sample(0.04, yaw: 5))
        var last: TrackedPose?
        for i in 2...500 { last = tracker.push(sample(Double(i) * 0.04, yaw: 5)) }
        #expect(abs(last?.pose.yaw ?? 9) < 0.1)
    }
}

@Suite struct PointerTests {
    @Test func headLeftMovesPointerLeftAndUpMovesUp() {
        var engine = PointerEngine()
        engine.update(TrackedPose(t: 0, pose: .zero, rate: HeadPose(yaw: 40, pitch: 40)))
        engine.update(TrackedPose(t: 0.04, pose: .zero, rate: HeadPose(yaw: 40, pitch: 40)))
        let d = engine.step(now: 0.05, dt: 1 / 60)
        #expect(d.x < 0)
        #expect(d.y < 0)
    }

    @Test func deadzoneHoldsStill() {
        var engine = PointerEngine()
        engine.update(TrackedPose(t: 0, pose: .zero, rate: HeadPose(yaw: 2, pitch: -2)))
        #expect(engine.step(now: 0.01, dt: 1 / 60) == .zero)
    }

    @Test func stopsByItselfWhenSamplesStop() {
        var engine = PointerEngine()
        engine.update(TrackedPose(t: 0, pose: .zero, rate: HeadPose(yaw: 80)))
        var now = 0.0
        for _ in 0..<120 { now += 1 / 60; _ = engine.step(now: now, dt: 1 / 60) }
        #expect(engine.step(now: now + 1 / 60, dt: 1 / 60) == .zero)
    }

    @Test func historyFindsThePastPosition() {
        var history = PointerHistory()
        history.record(Vec2(1, 1), at: 0)
        history.record(Vec2(9, 9), at: 1)
        #expect(history.position(at: 0.5) == Vec2(1, 1))
    }

    @Test func dwellFiresOnceUntilMovedAway() {
        var settings = DwellSettings()
        settings.enabled = true
        var dwell = DwellDetector(settings: settings)
        var fired = 0
        for i in 0...300 {
            if dwell.update(position: .zero, at: Double(i) * 0.01).fired { fired += 1 }
        }
        #expect(fired == 1)
        _ = dwell.update(position: Vec2(100, 0), at: 3.1)
        for i in 0...150 {
            if dwell.update(position: Vec2(100, 0), at: 3.2 + Double(i) * 0.01).fired { fired += 1 }
        }
        #expect(fired == 2)
    }

    @Test func scrollWaitsForTheDeadzone() {
        var engine = ScrollEngine()
        engine.update(TrackedPose(t: 0, pose: .zero, rate: .zero))
        engine.update(TrackedPose(t: 0.04, pose: HeadPose(pitch: 3), rate: .zero))
        #expect(engine.step(now: 0.05, dt: 0.016) == .zero)
        engine.update(TrackedPose(t: 0.08, pose: HeadPose(pitch: 15), rate: .zero))
        #expect(engine.step(now: 0.09, dt: 0.016).y > 0)
    }
}

@Suite struct GateTests {
    @Test func startsOff() {
        #expect(!ControlGate().allowsInput(at: 0))
    }

    @Test func realInputYields() {
        var gate = ControlGate()
        gate.setEnabled(true)
        #expect(gate.allowsInput(at: 1))
        gate.yield(until: 2)
        #expect(!gate.allowsInput(at: 1.5))
        #expect(gate.isLive)
        #expect(gate.allowsInput(at: 2.1))
    }

    @Test func everySuspensionBlocks() {
        var gate = ControlGate()
        gate.setEnabled(true)
        gate.suspend(.noHeadphones)
        gate.suspend(.noMotionData)
        gate.resume(.noHeadphones)
        #expect(!gate.allowsInput(at: 1))
        gate.resume(.noMotionData)
        #expect(gate.allowsInput(at: 1))
    }
}

@Suite struct GestureTests {
    let all = Set(GestureID.headBuiltins)

    private func nod(depth: Double = 16, at start: Double = 0.3, length: Double = 0.45) -> (Double) -> HeadPose {
        { HeadPose(pitch: -depth * bump($0, from: start, to: start + length)) }
    }

    @Test func detectsNod() {
        #expect(detect(stream(duration: 1.5, nod()), enabled: [.nod]) == [.nod])
    }

    @Test func nodReportsWhenItBegan() {
        var detector = BuiltinGestureDetector()
        let events = stream(duration: 1.5, nod()).flatMap { detector.process($0, enabled: [.nod]) }
        #expect(abs((events.first?.startTime ?? 9) - 0.3) < 0.15)
    }

    @Test func ignoresTinyNods() {
        #expect(detect(stream(duration: 1.5, nod(depth: 5)), enabled: [.nod]).isEmpty)
    }

    @Test func slowLookDownAndBackIsNotANod() {
        #expect(detect(stream(duration: 4, nod(depth: 20, at: 0.3, length: 3)), enabled: [.nod]).isEmpty)
    }

    @Test func diagonalMovementIsNotANod() {
        let poses = stream(duration: 1.5) { t in
            let b = bump(t, from: 0.3, to: 0.75)
            return HeadPose(yaw: 30 * b, pitch: -16 * b)
        }
        #expect(detect(poses, enabled: [.nod]).isEmpty)
    }

    @Test func doubleNodWinsOverNod() {
        let poses = stream(duration: 2.5) { t in
            HeadPose(pitch: -16 * (bump(t, from: 0.3, to: 0.7) + bump(t, from: 0.8, to: 1.2)))
        }
        #expect(detect(poses, enabled: [.nod, .doubleNod]) == [.doubleNod])
    }

    @Test func singleNodStillFiresWhenDoubleIsEnabled() {
        #expect(detect(stream(duration: 2, nod()), enabled: [.nod, .doubleNod]) == [.nod])
    }

    @Test func chinFlickIsNotANod() {
        let poses = stream(duration: 1.5) { HeadPose(pitch: 16 * bump($0, from: 0.3, to: 0.75)) }
        #expect(detect(poses, enabled: [.nod, .flickUp]) == [.flickUp])
    }

    @Test func detectsShake() {
        let poses = stream(duration: 2.2) { t in
            guard t > 0.3, t < 1.5 else { return .zero }
            return HeadPose(yaw: 15 * sin((t - 0.3) / 1.2 * 2 * .pi * 2.5))
        }
        #expect(detect(poses, enabled: [.shake]) == [.shake])
    }

    @Test func glancingAroundIsNotAShake() {
        let poses = stream(duration: 4) { t in HeadPose(yaw: 25 * sin(t * 2 * .pi * 0.3)) }
        #expect(detect(poses, enabled: [.shake]).isEmpty)
    }

    private func tilt(_ sign: Double, until end: Double) -> (Double) -> HeadPose {
        { t in HeadPose(roll: sign * 20 * smoothstep(0.2, 0.4, t) * (1 - smoothstep(end, end + 0.2, t))) }
    }

    @Test func detectsTiltsByDirection() {
        #expect(detect(stream(duration: 2, tilt(-1, until: 1)), enabled: [.tiltLeft, .tiltRight]) == [.tiltLeft])
        #expect(detect(stream(duration: 2, tilt(1, until: 1)), enabled: [.tiltLeft, .tiltRight]) == [.tiltRight])
    }

    @Test func swapTiltFlipsDirection() {
        var s = GestureSettings()
        s.swapTilt = true
        #expect(detect(stream(duration: 2, tilt(-1, until: 1)), enabled: [.tiltLeft, .tiltRight], settings: s) == [.tiltRight])
    }

    @Test func holdVariantSeparatesShortFromLong() {
        let both: Set<GestureID> = [.tiltLeft, .tiltLeftHold]
        #expect(detect(stream(duration: 2, tilt(-1, until: 0.65)), enabled: both) == [.tiltLeft])
        #expect(detect(stream(duration: 3, tilt(-1, until: 1.8)), enabled: both) == [.tiltLeftHold])
    }

    @Test func tiltFiresOncePerTilt() {
        #expect(detect(stream(duration: 5, tilt(-1, until: 4)), enabled: [.tiltLeft]) == [.tiltLeft])
    }

    @Test func disabledGesturesStaySilent() {
        #expect(detect(stream(duration: 1.5, nod()), enabled: [.shake]).isEmpty)
    }

    @Test func stillHeadFiresNothing() {
        #expect(detect(stream(duration: 5) { _ in .zero }, enabled: all).isEmpty)
    }

    @Test func noisyReadingPostureFiresNothing() {
        // Small natural sway, the case that matters for "no accidental clicks".
        let poses = stream(duration: 30) { t in
            HeadPose(yaw: 3 * sin(t * 1.3), pitch: 2.5 * sin(t * 0.9 + 1), roll: 2 * sin(t * 0.7))
        }
        #expect(detect(poses, enabled: all).isEmpty)
    }

    @Test func rebasedSampleResetsDetectors() {
        var poses = stream(duration: 1.5, nod())
        poses[12].rebased = true
        #expect(detect(poses, enabled: [.nod]).isEmpty)
    }
}

@Suite struct TemplateTests {
    /// A figure-eight-ish custom gesture: turn right, tilt, come back.
    private func signature(scale: Double = 1, speed: Double = 1, wobble: Double = 0) -> (Double) -> HeadPose {
        { t in
            let u = t * speed
            guard u > 0.2, u < 1.2 else { return .zero }
            let phase = (u - 0.2) / 1.0
            return HeadPose(
                yaw: scale * 22 * sin(phase * .pi) + wobble * sin(u * 9),
                pitch: scale * 10 * sin(phase * 2 * .pi),
                roll: scale * 16 * sin(phase * .pi)
            )
        }
    }

    private func take(_ f: @escaping (Double) -> HeadPose, duration: Double = 2.2) -> MotionSegment? {
        var segmenter = MotionSegmenter()
        return stream(duration: duration, f).compactMap { segmenter.push($0) }.first
    }

    private func template() throws -> GestureTemplate {
        let takes = try [signature(), signature(scale: 1.1, wobble: 1), signature(scale: 0.92, speed: 1.1, wobble: 0.7)]
            .map { try #require(take($0)) }
        return try #require(GestureTemplate(takes: takes))
    }

    @Test func segmenterFindsOneMovement() throws {
        let segment = try #require(take(signature()))
        #expect(segment.frames.count == MotionSegmenter.frameCount)
        #expect(segment.amplitude > 15)
        #expect(segment.duration > 0.6 && segment.duration < 1.4)
    }

    @Test func matchesTheSameMovementAgain() throws {
        let t = try template()
        let attempt = try #require(take(signature(scale: 1.05, speed: 0.92, wobble: 0.5), duration: 2.6))
        #expect(t.compare(attempt) <= t.effectiveThreshold)
    }

    @Test func rejectsADifferentMovement() throws {
        let t = try template()
        let other = try #require(take { u in
            guard u > 0.2, u < 1.2 else { return .zero }
            let phase = (u - 0.2) / 1.0
            return HeadPose(yaw: -22 * sin(phase * .pi), pitch: -14 * sin(phase * .pi), roll: 0)
        })
        #expect(t.compare(other) > t.effectiveThreshold)
    }

    @Test func rejectsTakesThatDisagree() throws {
        let a = try #require(take(signature()))
        let b = try #require(take { t in HeadPose(yaw: -30 * bump(t, from: 0.2, to: 1.2), roll: -25 * bump(t, from: 0.2, to: 1.2)) })
        let c = try #require(take { t in HeadPose(pitch: 30 * bump(t, from: 0.2, to: 1.2)) })
        #expect(GestureTemplate(takes: [a, b, c]) == nil)
    }

    @Test func engineFiresRecordedGestureAndSkipsStockDetector() throws {
        let id = GestureID("custom.test")
        let t = try template()
        var engine = GestureEngine()
        let events = stream(duration: 2.2, signature(scale: 1.02, wobble: 0.4))
            .flatMap { engine.process($0, enabled: [id], templates: [id: t]) }
        #expect(events.map(\.gesture) == [id])
    }

    @Test func recordingANodReplacesTheStockNod() throws {
        let t = try template()
        var engine = GestureEngine()
        let nod = stream(duration: 1.5) { HeadPose(pitch: -16 * bump($0, from: 0.3, to: 0.75)) }
        let events = nod.flatMap { engine.process($0, enabled: [.nod], templates: [.nod: t]) }
        #expect(events.isEmpty)
    }

    @Test func recorderCollectsThreeTakes() {
        var recorder = GestureRecorder()
        for _ in 0..<4 {
            for p in stream(duration: 2.2, signature()) { _ = recorder.push(p) }
        }
        #expect(recorder.takes.count == 3)
        #expect(recorder.isComplete)
        #expect(recorder.makeTemplate() != nil)
    }

    @Test func oneWaySweepIsFlaggedAsPointing() throws {
        let f: (Double) -> HeadPose = { HeadPose(yaw: 30 * smoothstep(0.2, 0.8, $0)) }
        let takes = try (0..<3).map { _ in try #require(take(f)) }
        #expect(try #require(GestureTemplate(takes: takes)).looksLikePointing)
        #expect(try !template().looksLikePointing)
    }

    @Test func identicalTemplatesAreConfusable() throws {
        let t = try template()
        #expect(t.isConfusable(with: t))
    }

    @Test func demoReplayEndsAtRest() throws {
        let segment = try #require(take(signature()))
        let p = GestureDemo.pose(of: segment, elapsed: segment.duration + 0.85)
        #expect(p.peak < 1)
    }
}

@Suite struct ConfigTests {
    @Test func roundTripsThroughJSON() throws {
        var config = Config()
        config.bind(.nod, to: .key(.enter), mode: Mode.pointerID)
        config.bind(.shake, to: .runShortcut("Focus"), mode: Mode.mediaID)
        config.apps = [AppProfile(bundleID: "com.apple.Safari", name: "Safari",
                                  overrides: [Mode.pointerID: ["nod": .rightClick]])]
        let back = try ConfigStore.decode(ConfigStore.encode(config))
        #expect(back == config)
    }

    @Test func appOverrideBeatsMode() {
        var config = Config()
        config.apps = [AppProfile(bundleID: "a", name: "A", overrides: [Mode.pointerID: ["nod": .rightClick]])]
        #expect(config.action(for: .nod, mode: Mode.pointerID, app: "a") == .rightClick)
        #expect(config.action(for: .nod, mode: Mode.pointerID, app: "b") == .none)
    }

    @Test func pointerModeNeverListensForTurns() {
        var config = Config()
        config.bind(.turnLeft, to: .leftClick, mode: Mode.pointerID)
        #expect(!config.enabledGestures(mode: Mode.pointerID, app: nil).contains(.turnLeft))
    }

    @Test func everyDefaultModeCanBeLeftWithoutTheKeyboard() {
        let config = Config()
        for mode in config.modes {
            let exits = mode.bindings.values.contains { action in
                switch action {
                case .pauseResume, .setMode: true
                default: false
                }
            }
            #expect(exits, "\(mode.id)")
        }
    }

    @Test func removingAGestureRemovesItsBindings() throws {
        var config = Config()
        let takes = [MotionSegment(startTime: 0, duration: 1, frames: [.zero, HeadPose(yaw: 20)]),
                     MotionSegment(startTime: 0, duration: 1, frames: [.zero, HeadPose(yaw: 21)])]
        let gesture = CustomGesture(name: "x", template: try #require(GestureTemplate(takes: takes)))
        config.customGestures = [gesture]
        config.bind(gesture.id, to: .leftClick, mode: Mode.pointerID)
        config.removeCustomGesture(gesture.id)
        #expect(config.mode(Mode.pointerID)?.bindings[gesture.id.rawValue] == nil)
        #expect(config.customGestures.isEmpty)
    }

    @Test func unreadableFileIsKeptAndDefaultsLoad() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config.json")
        try Data("not json".utf8).write(to: url)
        #expect(ConfigStore(url: url).load() == Config())
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("config.broken.json").path))
    }
}

@Suite struct BudTapTests {
    private func run(_ jolts: [Int: Double], count: Int = 60, speed: Double = 2, wantsDouble: Bool = false,
                     background: Double = 0) -> [GestureID] {
        var detector = BudTapDetector()
        var out: [GestureID] = []
        for i in 0..<count {
            // Alternating sign makes `background` a steady sample-to-sample shake.
            let shake = background / 2 * (i.isMultiple(of: 2) ? 1 : -1)
            let a = Vec3(0, 0, jolts[i] ?? shake)
            out += detector.process(t: Double(i) * 0.02, acceleration: a, headSpeed: speed, wantsDouble: wantsDouble).map(\.gesture)
        }
        return out
    }

    @Test func tapOnAStillHeadFires() { #expect(run([60: 1], count: 90) == [.budTap]) }

    @Test func theSensorJumpAsAStreamStartsIsNotATap() { #expect(run([1: 0.48, 2: 0]).isEmpty) }

    @Test func theSameAppliesAfterAGap() {
        var detector = BudTapDetector()
        var out: [GestureEvent] = []
        for i in 0..<80 { out += detector.process(t: Double(i) * 0.02, acceleration: .zero, headSpeed: 0, wantsDouble: false) }
        out += detector.process(t: 5, acceleration: .zero, headSpeed: 0, wantsDouble: false)
        out += detector.process(t: 5.02, acceleration: Vec3(0, 0, 1), headSpeed: 0, wantsDouble: false)
        #expect(out.isEmpty)
    }
    @Test func aStillHeadFiresNothing() { #expect(run([:]).isEmpty) }
    @Test func gentleBumpIsIgnored() { #expect(run([60: 0.1], count: 90).isEmpty) }
    @Test func joltWhileTurningIsNotATap() { #expect(run([60: 1], count: 90, speed: 120).isEmpty) }

    @Test func steadyShakingLikeWalkingIsNotATap() {
        #expect(run([:], count: 400, background: 0.3).isEmpty)
        #expect(run([380: 0.5], count: 400, background: 0.3).isEmpty)
    }

    @Test func aStrongTapStillGetsThroughLightShaking() {
        #expect(run([380: 1], count: 400, background: 0.05) == [.budTap])
    }

    @Test func doubleTapWinsWhenWanted() {
        #expect(run([60: 1, 75: 1], count: 110, wantsDouble: true) == [.budDoubleTap])
    }

    @Test func singleTapIsReleasedWhenNoSecondFollows() {
        #expect(run([60: 1], count: 110, wantsDouble: true) == [.budTap])
    }

    @Test func oneTapRingingAcrossSamplesCountsOnce() {
        #expect(run([60: 1, 61: 0, 62: 0.8], count: 90) == [.budTap])
    }

    @Test func valuesSeenOnRealAirPods() {
        #expect(run([60: 0.40], count: 90) == [.budTap])
        #expect(run([60: 0.35], count: 90).isEmpty)
    }

    @Test func oneTapNeverCountsTwice() {
        #expect(run([60: 0.6, 70: 0.41], count: 90) == [.budTap]) // 0.2 s apart
    }

    @Test func clickPointIsBeforeTheTap() {
        var detector = BudTapDetector()
        for i in 0..<70 { _ = detector.process(t: Double(i) * 0.02, acceleration: .zero, headSpeed: 0, wantsDouble: false) }
        let events = detector.process(t: 1.4, acceleration: Vec3(1, 0, 0), headSpeed: 0, wantsDouble: false)
        #expect((events.first?.startTime ?? 9) < 1.4)
    }
}

@Suite struct MigrationTests {
    private func json(_ config: Config) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: ConfigStore.encode(config)) as! [String: Any]
    }

    /// A file written by the build that had the (since removed) handheld mode.
    @Test func fileFromTheHandheldBuildKeepsEverythingElse() throws {
        var saved = Config()
        saved.pointer.speed = 2.2
        saved.bind(.nod, to: .key(.enter), mode: Mode.pointerID)
        var root = try json(saved)
        var modes = root["modes"] as! [[String: Any]]
        modes.append(["id": "hand", "name": "Handheld", "motion": "hand", "bindings": [String: Any]()])
        root["modes"] = modes
        root["activeMode"] = "hand"
        root["hand"] = ["tapStrength": 0.5]
        let config = try ConfigStore.decode(JSONSerialization.data(withJSONObject: root))
        #expect(config.pointer.speed == 2.2)
        #expect(config.action(for: .nod, mode: Mode.pointerID, app: nil) == .key(.enter))
        #expect(config.modes.map(\.id) == [Mode.pointerID, Mode.scrollID, Mode.presentID, Mode.mediaID])
        #expect(config.activeMode == Mode.pointerID)
    }

    private func versionOne(nod: Action?) throws -> Config {
        var old = Config()
        old.bind(.nod, to: nod ?? .none, mode: Mode.pointerID)
        var root = try json(old)
        root["version"] = 1
        root["stemLookback"] = nil
        return try ConfigStore.decode(JSONSerialization.data(withJSONObject: root))
    }

    @Test func tapIsAddedToAnExistingConfig() throws {
        var old = Config()
        old.bind(.budTap, to: .none, mode: Mode.pointerID)
        old.bind(.shake, to: .key(.enter), mode: Mode.pointerID)
        var root = try json(old)
        root["version"] = 2
        let config = try ConfigStore.decode(JSONSerialization.data(withJSONObject: root))
        #expect(config.action(for: .budTap, mode: Mode.pointerID, app: nil) == .leftClick)
        #expect(config.action(for: .shake, mode: Mode.pointerID, app: nil) == .key(.enter))
    }

    @Test func oldDefaultStrengthIsRetunedButAChosenOneIsKept() throws {
        var root = try json(Config())
        root["version"] = 3
        root["tapStrength"] = 0.35
        #expect(try ConfigStore.decode(JSONSerialization.data(withJSONObject: root)).tapStrength == 0.38)
        root["tapStrength"] = 0.5
        #expect(try ConfigStore.decode(JSONSerialization.data(withJSONObject: root)).tapStrength == 0.5)
    }

    @Test func removingTheTapStaysRemovedOnceUpgraded() throws {
        var config = Config()
        config.bind(.budTap, to: .none, mode: Mode.pointerID)
        let back = try ConfigStore.decode(ConfigStore.encode(config))
        #expect(back.action(for: .budTap, mode: Mode.pointerID, app: nil) == .none)
    }

    @Test func clickMovesFromNodToStem() throws {
        let config = try versionOne(nod: .leftClick)
        #expect(config.action(for: .nod, mode: Mode.pointerID, app: nil) == .none)
        #expect(config.action(for: .stemSingle, mode: Mode.pointerID, app: nil) == .leftClick)
        #expect(config.stemLookback == 0.3)
    }

    @Test func aNodTheUserRemappedIsLeftAlone() throws {
        #expect(try versionOne(nod: .key(.enter)).action(for: .nod, mode: Mode.pointerID, app: nil) == .key(.enter))
    }

    @Test func aNodBoundAfterUpgradingStaysBound() throws {
        var config = Config()
        config.bind(.nod, to: .leftClick, mode: Mode.pointerID)
        let back = try ConfigStore.decode(ConfigStore.encode(config))
        #expect(back.action(for: .nod, mode: Mode.pointerID, app: nil) == .leftClick)
    }

    @Test func nodNoLongerClicksByDefaultButOtherModesKeepIt() {
        let config = Config()
        #expect(config.action(for: .nod, mode: Mode.pointerID, app: nil) == .none)
        #expect(config.action(for: .nod, mode: Mode.presentID, app: nil) == .key(.right))
    }

    @Test func missingKeysTakeDefaults() throws {
        let config = try ConfigStore.decode(Data(#"{"pointer":{"speed":1.5,"acceleration":0.7,"deadzone":3,"smoothing":0.5,"invertX":false,"invertY":false}}"#.utf8))
        #expect(config.pointer.speed == 1.5)
        #expect(config.modes.count == 4)
    }
}
