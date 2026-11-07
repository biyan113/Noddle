import AppKit
import AVFoundation
import CoreMotion
import NoddleCore
import UniformTypeIdentifiers

final class OverviewPage: Page {
    private let stage = Stage(height: 370)
    private var master: Switch!
    private var modes: Segments!
    private let headphones = StatusRow("")
    private let motion = StatusRow("")
    private let access = StatusRow("")
    private let route = StatusRow("")
    private var routeButton: Button!
    private let state = text("", size: 15, weight: .semibold)
    private var timer: Timer?

    override func build() {
        heading(L("你好，这是 Noddle", "Hello, this is Noddle"),
                L("用戴着 AirPods 的头，操作你的 Mac。", "Use your head, with AirPods on, to work your Mac."))

        stage.title.stringValue = L("这是你", "This is you")
        master = Switch(on: false) { [weak self] on in self?.controller.setControl(on) }
        master.controlSize = .large
        modes = Segments(controller.config.modes.map(\.displayName), selected: 0) { [weak self] i in
            guard let self else { return }
            self.controller.setMode(self.controller.config.modes[i].id)
        }
        modes.controlSize = .regular

        let control = Card(vstack([
            hstack([vstack([text(L("头部控制", "Head control"), size: 13, color: .secondaryLabelColor), state], spacing: 2), spacer(), master]),
            modes,
            Button(L("设为正前方", "Set as Straight Ahead"), symbol: "scope") { [weak self] in self?.controller.recenter() },
        ], spacing: 14).filling())
        routeButton = Button(L("切到 AirPods", "Use AirPods")) { [weak self] in
            AudioRoute.useAirPods()
            self?.refresh()
        }
        routeButton.controlSize = .regular
        let status = Card(vstack([headphones, hstack([route, spacer(), routeButton]), motion, access], spacing: 9).filling())
        let keys = Card(vstack(HotKeys.labels.map { entry in
            hstack([text(entry.1, weight: .medium), caption(entry.2)])
        }, spacing: 8))
        let tips = Card(vstack([
            text(L("开始", "Getting started"), weight: .semibold),
            caption(L("1. 戴上 AirPods，连接这台 Mac\n2. 在“权限与隐私”里允许辅助功能\n3. 看向屏幕中央，打开头部控制\n4. 转头瞄准，轻敲耳机外壳点击",
                      "1. Put on AirPods connected to this Mac\n2. Allow Accessibility under Permissions\n3. Look at the screen centre and turn on Head control\n4. Turn to aim; tap the earbud to click")),
        ], spacing: 6))

        let right = vstack([control, status, keys, tips], spacing: 12).filling()
        add(columns(stage, right, rightWidth: 330))
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        timer?.invalidate()
    }

    override func subscribe() {
        onGesture { [weak self] hit in
            let name = AppController.shared.config.name(of: hit.event.gesture)
            self?.stage.subtitle.stringValue = hit.action == .none ? name : "\(name) → \(hit.action.label)"
        }
    }

    override func refresh() {
        let c = controller
        master.state = c.isActive ? .on : .off
        state.stringValue = c.statusText
        modes.selectedSegment = c.config.modes.firstIndex { $0.id == c.config.activeMode } ?? 0
        let receiving = c.isReceivingMotion
        let routed = AudioRoute.isUsingAirPods || c.simulated
        route.set(routed ? L("声音输出是 AirPods", "Sound goes to AirPods") : L("声音没走 AirPods，收不到数据", "Sound isn't on AirPods: no motion"),
                  ok: routed)
        routeButton.isHidden = routed
        headphones.set(receiving || c.headphonesConnected ? L("AirPods 已连接", "AirPods connected") : L("未检测到 AirPods", "No AirPods detected"),
                       ok: receiving || c.headphonesConnected)
        motion.set(receiving ? L("运动数据 \(Int(c.sampleRate)) Hz", "Motion data \(Int(c.sampleRate)) Hz") : L("等待运动数据", "Waiting for motion data"), ok: receiving)
        access.set(Permissions.accessibility ? L("辅助功能已允许", "Accessibility allowed") : L("需要辅助功能权限", "Accessibility needed"),
                   ok: Permissions.accessibility)
        if stage.subtitle.stringValue.isEmpty || !receiving {
            stage.subtitle.stringValue = receiving ? L("人物实时跟随你的头部", "Following your head live") : L("戴上耳机后，人物会跟着你动", "Put on your AirPods and the figure moves with you")
        }
    }
}

