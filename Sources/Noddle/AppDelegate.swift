import AppKit
import CoreMotion
import NoddleCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var settings: SettingsWindowController?
    private var changeToken: UUID?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let arguments = CommandLine.arguments
        if let i = arguments.firstIndex(of: "--probe") {
            let seconds = arguments.indices.contains(i + 1) ? Double(arguments[i + 1]) ?? 15 : 15
            Probe.shared.run(seconds: seconds)
            return
        }

        let controller = AppController.shared
        controller.start(simulate: arguments.contains("--simulate"))

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = StatusIcon.image(active: false)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        changeToken = controller.changes.listen { [weak self] in self?.refreshIcon() }

        if let i = arguments.firstIndex(of: "--snapshot"), arguments.indices.contains(i + 1) {
            openSettings(page: nil)
            settings?.snapshotAll(to: arguments[i + 1],
                                  ids: ["overview", "gestures", "feel", "calibrate", "apps", "permissions", "advanced"]) {
                NSApp.terminate(nil)
            }
        } else if let i = arguments.firstIndex(of: "--page") {
            openSettings(page: arguments.indices.contains(i + 1) ? arguments[i + 1] : nil)
        } else if !controller.config.onboarded {
            openSettings(page: nil)
            controller.update { $0.onboarded = true }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppController.shared.setControl(false)
        AppController.shared.saveNow()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    private func refreshIcon() {
        statusItem.button?.image = StatusIcon.image(active: AppController.shared.isActive)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let c = AppController.shared
        menu.removeAllItems()
        let status = NSMenuItem(title: "Noddle · \(c.statusText)", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        let toggle = NSMenuItem(title: c.isActive ? L("关闭控制", "Turn Control Off") : L("开启控制", "Turn Control On"),
                                action: #selector(toggleControl), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)
        let center = NSMenuItem(title: L("重新归中", "Recenter"), action: #selector(recenter), keyEquivalent: "")
        center.target = self
        menu.addItem(center)
        menu.addItem(.separator())

        for mode in c.config.modes {
            let item = NSMenuItem(title: mode.displayName, action: #selector(chooseMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.id
            item.state = mode.id == c.config.activeMode ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let open = NSMenuItem(title: L("设置…", "Settings…"), action: #selector(showSettings), keyEquivalent: ",")
        open.target = self
        menu.addItem(open)
        menu.addItem(NSMenuItem(title: L("退出 Noddle", "Quit Noddle"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc private func toggleControl() {
        let c = AppController.shared
        c.setControl(!c.isActive)
    }
    @objc private func recenter() { AppController.shared.recenter() }
    @objc private func chooseMode(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { AppController.shared.setMode(id) }
    }
    @objc private func showSettings() { openSettings(page: nil) }

    private func openSettings(page: String?) {
        if settings == nil { settings = SettingsWindowController() }
        settings?.present(page: page)
    }
}

/// The menu bar glyph: a head with an AirPod, drawn so it follows the menu bar's colour.
enum StatusIcon {
    @MainActor static func image(active: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setStroke()
            NSColor.black.setFill()
            let head = NSBezierPath(ovalIn: NSRect(x: 3, y: 3, width: 11, height: 12.5))
            head.lineWidth = 1.4
            if active { head.fill() } else { head.stroke() }
            let stem = NSBezierPath()
            stem.move(to: NSPoint(x: 15.6, y: 9.5))
            stem.line(to: NSPoint(x: 15.6, y: 6.5))
            stem.lineWidth = 1.8
            stem.lineCapStyle = .round
            stem.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }
}

/// `Noddle --probe 15`: measures what the sensors really deliver and prints a JSON report.
@MainActor
final class Probe {
    static let shared = Probe()
    private let source = HeadphoneMotionSource()
    private let audio = AudioKeepAlive()
    private var samples: [MotionSample] = []
    private var connected = false

    func run(seconds: Double) {
        print("probe: authorization=\(HeadphoneMotionSource.authorization.rawValue)")
        source.onSample = { [weak self] in self?.samples.append($0) }
        source.onConnection = { [weak self] in
            self?.connected = $0
            print("probe: connected=\($0)")
        }
        audio.start()
        source.start()
        Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish(seconds) }
        }
    }

    private func finish(_ seconds: Double) {
        var tracker = PoseTracker()
        var engine = GestureEngine()
        var rates: [Double] = []
        var rebased = 0
        var events: [String] = []
        let all = Set(GestureID.headBuiltins)
        for sample in samples {
            guard let p = tracker.push(sample) else { continue }
            if p.rebased { rebased += 1 }
            rates.append(max(abs(p.rate.yaw), abs(p.rate.pitch)))
            events += engine.process(p, enabled: all, templates: [:]).map(\.gesture.rawValue)
        }
        let sorted = rates.sorted()
        func percentile(_ q: Double) -> Double { sorted.isEmpty ? 0 : sorted[Int(Double(sorted.count - 1) * q)] }
        func span(_ v: [Double]) -> Double { (v.max() ?? 0) - (v.min() ?? 0) }
        let gaps = zip(samples, samples.dropFirst()).map { $1.t - $0.t }.sorted()
        let streamed = (samples.last?.t ?? 0) - (samples.first?.t ?? 0)
        print("""
        probe: samples=\(samples.count) streamedSeconds=\(streamed) hz=\(Double(samples.count) / max(streamed, 0.01)) \
        medianGapMs=\(gaps.isEmpty ? 0 : gaps[gaps.count / 2] * 1000) maxGapMs=\((gaps.last ?? 0) * 1000) \
        rateP50=\(percentile(0.5)) rateP90=\(percentile(0.9)) rateP99=\(percentile(0.99)) rebased=\(rebased) \
        yawSpan=\(span(samples.map { Angle.degrees($0.yaw) })) pitchSpan=\(span(samples.map { Angle.degrees($0.pitch) })) \
        rollSpan=\(span(samples.map { Angle.degrees($0.roll) })) gestures=\(events)
        """)
        NSApp.terminate(nil)
    }
}
