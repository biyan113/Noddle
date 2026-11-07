import AppKit
import NoddleCore
import QuartzCore

/// A tiny multicast: pages subscribe while they are on screen.
@MainActor
final class Bus<Value> {
    private var listeners: [UUID: (Value) -> Void] = [:]
    func listen(_ handler: @escaping (Value) -> Void) -> UUID {
        let id = UUID()
        listeners[id] = handler
        return id
    }
    func remove(_ id: UUID?) { if let id { listeners[id] = nil } }
    func send(_ value: Value) { for listener in listeners.values { listener(value) } }
    var isEmpty: Bool { listeners.isEmpty }
}

struct RecognisedGesture {
    var event: GestureEvent
    var action: Action
    var executed: Bool
}

/// Owns the pipeline: sensors → tracking → gestures/pointer → gate → injected events.
@MainActor
final class AppController {
    static let shared = AppController()

    let store = ConfigStore(url: ConfigStore.defaultURL)
    private(set) var config: Config
    private(set) var gate = ControlGate()

    let poses = Bus<TrackedPose>()
    let gestures = Bus<RecognisedGesture>()
    let changes = Bus<Void>()

    /// While the recording flow is open, gestures are seen but never executed.
    var isRecording = false { didSet { engine.reset() } }
    /// Settings window open: keep sensors running so the figure can follow the head.
    var isObserved = false { didSet { updateServices() } }

    private(set) var latest: TrackedPose?
    private(set) var sampleRate = 0.0
    private(set) var headphonesConnected = false
    private(set) var frontApp: String?
    var simulated = false

    private var source: MotionSource
    private let keepAlive = AudioKeepAlive()
    private let stem = StemService()
    private let injector = Injector()
    private let hotKeys = HotKeys()
    private let realInput = RealInputMonitor()
    let voice = VoiceService()
    private let hud = HUDController()

    private var tracker = PoseTracker()
    private var engine = GestureEngine()
    private var budTaps = BudTapDetector()
    /// Recent strongest jolt, held briefly so the meter is readable.
    private(set) var tapPeak = 0.0
    private var lastTapLog = 0.0
    private var pointer = PointerEngine()
    private var scroll = ScrollEngine()
    private var dwell = DwellDetector()
    private var history = PointerHistory()

    private var position = Vec2.zero
    private var lastTick = 0.0
    private var lastSample = 0.0
    private var lastRestart = 0.0
    private var clockOffset: Double?
    private var rateWindow: [Double] = []
    private var motionRunning = false
    private var resumableByGesture = false
    private var displayLink: CADisplayLink?
    private var saveTimer: Timer?
    private var permissionTimer: Timer?
    private var stemHoldUntil = 0.0
    private var freezeUntil = 0.0
    private var recordingFile: FileHandle?

    private init() {
        config = store.load()
        source = HeadphoneMotionSource()
    }

    private var now: Double { ProcessInfo.processInfo.systemUptime }

    var statusText: String {
        if !gate.enabled { return resumableByGesture ? L("已暂停", "Paused") : L("控制已关闭", "Control off") }
        if let reason = gate.suspensions.sorted(by: { $0.rawValue < $1.rawValue }).first { return reason.label }
        return config.currentMode.displayName
    }

    var isActive: Bool { gate.enabled }
    var isReceivingMotion: Bool { motionRunning && now - lastSample < 0.5 }