final class FeelPage: Page {
    private let pad = TestPad()
    private let stage = Stage(height: 210)
    private let tapMeter = AngleMeter()

    override func build() {
        heading(L("手感", "Feel"), L("边调边试。下面的练习区用的是虚拟指针，不会动到真实鼠标。",
                                    "Tune as you try. The practice area uses a virtual pointer, not your real one."))
        let c = controller.config
        func deg(_ v: Double) -> String { String(format: "%.0f°", v) }
        func sec(_ v: Double) -> String { String(format: "%.2f s", v) }
        func x(_ v: Double) -> String { String(format: "%.1f×", v) }
        func pct(_ v: Double) -> String { String(format: "%.0f%%", v * 100) }

        let pointer = vstack([
            SliderRow(L("速度", "Speed"), value: c.pointer.speed, range: 0.3...3, format: x) { [weak self] v in self?.controller.update { $0.pointer.speed = v } },
            SliderRow(L("加速度", "Acceleration"), value: c.pointer.acceleration, range: 0...2, format: x) { [weak self] v in self?.controller.update { $0.pointer.acceleration = v } },
            SliderRow(L("防抖死区", "Dead zone"), value: c.pointer.deadzone, range: 0...12, format: { String(format: "%.0f°/s", $0) }) { [weak self] v in self?.controller.update { $0.pointer.deadzone = v } },
            SliderRow(L("平滑", "Smoothing"), value: c.pointer.smoothing, range: 0...1, format: pct) { [weak self] v in self?.controller.update { $0.pointer.smoothing = v } },
            SliderRow(L("轻点回退", "Stem rewind"), value: c.stemLookback, range: 0...0.7, format: sec) { [weak self] v in self?.controller.update { $0.stemLookback = v } },
            caption(L("轻点时点在多久之前瞄准的位置。点得偏后就调大，指针被拉回太多就调小。",
                      "Clicks land where you aimed this long before the press. Raise it if clicks land late, lower it if they jump back.")),
            hstack([text(L("反转水平", "Invert horizontal")), spacer(), Switch(on: c.pointer.invertX) { [weak self] v in self?.controller.update { $0.pointer.invertX = v } }]),
            hstack([text(L("反转垂直", "Invert vertical")), spacer(), Switch(on: c.pointer.invertY) { [weak self] v in self?.controller.update { $0.pointer.invertY = v } }]),
        ], spacing: 10).filling()

        pad.translatesAutoresizingMaskIntoConstraints = false
        pad.heightAnchor.constraint(equalToConstant: 180).isActive = true
        let padColumn = vstack([text(L("练习区", "Practice area"), size: 13, weight: .semibold, color: .secondaryLabelColor), Card(pad, padding: 8), stage], spacing: 8).filling()
        stage.title.stringValue = L("动作识别", "Recognition")
        stage.subtitle.stringValue = L("做个动作试试", "Try a gesture")

        tapMeter.translatesAutoresizingMaskIntoConstraints = false
        tapMeter.heightAnchor.constraint(equalToConstant: 8).isActive = true
        tapMeter.limit = 1
        let tap = vstack([
            SliderRow(L("轻敲力度", "Tap strength"), value: c.tapStrength, range: 0.1...1, format: { String(format: "%.2f g", $0) }) { [weak self] v in self?.controller.update { $0.tapStrength = v } },
            tapMeter,
            caption(L("敲一下耳机外壳，看蓝条能到多高。敲不出来就调小，误触就调大。", "Tap the earbud and watch the bar. Lower this if taps are missed, raise it if clicks misfire.")),
        ], spacing: 10).filling()

        let gestures = vstack([
            SliderRow(L("点头幅度", "Nod depth"), value: c.gestures.nodDepth, range: 5...25, format: deg) { [weak self] v in self?.controller.update { $0.gestures.nodDepth = v } },
            SliderRow(L("歪头角度", "Tilt angle"), value: c.gestures.tiltAngle, range: 8...30, format: deg) { [weak self] v in self?.controller.update { $0.gestures.tiltAngle = v } },
            SliderRow(L("转头角度", "Turn angle"), value: c.gestures.turnAngle, range: 12...45, format: deg) { [weak self] v in self?.controller.update { $0.gestures.turnAngle = v } },
            SliderRow(L("抬/低头角度", "Look angle"), value: c.gestures.lookAngle, range: 8...35, format: deg) { [weak self] v in self?.controller.update { $0.gestures.lookAngle = v } },
            SliderRow(L("停住时长", "Hold time"), value: c.gestures.holdTime, range: 0.4...2, format: sec) { [weak self] v in self?.controller.update { $0.gestures.holdTime = v } },
            SliderRow(L("冷却时间", "Cooldown"), value: c.gestures.cooldown, range: 0.1...1.2, format: sec) { [weak self] v in self?.controller.update { $0.gestures.cooldown = v } },
        ], spacing: 10).filling()

        let scroll = vstack([
            SliderRow(L("滚动速度", "Scroll speed"), value: c.scroll.speed, range: 8...80, format: { String(format: "%.0f", $0) }) { [weak self] v in self?.controller.update { $0.scroll.speed = v } },
            SliderRow(L("滚动死区", "Scroll dead zone"), value: c.scroll.deadzone, range: 2...15, format: deg) { [weak self] v in self?.controller.update { $0.scroll.deadzone = v } },
            hstack([text(L("自然滚动方向", "Natural direction")), spacer(), Switch(on: c.scroll.natural) { [weak self] v in self?.controller.update { $0.scroll.natural = v } }]),
            hstack([text(L("转头横向滚动", "Turn to scroll sideways")), spacer(), Switch(on: c.scroll.horizontal) { [weak self] v in self?.controller.update { $0.scroll.horizontal = v } }]),
        ], spacing: 10).filling()

        let left = vstack([titled(L("指针", "Pointer"), pointer), titled(L("轻敲耳机", "Tapping the earbud"), tap), titled(L("动作灵敏度", "Gesture sensitivity"), gestures), titled(L("滚动", "Scrolling"), scroll)], spacing: 14).filling()
        add(columns(left, padColumn, rightWidth: 270))
    }

    override func subscribe() {
        onGesture { [weak self] hit in
            self?.stage.subtitle.stringValue = AppController.shared.config.name(of: hit.event.gesture)
        }
        onPose { [weak self] _ in
            guard let self else { return }
            self.tapMeter.value = self.controller.tapPeak
        }
    }
}

final class CalibratePage: Page {
    private let stage = Stage(height: 380)
    private let yaw = AngleMeter(), pitch = AngleMeter(), roll = AngleMeter()
    private let yawValue = text("0°"), pitchValue = text("0°"), rollValue = text("0°")
    private var countdown: Timer?
    private var startButton: Button!

    override func build() {
        heading(L("校准", "Calibrate"), L("告诉 Noddle 你平时“看向屏幕”的姿势。换坐姿后再来一次就好。",
                                         "Show Noddle how you normally face the screen. Repeat after changing posture."))
        stage.title.stringValue = L("中立姿态", "Neutral pose")
        stage.subtitle.stringValue = L("舒服地坐好，看向屏幕中央", "Sit comfortably and face the screen centre")
        startButton = Button(L("3 秒后记录中立姿态", "Set Neutral in 3 Seconds"), symbol: "scope", prominent: true) { [weak self] in self?.begin() }

        func meter(_ name: String, _ bar: AngleMeter, _ value: NSTextField) -> NSView {
            bar.translatesAutoresizingMaskIntoConstraints = false
            bar.heightAnchor.constraint(equalToConstant: 8).isActive = true
            value.alignment = .right
            value.widthAnchor.constraint(equalToConstant: 44).isActive = true
            return vstack([hstack([text(name), spacer(), value]), bar], spacing: 5).filling()
        }
        let meters = vstack([
            meter(L("左右转头", "Turn"), yaw, yawValue),
            meter(L("抬头低头", "Look"), pitch, pitchValue),
            meter(L("左右歪头", "Tilt"), roll, rollValue),
        ], spacing: 14).filling()

        let direction = vstack([
            caption(L("人物像镜子：你向左，它也向屏幕左边。如果歪头方向反了，打开下面的开关。",
                      "The figure is a mirror: go left and it goes to the screen's left. If tilting is reversed, turn this on.")),
            hstack([text(L("交换左右歪头", "Swap tilt direction")), spacer(),
                    Switch(on: controller.config.gestures.swapTilt) { [weak self] v in self?.controller.update { $0.gestures.swapTilt = v } }]),
        ], spacing: 10).filling()

        let right = vstack([titled(L("实时姿态", "Live pose"), meters), titled(L("方向检查", "Direction check"), direction), startButton], spacing: 14).filling()
        add(columns(stage, right, rightWidth: 310))
    }