    func start(simulate: Bool) {
        simulated = simulate
        if simulate { source = SimulatedMotionSource() }
        applyConfig()
        saveNow() // Writes back any migration from an older version.
        wireSource()

        hotKeys.onCommand = { [weak self] command in
            guard let self else { return }
            switch command {
            case .toggle: self.setControl(!self.gate.enabled)
            case .recenter: self.recenter()
            case .nextMode: self.nextMode()
            }
        }
        hotKeys.install()

        stem.onPress = { [weak self] gesture in self?.stemPressed(gesture) }
        realInput.onInput = { [weak self] keyboard in self?.realInputSeen(keyboard: keyboard) }

        voice.onPartial = { [weak self] text in self?.hud.show(text, symbol: "waveform", sticky: true) }
        voice.onError = { [weak self] message in self?.hud.show(message, symbol: "exclamationmark.triangle") }
        voice.onFinished = { [weak self] text in
            guard let self else { return }
            self.hud.hide()
            if self.gate.isLive { self.injector.type(text) }
        }

        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let id = app?.bundleIdentifier
            MainActor.assumeIsolated { self?.frontAppChanged(id) }
        }
        frontApp = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        // Nobody is looking: a display asleep must never receive clicks, locked or not.
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.willSleepNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.suspend(.screenLocked) }
            }
        }
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.didWakeNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.resume(.screenLocked) }
            }
        }

        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.suspend(.screenLocked) }
        }
        distributed.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.resume(.screenLocked) }
        }

        // Accessibility is granted in System Settings with no callback, so look for it.
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkPermissions() }
        }
        Log.write("launch: accessibility=\(Permissions.accessibility) path=\(Bundle.main.bundlePath)")
        checkPermissions()
        startDisplayLink()
        updateServices()
    }

    private func wireSource() {
        source.onSample = { [weak self] sample in self?.handle(sample) }
        source.onConnection = { [weak self] connected in self?.connectionChanged(connected) }
    }

    // MARK: Config

    func update(_ change: (inout Config) -> Void) {
        var next = config
        change(&next)
        guard next != config else { return }
        config = next
        applyConfig()
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveNow() }
        }
        changes.send(())
    }

    func replaceConfig(_ new: Config) {
        update { $0 = new }
        saveNow()
    }

    func saveNow() {
        saveTimer?.invalidate()
        do { try store.save(config) } catch { Log.write("save failed: \(error.localizedDescription)") }
    }

    private func applyConfig() {
        pointer.settings = config.pointer
        budTaps.strength = config.tapStrength
        scroll.settings = config.scroll
        dwell.settings = config.dwell
        engine.builtins.settings = config.gestures
        updateServices()
    }

    // MARK: Control

    func setControl(_ on: Bool) {
        guard on != gate.enabled || resumableByGesture else { return }
        resumableByGesture = false
        gate.setEnabled(on)
        resetMotionState()
        if !on { releaseEverything() }
        tracker.recenter()
        if on, !simulated, !Permissions.accessibility {
            // Never the system dialog here: it would appear on every toggle. The button on the
            // Permissions page is the only thing that asks.
            hud.show(L("需要辅助功能权限，请到“权限与隐私”页开启", "Allow Accessibility on the Permissions page"), symbol: "lock.shield")
        } else if on, !simulated, !AudioRoute.isUsingAirPods {
            hud.show(L("请把声音输出切到 AirPods", "Switch sound output to AirPods"), symbol: "airpodspro")
        } else {
            hud.show(on ? config.currentMode.displayName : L("控制已关闭", "Control off"),
                     symbol: on ? "dot.radiowaves.left.and.right" : "pause.circle")
        }
        updateServices()
        changes.send(())
    }

    private func pauseByGesture() {
        gate.setEnabled(false)
        resumableByGesture = true
        releaseEverything()
        resetMotionState()
        hud.show(L("已暂停，再做一次恢复", "Paused. Repeat to resume"), symbol: "pause.circle")
        updateServices()
        changes.send(())
    }

    func recenter() {
        tracker.recenter()
        scroll.reset()
        hud.show(L("已归中", "Recentered"), symbol: "scope")
        changes.send(())
    }

    func nextMode() {
        let ids = config.modes.map(\.id)
        guard let i = ids.firstIndex(of: config.activeMode) else { return }
        setMode(ids[(i + 1) % ids.count])
    }

    func setMode(_ id: String) {
        guard config.mode(id) != nil else { return }
        injector.endDrag()
        update { $0.activeMode = id }
        resetMotionState()
        hud.show(config.currentMode.displayName, symbol: "circle.grid.2x2")
        changes.send(())
    }

    private func resetMotionState() {
        pointer.reset()
        scroll.reset()
        dwell.reset()
        engine.reset()
        history.clear()
        position = Vec2(Double(injector.location.x), Double(injector.location.y))
        hud.dwell(nil, at: .zero)
    }

    /// Every way of stopping comes through here, so nothing stays held or listening.
    private func releaseEverything() {
        injector.endDrag()
        voice.finish()
        hud.dwell(nil, at: .zero)
    }

    private func suspend(_ reason: Suspension) {
        guard !gate.suspensions.contains(reason) else { return }
        gate.suspend(reason)
        releaseEverything()
        resetMotionState()
        Log.write("suspended: \(reason.rawValue)")
        changes.send(())
    }

    private func resume(_ reason: Suspension) {
        guard gate.suspensions.contains(reason) else { return }
        gate.resume(reason)
        resetMotionState()
        Log.write("resumed: \(reason.rawValue)")
        changes.send(())
    }

    private func checkPermissions() {
        let trusted = Permissions.accessibility || simulated
        if trusted {
            resume(.noAccessibility)
            if !realInput.isRunning, Permissions.accessibility { realInput.start() }
        } else {
            suspend(.noAccessibility)
            realInput.stop()
        }
    }

    private func updateServices() {
        let wantMotion = gate.enabled || resumableByGesture || isObserved
        if wantMotion != motionRunning {
            motionRunning = wantMotion
            if wantMotion {
                lastSample = now
                source.start()
            } else {
                source.stop()
                latest = nil
                sampleRate = 0
                tracker.reset()
                clockOffset = nil
            }
        }
        let live = gate.enabled || resumableByGesture
        let wantStem = live && config.safety.captureStem && config.usesStem(mode: config.activeMode, app: frontApp)
        if wantStem { stem.start() } else { stem.stop() }
        if wantMotion, !simulated, config.safety.keepAudioAlive || wantStem { keepAlive.start() } else { keepAlive.stop() }
    }

    private func connectionChanged(_ connected: Bool) {
        headphonesConnected = connected
        Log.write("headphones \(connected ? "connected" : "disconnected")")
        if connected {
            resume(.noHeadphones)
        } else {
            suspend(.noHeadphones)
            // The link flaps briefly when audio routing settles, so only announce a real loss.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, !self.headphonesConnected, self.gate.enabled else { return }
                    self.hud.show(L("耳机已断开，控制已停止", "Headphones disconnected, input stopped"), symbol: "airpodspro")
                }
            }
        }
        changes.send(())
    }

    private func frontAppChanged(_ id: String?) {
        frontApp = id
        let profile = config.apps.first { $0.bundleID == id }
        if profile?.disabled == true { suspend(.appExcluded) } else { resume(.appExcluded) }
        if let mode = profile?.preferredMode, mode != config.activeMode { setMode(mode) }
        updateServices()
    }

    private func realInputSeen(keyboard: Bool) {
        if keyboard, !config.safety.yieldToKeyboard { return }
        let t = now
        let wasAllowed = gate.allowsInput(at: t)
        gate.yield(until: t + config.safety.yieldTime)
        if wasAllowed {
            injector.endDrag()
            pointer.reset()
            dwell.reset()
            history.clear() // A click must never rewind to before the real mouse moved.
            hud.dwell(nil, at: .zero)
        }
    }

    // MARK: Motion pipeline

    private func handle(_ raw: MotionSample) {
        let arrival = now
        // CoreMotion's clock is not guaranteed to match ours. Keep its smooth spacing, on our base.
        if clockOffset == nil || abs(raw.t + clockOffset! - arrival) > 0.25 { clockOffset = arrival - raw.t }
        var sample = raw
        sample.t = raw.t + clockOffset!
        lastSample = arrival
        if headphonesConnected == false { headphonesConnected = true; changes.send(()) }
        resume(.noHeadphones)
        resume(.noMotionData)

        rateWindow.append(arrival)
        rateWindow.removeAll { arrival - $0 > 1 }
        sampleRate = Double(rateWindow.count)

        if let recordingFile, let data = try? JSONEncoder().encode(raw) {
            recordingFile.write(data + Data("\n".utf8))
        }

        guard let tracked = tracker.push(sample) else { return }
        latest = tracked
        poses.send(tracked)

        if gate.isLive, !isRecording {
            switch config.currentMode.motion {
            case .pointer: pointer.update(tracked)
            case .scroll: scroll.update(tracked)
            case .none: break
            }
        }

        guard !isRecording else { return }
        let enabled = config.enabledGestures(mode: config.activeMode, app: frontApp)
        for event in engine.process(tracked, enabled: enabled, templates: config.templates) {
            recognised(event)
        }
        if let acceleration = sample.acceleration, enabled.contains(where: \.isTap) {
            let taps = budTaps.process(t: sample.t, acceleration: acceleration, headSpeed: sample.gyro ?? tracked.rate.peak,
                                       wantsDouble: enabled.contains(.budDoubleTap))
            tapPeak = max(budTaps.lastJolt, tapPeak * 0.96)
            logJolt(accepted: !taps.isEmpty)
            for event in taps where enabled.contains(event.gesture) { recognised(event) }
        }
    }

    /// Records anything tap-sized, so the threshold can be tuned from what really happened.
    private func logJolt(accepted: Bool) {
        guard budTaps.lastJolt > 0.12, now - lastTapLog > 0.1 || accepted else { return }
        lastTapLog = now
        Log.write(String(format: "tap: t=%.2f jolt=%.2f headSpeed=%.0f accepted=%@", now, budTaps.lastJolt, budTaps.lastHeadSpeed, accepted ? "yes" : "no"))
    }

    private func stemPressed(_ gesture: GestureID) {
        Log.write("stem: \(gesture.rawValue)")
        guard now >= stemHoldUntil else { return }
        recognised(GestureEvent(gesture: gesture, startTime: now - config.stemLookback, time: now))
    }

    private func recognised(_ event: GestureEvent) {
        let action = config.action(for: event.gesture, mode: config.activeMode, app: frontApp)
        var executed = false
        if resumableByGesture, action == .pauseResume {
            setControl(true)
            executed = true
        } else if gate.isLive, action.isControlAction || gate.allowsInput(at: now) {
            perform(action, for: event)
            executed = true
        }
        gestures.send(RecognisedGesture(event: event, action: action, executed: executed))
    }

    private func perform(_ action: Action, for event: GestureEvent) {
        // Only clicks rewind the pointer: "back" or a key press must leave it where it is.
        let target = action.isPointerAction ? clickPoint(for: event) : injector.location
        switch action {
        case .none: return
        case .leftClick: injector.click(.left, at: target)
        case .rightClick: injector.click(.right, at: target)
        case .middleClick: injector.click(.center, at: target)
        case .doubleClick: injector.click(.left, at: target, count: 2)
        case .toggleDrag:
            if injector.isDragging { injector.endDrag() } else { injector.beginDrag(at: target) }
        case .pauseResume: pauseByGesture(); return
        case .recenter: recenter(); return
        case .nextMode: nextMode(); return
        case .setMode(let id): setMode(id); return
        case .key(let combo): injector.press(combo)
        case .media(let key):
            // Our own Now Playing claim would swallow the key, so step aside for a moment.
            let wasClaiming = stem.isActive
            if wasClaiming { stem.stop() }
            injector.media(key)
            if wasClaiming {
                stemHoldUntil = now + 0.5
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                    MainActor.assumeIsolated { self?.updateServices() }
                }
            }
        case .dictation: voice.toggle(locale: config.dictationLocale)
        case .runShortcut(let name): runShortcut(name)
        }
        if config.safety.showHUD {
            hud.show("\(config.name(of: event.gesture)) → \(action.label)", symbol: "checkmark.circle")
        }
        if config.safety.soundFeedback { NSSound(named: "Tink")?.play() }
    }

    /// Head gestures land where the pointer was when they began, undoing the nod's own drift.
    private func clickPoint(for event: GestureEvent) -> CGPoint {
        guard config.currentMode.motion == .pointer,
              let past = history.position(at: event.startTime) else { return injector.location }
        let point = CGPoint(x: past.x, y: past.y)
        position = past
        pointer.reset()
        injector.move(to: point)
        freezeUntil = now + 0.15 // Let the press's jolt pass, so the pointer doesn't leap off.
        return point
    }

    private func runShortcut(_ name: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = ["run", name]
        do { try process.run() } catch { Log.write("shortcut failed: \(error.localizedDescription)") }
    }

    // MARK: Frame loop

    private func startDisplayLink() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let link = screen.displayLink(target: self, selector: #selector(frame))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func frame() {
        let t = now
        let dt = min(t - lastTick, 0.05)
        lastTick = t

        if motionRunning, t - lastSample > 0.7 { suspend(.noMotionData) }
        // A stream can stall after an audio route change. Rate-limited, so it can never spin.
        if motionRunning, t - lastSample > 2, t - lastRestart > 5, let headphones = source as? HeadphoneMotionSource {
            lastRestart = t
            headphones.restart()
        }

        guard gate.allowsInput(at: t), !isRecording else {
            position = Vec2(Double(injector.location.x), Double(injector.location.y))
            return
        }
        switch config.currentMode.motion {
        case .pointer: stepPointer(t, dt)
        case .scroll: injector.scroll(scroll.step(now: t, dt: dt))
        case .none: break
        }
    }

    private func stepPointer(_ t: Double, _ dt: Double) {
        let delta = pointer.step(now: t, dt: dt)
        if delta != .zero, t >= freezeUntil {
            let next = ScreenBounds.clamp(CGPoint(x: position.x + delta.x, y: position.y + delta.y))
            position = Vec2(next.x, next.y)
            injector.move(to: next)
        }
        history.record(position, at: t)

        guard config.dwell.enabled, !injector.isDragging else { return }
        let point = CGPoint(x: position.x, y: position.y)
        let state = dwell.update(position: position, at: t)
        guard state.progress > 0 else { hud.dwell(nil, at: .zero); return }
        guard ClickableProbe.isClickable(at: point) else { hud.dwell(nil, at: .zero); return }
        hud.dwell(state.progress, at: point)
        if state.fired {
            hud.dwell(nil, at: .zero)
            injector.click(.left, at: point)
        }
    }

    // MARK: Debug recording

    var isCapturingMotion: Bool { recordingFile != nil }

    func toggleMotionCapture() -> URL? {
        if let file = recordingFile {
            try? file.close()
            recordingFile = nil
            return nil
        }
        let dir = Log.fileURL.deletingLastPathComponent()
        let url = dir.appendingPathComponent("motion-\(Int(Date().timeIntervalSince1970)).jsonl")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        recordingFile = try? FileHandle(forWritingTo: url)
        return url
    }
}