    override func subscribe() {
        onPose { [weak self] p in
            guard let self else { return }
            self.yaw.value = -p.pose.yaw
            self.pitch.value = p.pose.pitch
            self.roll.value = p.pose.roll
            self.yawValue.stringValue = String(format: "%.0f°", p.pose.yaw)
            self.pitchValue.stringValue = String(format: "%.0f°", p.pose.pitch)
            self.rollValue.stringValue = String(format: "%.0f°", p.pose.roll)
        }
    }

    private func begin() {
        countdown?.invalidate()
        var left = 3
        stage.title.stringValue = "\(left)"
        countdown = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { return }
                left -= 1
                if left > 0 {
                    self.stage.title.stringValue = "\(left)"
                } else {
                    timer.invalidate()
                    self.controller.recenter()
                    self.stage.figure.pulse()
                    self.stage.title.stringValue = L("完成", "Done")
                }
            }
        }
    }
}

final class AppsPage: Page, NSTableViewDataSource, NSTableViewDelegate {
    private let table = NSTableView()
    private let detail = NSStackView()
    private var selected: String?

    override func build() {
        heading(L("应用配置", "Apps"), L("让某个 App 自动进入一种模式，改写部分动作，或者干脆不生效。",
                                         "Make an app enter a mode, override some gestures, or exclude it entirely."))
        table.addTableColumn(NSTableColumn(identifier: .init("app")))
        table.headerView = nil
        table.rowHeight = 34
        table.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: 380).isActive = true

        let addButton = Button(L("添加 App", "Add App"), symbol: "plus") { [weak self] in self?.addApp() }
        let removeButton = Button(L("移除", "Remove"), symbol: "minus") { [weak self] in self?.removeApp() }
        let left = vstack([Card(scroll, padding: 6), hstack([addButton, removeButton])], spacing: 10).filling()

        detail.orientation = .vertical
        detail.alignment = .leading
        detail.spacing = 12
        let card = Card(detail)
        add(columns(card, left, rightWidth: 230))
    }

    override func refresh() {
        table.reloadData()
        rebuildDetail()
    }

    private var apps: [AppProfile] { controller.config.apps }

    func numberOfRows(in tableView: NSTableView) -> Int { apps.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = NSTableCellView()
        let profile = apps[row]
        var views: [NSView] = []
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: profile.bundleID) {
            let image = NSImageView(image: NSWorkspace.shared.icon(forFile: url.path))
            image.widthAnchor.constraint(equalToConstant: 22).isActive = true
            image.heightAnchor.constraint(equalToConstant: 22).isActive = true
            views.append(image)
        }
        views.append(text(profile.name))
        let stack = hstack(views, spacing: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(stack)
        stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6).isActive = true
        stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor).isActive = true
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        selected = table.selectedRow >= 0 && table.selectedRow < apps.count ? apps[table.selectedRow].bundleID : nil
        rebuildDetail()
    }

    private func addApp() {
        let menu = NSMenu()
        let running = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.bundleIdentifier != nil && $0.bundleIdentifier != Bundle.main.bundleIdentifier
        }
        for app in running.sorted(by: { ($0.localizedName ?? "") < ($1.localizedName ?? "") }) {
            guard let id = app.bundleIdentifier, !apps.contains(where: { $0.bundleID == id }) else { continue }
            let item = NSMenuItem(title: app.localizedName ?? id, action: #selector(pick(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = id
            menu.addItem(item)
        }
        guard menu.numberOfItems > 0, let event = NSApp.currentEvent else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }

    @objc private func pick(_ item: NSMenuItem) {
        guard let id = item.representedObject as? String else { return }
        controller.update { $0.apps.append(AppProfile(bundleID: id, name: item.title)) }
    }

    private func removeApp() {
        guard let selected else { return }
        controller.update { $0.apps.removeAll { $0.bundleID == selected } }
        self.selected = nil
    }

    private func change(_ edit: (inout AppProfile) -> Void) {
        guard let selected else { return }
        controller.update { config in
            if let i = config.apps.firstIndex(where: { $0.bundleID == selected }) { edit(&config.apps[i]) }
        }
    }

    private func rebuildDetail() {
        detail.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard let selected, let profile = apps.first(where: { $0.bundleID == selected }) else {
            detail.addArrangedSubview(caption(L("从左侧选择或添加一个 App。", "Choose or add an app on the left.")))
            return
        }
        let config = controller.config
        detail.addArrangedSubview(text(profile.name, size: 17, weight: .semibold))
        detail.addArrangedSubview(hstack([text(L("在这个 App 里停用 Noddle", "Disable Noddle in this app")), spacer(),
                                          Switch(on: profile.disabled) { [weak self] v in self?.change { $0.disabled = v } }]))
        let modePopup = Popup()
        modePopup.addItem(withTitle: L("不切换", "Keep current"))
        for mode in config.modes { modePopup.addItem(withTitle: mode.displayName) }
        if let id = profile.preferredMode, let i = config.modes.firstIndex(where: { $0.id == id }) { modePopup.selectItem(at: i + 1) }
        modePopup.onChange = { [weak self, weak modePopup] _ in
            guard let self, let modePopup else { return }
            let i = modePopup.indexOfSelectedItem
            self.change { $0.preferredMode = i == 0 ? nil : self.controller.config.modes[i - 1].id }
        }
        detail.addArrangedSubview(hstack([text(L("切到这个 App 时进入", "Switch to mode")), spacer(), modePopup]))

        let modeID = config.activeMode
        detail.addArrangedSubview(text(L("改写“\(config.currentMode.displayName)”里的动作", "Overrides in \(config.currentMode.displayName)"),
                                       weight: .semibold, color: .secondaryLabelColor))
        for gesture in config.allGestures where config.mode(modeID)?.bindings[gesture.rawValue] != nil
            || profile.overrides[modeID]?[gesture.rawValue] != nil {
            let popup = Popup()
            let inherit = L("沿用模式设置", "Same as mode")
            let current = profile.overrides[modeID]?[gesture.rawValue]
            ActionMenu.fill(popup, current: current, config: config, inheritLabel: inherit)
            popup.widthAnchor.constraint(equalToConstant: 180).isActive = true
            popup.onChange = { [weak self] item in
                guard let self else { return }
                ActionMenu.resolve(item, in: self.view.window, done: { choice in
                    self.change { $0.overrides[modeID, default: [:]][gesture.rawValue] = choice }
                }, cancelled: { self.rebuildDetail() })
            }
            detail.addArrangedSubview(hstack([text(config.name(of: gesture)), spacer(), popup]))
        }
        detail.filling()
    }
}

final class PermissionsPage: Page {
    private let access = StatusRow(""), motion = StatusRow(""), mic = StatusRow("")
    private var timer: Timer?

    override func build() {
        heading(L("权限与隐私", "Permissions"), L("所有运动数据都只在这台 Mac 的内存里处理，不联网、不上传、没有统计。",
                                                 "Motion data is processed in memory on this Mac. No network, no uploads, no analytics."))
        let rows = vstack([
            hstack([access, spacer(), Button(L("打开设置", "Open Settings")) {
                Permissions.promptAccessibility()
                Permissions.open("Privacy_Accessibility")
            }]),
            caption(L("用来移动指针、点击和发送按键。", "Moves the pointer, clicks and sends keys.")),
            hstack([motion, spacer(), Button(L("打开设置", "Open Settings")) { Permissions.open("Privacy_Motion") }]),
            caption(L("用来读取 AirPods 的头部运动。", "Reads head motion from your AirPods.")),
            hstack([mic, spacer(), Button(L("请求权限", "Request Access")) { [weak self] in
                self?.controller.voice.requestAccess { _ in self?.refresh() }
            }]),
            caption(L("只有语音输入时才用，没用到可以不开。", "Only for dictation. Optional.")),
        ], spacing: 8).filling()
        section(L("系统权限", "System access"), rows)
        section(L("启动", "Startup"), hstack([text(L("登录时打开 Noddle", "Open Noddle at login")), spacer(),
                                               Switch(on: LoginItem.isEnabled) { LoginItem.set($0) }]))
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        timer?.invalidate()
    }

    override func refresh() {
        access.set(L("辅助功能", "Accessibility"), ok: Permissions.accessibility)
        let status = HeadphoneMotionSource.authorization
        motion.set(L("运动与健身", "Motion & Fitness"), ok: status == .notDetermined ? nil : status == .authorized)
        mic.set(L("麦克风与语音识别（可选）", "Microphone & Speech (optional)"), ok: VoiceService.isAuthorized ? true : nil)
    }
}

final class AdvancedPage: Page {
    private let readout = text("", size: 12, color: .secondaryLabelColor, wrap: true)
    private var captureButton: Button!
    private var timer: Timer?

    override func build() {
        heading(L("高级", "Advanced"), L("安全行为、悬停点击、语音和调试工具。", "Safety behaviour, hover click, dictation and debugging."))
        let c = controller.config
        func toggle(_ title: String, _ on: Bool, _ apply: @escaping (inout Config, Bool) -> Void) -> NSView {
            hstack([text(title), spacer(), Switch(on: on) { [weak self] v in self?.controller.update { apply(&$0, v) } }])
        }
        section(L("安全", "Safety"), vstack([
            SliderRow(L("让出时长", "Yield time"), value: c.safety.yieldTime, range: 0.3...3, format: { String(format: "%.1f s", $0) }) { [weak self] v in
                self?.controller.update { $0.safety.yieldTime = v }
            },
            caption(L("碰到真实鼠标、触控板后，Noddle 会自动让出控制权这么久。", "How long Noddle stays out of the way after you touch a real mouse or trackpad.")),
            toggle(L("打字时也让出", "Also yield while typing"), c.safety.yieldToKeyboard) { $0.safety.yieldToKeyboard = $1 },
            toggle(L("接管耳机柄轻点", "Capture stem presses"), c.safety.captureStem) { $0.safety.captureStem = $1 },
            toggle(L("静音保活（数据更稳定）", "Silent keep-alive (steadier data)"), c.safety.keepAudioAlive) { $0.safety.keepAudioAlive = $1 },
            toggle(L("屏幕提示", "On-screen feedback"), c.safety.showHUD) { $0.safety.showHUD = $1 },
            toggle(L("提示音", "Sound feedback"), c.safety.soundFeedback) { $0.safety.soundFeedback = $1 },
        ], spacing: 10).filling())

        section(L("悬停点击", "Hover click"), vstack([
            toggle(L("指针停在按钮上时自动点击", "Click when resting on a button"), c.dwell.enabled) { $0.dwell.enabled = $1 },
            SliderRow(L("停留时间", "Rest time"), value: c.dwell.duration, range: 0.5...2.5, format: { String(format: "%.1f s", $0) }) { [weak self] v in
                self?.controller.update { $0.dwell.duration = v }
            },
        ], spacing: 10).filling())

        let language = Popup()
        let locales = [("zh-CN", "简体中文"), ("en-US", "English"), ("ja-JP", "日本語")]
        locales.forEach { language.addItem(withTitle: $0.1) }
        language.selectItem(at: locales.firstIndex { $0.0 == c.dictationLocale } ?? 0)
        language.onChange = { [weak self, weak language] _ in
            guard let self, let language else { return }
            let id = locales[language.indexOfSelectedItem].0
            self.controller.update { $0.dictationLocale = id }
        }
        section(L("语音输入", "Dictation"), hstack([text(L("识别语言", "Language")), spacer(), language]))

        section(L("配置", "Configuration"), hstack([
            Button(L("导出…", "Export…")) { [weak self] in self?.exportConfig() },
            Button(L("导入…", "Import…")) { [weak self] in self?.importConfig() },
            spacer(),
            Button(L("恢复默认", "Reset All")) { [weak self] in self?.reset() },
        ]))

        captureButton = Button(L("录制原始运动数据", "Record Raw Motion")) { [weak self] in
            guard let self else { return }
            if let url = self.controller.toggleMotionCapture() { Log.write("capturing to \(url.path)") }
            self.refresh()
        }
        section(L("调试", "Debug"), vstack([
            readout,
            hstack([captureButton, Button(L("打开日志", "Show Logs")) { NSWorkspace.shared.activateFileViewerSelecting([Log.fileURL]) }]),
        ], spacing: 10).filling())
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        timer?.invalidate()
    }

    override func refresh() {
        let c = controller
        let p = c.latest?.pose ?? .zero
        readout.stringValue = String(format: "%@ · %.0f Hz · yaw %.1f° pitch %.1f° roll %.1f°", c.statusText, c.sampleRate, p.yaw, p.pitch, p.roll)
        captureButton?.title = c.isCapturingMotion ? L("停止录制", "Stop Recording") : L("录制原始运动数据", "Record Raw Motion")
    }

    private func exportConfig() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Noddle.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? ConfigStore.encode(controller.config).write(to: url)
    }

    private func importConfig() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        do {
            controller.replaceConfig(try ConfigStore.decode(data))
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    private func reset() {
        let alert = NSAlert()
        alert.messageText = L("恢复全部默认设置？", "Reset everything to defaults?")
        alert.informativeText = L("录制的手势和应用配置都会被清除。", "Recorded gestures and app settings will be removed.")
        alert.addButton(withTitle: L("恢复默认", "Reset"))
        alert.addButton(withTitle: L("取消", "Cancel"))
        if alert.runModal() == .alertFirstButtonReturn {
            var fresh = Config()
            fresh.onboarded = true
            controller.replaceConfig(fresh)
        }
    }
}
