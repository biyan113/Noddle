import AppKit
import NoddleCore

/// Fills a popup with every action. Selecting a special item asks for its details.
@MainActor
enum ActionMenu {
    final class Box: NSObject {
        let action: Action?
        let special: String?
        init(action: Action? = nil, special: String? = nil) {
            self.action = action
            self.special = special
        }
    }

    static func fill(_ popup: NSPopUpButton, current: Action?, config: Config, inheritLabel: String? = nil) {
        let menu = NSMenu()
        popup.autoenablesItems = false
        var selected: NSMenuItem?
        func add(_ action: Action, title: String? = nil) {
            let item = NSMenuItem(title: title ?? action.label, action: nil, keyEquivalent: "")
            item.representedObject = Box(action: action)
            menu.addItem(item)
            if action == current { selected = item }
        }
        func header(_ title: String) {
            menu.addItem(.separator())
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        if let inheritLabel {
            let item = NSMenuItem(title: inheritLabel, action: nil, keyEquivalent: "")
            item.representedObject = Box()
            menu.addItem(item)
            if current == nil { selected = item }
        }
        add(.none)
        header(L("鼠标", "Mouse"))
        [Action.leftClick, .rightClick, .doubleClick, .middleClick, .toggleDrag].forEach { add($0) }
        header(L("控制", "Control"))
        add(.pauseResume); add(.recenter); add(.nextMode)
        for mode in config.modes { add(.setMode(mode.id)) }
        header(L("按键", "Keys"))
        for preset in Action.keyPresets { add(.key(preset.combo)) }
        header(L("媒体", "Media"))
        MediaKey.allCases.forEach { add(.media($0)) }
        header(L("其他", "Other"))
        add(.dictation)
        if let current, selected == nil {
            add(current) // A custom key or Shortcut already chosen.
        }
        for (title, tag) in [(L("自定义按键…", "Custom key…"), "key"), (L("运行快捷指令…", "Run a Shortcut…"), "shortcut")] {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.representedObject = Box(special: tag)
            menu.addItem(item)
        }
        popup.menu = menu
        if let selected { popup.select(selected) }
    }

    /// Resolves a choice, asking for details if needed. `nil` result means "inherit".
    static func resolve(_ item: NSMenuItem, in window: NSWindow?, done: @escaping (Action?) -> Void, cancelled: @escaping () -> Void) {
        guard let box = item.representedObject as? Box else { return cancelled() }
        switch box.special {
        case "key":
            KeyCaptureSheet.present(in: window) { combo in
                if let combo { done(.key(combo)) } else { cancelled() }
            }
        case "shortcut":
            let alert = NSAlert()
            alert.messageText = L("输入快捷指令的名称", "Name of the Shortcut")
            alert.informativeText = L("它必须已存在于“快捷指令”App 中。", "It must already exist in the Shortcuts app.")
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
            alert.accessoryView = field
            alert.addButton(withTitle: L("好", "OK"))
            alert.addButton(withTitle: L("取消", "Cancel"))
            if alert.runModal() == .alertFirstButtonReturn, !field.stringValue.isEmpty {
                done(.runShortcut(field.stringValue))
            } else {
                cancelled()
            }
        default:
            done(box.action)
        }
    }
}

/// Captures one key combination.
@MainActor
enum KeyCaptureSheet {
    private final class Catcher: NSView {
        var onKey: ((NSEvent) -> Void)?
        override var acceptsFirstResponder: Bool { true }
        override func keyDown(with event: NSEvent) { onKey?(event) }
    }

    static func present(in window: NSWindow?, done: @escaping (KeyCombo?) -> Void) {
        let alert = NSAlert()
        alert.messageText = L("按下想绑定的按键", "Press the key to bind")
        alert.informativeText = L("可以带 ⌘ ⌥ ⌃ ⇧。", "Modifiers ⌘ ⌥ ⌃ ⇧ are fine.")
        alert.addButton(withTitle: L("取消", "Cancel"))
        let catcher = Catcher(frame: NSRect(x: 0, y: 0, width: 240, height: 4))
        alert.accessoryView = catcher
        var result: KeyCombo?
        catcher.onKey = { event in
            var mods: UInt64 = 0
            var shown = ""
            let flags = event.modifierFlags
            if flags.contains(.control) { mods |= 0x40000; shown += "⌃" }
            if flags.contains(.option) { mods |= 0x80000; shown += "⌥" }
            if flags.contains(.shift) { mods |= 0x20000; shown += "⇧" }
            if flags.contains(.command) { mods |= 0x100000; shown += "⌘" }
            shown += (event.charactersIgnoringModifiers ?? "?").uppercased()
            result = KeyCombo(keyCode: event.keyCode, modifiers: mods, display: shown)
            NSApp.stopModal()
            alert.window.orderOut(nil)
        }
        alert.window.initialFirstResponder = catcher
        DispatchQueue.main.async { alert.window.makeFirstResponder(catcher) }
        _ = alert.runModal()
        done(result)
    }
}

final class GesturesPage: Page, NSTableViewDataSource, NSTableViewDelegate {
    private let stage = Stage(height: 300)
    private let table = NSTableView()
    private var modeControl: Segments!
    private var modeID = Mode.pointerID
    private var rows: [GestureID] = []
    private var selected: GestureID?
    private let warning = caption("")
    private let recordButton = NSButton()
    private let resetButton = NSButton()

    override func build() {
        heading(L("动作与映射", "Gestures"),
                L("为每种模式决定：什么动作，做什么事。选中一行，人物会演示给你看。",
                  "Decide what each movement does in each mode. Select a row and the figure shows it."))

        let modes = controller.config.modes
        modeControl = Segments(modes.map(\.displayName), selected: 0) { [weak self] i in
            guard let self else { return }
            self.modeID = self.controller.config.modes[i].id
            self.reloadRows()
        }

        table.addTableColumn(NSTableColumn(identifier: .init("gesture")))
        table.headerView = nil
        table.rowHeight = 40
        table.style = .plain
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .regular
        table.dataSource = self
        table.delegate = self
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: 430).isActive = true

        let list = Card(scroll, padding: 6)
        let addButton = Button(L("录制新手势", "Record a Gesture"), symbol: "plus") { [weak self] in self?.record(nil) }

        for (button, title, symbol, selector) in [
            (recordButton, L("录制我的版本", "Record My Version"), "record.circle", #selector(recordSelected)),
            (resetButton, L("恢复默认动作", "Use Default"), "arrow.uturn.backward", #selector(resetSelected)),
        ] {
            button.title = title
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            button.imagePosition = .imageLeading
            button.bezelStyle = .push
            button.controlSize = .large
            button.target = self
            button.action = selector
        }
        let right = vstack([stage, hstack([recordButton, resetButton]), warning], spacing: 10, alignment: .centerX)
        stage.leadingAnchor.constraint(equalTo: right.leadingAnchor).isActive = true
        stage.trailingAnchor.constraint(equalTo: right.trailingAnchor).isActive = true
        warning.leadingAnchor.constraint(equalTo: right.leadingAnchor).isActive = true
        warning.trailingAnchor.constraint(equalTo: right.trailingAnchor).isActive = true

        let left = vstack([list, hstack([addButton, spacer()])], spacing: 10).filling()
        add(hstack([modeControl, spacer()]))
        add(columns(left, right, rightWidth: 300))
        reloadRows()
    }

    override func subscribe() {
        onGesture { [weak self] hit in
            guard let self, hit.event.gesture == self.selected else { return }
            self.stage.subtitle.stringValue = L("识别到了！", "Recognised!") + " · " + hit.action.label
        }
    }

    override func refresh() {
        let id = table.selectedRow
        reloadRows()
        if id >= 0, id < rows.count { table.selectRowIndexes([id], byExtendingSelection: false) }
    }

    private func reloadRows() {
        let config = controller.config
        rows = config.mode(modeID).map(config.gestures(for:)) ?? []
        table.reloadData()
        updateDetail()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let gesture = rows[row]
        let config = controller.config
        let cell = NSTableCellView()
        var labels: [NSView] = [text(config.name(of: gesture))]
        if config.recordedBuiltins[gesture.rawValue] != nil {
            labels.append(text(L("我的版本", "My version"), size: 11, color: .controlAccentColor))
        }
        let popup = Popup()
        popup.controlSize = .regular
        let action = config.mode(modeID)?.bindings[gesture.rawValue] ?? Action.none
        ActionMenu.fill(popup, current: action, config: config)
        popup.onChange = { [weak self, weak popup] item in
            guard let self else { return }
            ActionMenu.resolve(item, in: self.view.window, done: { choice in
                self.controller.update { $0.bind(gesture, to: choice ?? .none, mode: self.modeID) }
                self.updateWarning()
            }, cancelled: {
                if let popup { ActionMenu.fill(popup, current: action, config: self.controller.config) }
            })
        }
        popup.widthAnchor.constraint(equalToConstant: 170).isActive = true
        let stack = hstack(labels + [spacer(), popup])
        stack.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            stack.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        selected = table.selectedRow >= 0 ? rows[table.selectedRow] : nil
        updateDetail()
        guard let selected else { return }
        if let template = controller.config.template(for: selected) {
            stage.figure.play(.replay(template.reference))
        } else if !selected.isStem, !selected.isTap {
            stage.figure.play(.demo(selected))
        } else {
            stage.figure.play(.live)
        }
    }

    private func updateDetail() {
        guard let selected else {
            stage.title.stringValue = L("这是你", "This is you")
            stage.subtitle.stringValue = L("人物实时跟随你的头部。", "The figure follows your head live.")
            recordButton.isHidden = true
            resetButton.isHidden = true
            warning.stringValue = ""
            return
        }
        let config = controller.config
        stage.title.stringValue = config.name(of: selected)
        let action = config.mode(modeID)?.bindings[selected.rawValue] ?? .none
        stage.subtitle.stringValue = action == .none ? L("未绑定", "Not bound") : action.label
        recordButton.isHidden = selected.isStem || selected.isTap
        resetButton.title = selected.isCustom ? L("删除手势", "Delete Gesture") : L("恢复默认动作", "Use Default")
        resetButton.isHidden = !(selected.isCustom || config.recordedBuiltins[selected.rawValue] != nil)
        updateWarning()
    }

    private func updateWarning() {
        guard let selected else { return }
        let config = controller.config
        var notes: [String] = []
        if selected.isStem {
            notes.append(L("轻点时，音乐的播放控制会暂时交给 Noddle。", "While in use, stem presses control Noddle instead of your music."))
        }
        if selected.isTap {
            notes.append(L("手指轻敲耳机外壳，头保持基本不动。力度在“手感”页调。", "Tap the shell with a finger, head nearly still. Adjust strength on the Feel page."))
        }
        let action = config.mode(modeID)?.bindings[selected.rawValue] ?? .none
        let others = config.gestures(boundTo: action, mode: modeID).filter { $0 != selected }
        if action != .none, !others.isEmpty {
            notes.append(L("同一件事也可由：", "Also triggered by: ") + others.map(config.name(of:)).joined(separator: "、"))
        }
        if !config.hasGesturePause(mode: modeID) {
            notes.append(L("这个模式没有暂停动作，只能用 ⌃⌥P 停止。", "This mode has no pause gesture; use ⌃⌥P to stop."))
        }
        warning.stringValue = notes.joined(separator: "\n")
    }

    @objc private func recordSelected() { record(selected) }

    @objc private func resetSelected() {
        guard let selected else { return }
        controller.update {
            if selected.isCustom { $0.removeCustomGesture(selected) } else { $0.recordedBuiltins[selected.rawValue] = nil }
        }
        self.selected = nil
        table.deselectAll(nil)
        reloadRows()
    }

    /// `target` nil = a brand new gesture; otherwise re-record that gesture.
    private func record(_ target: GestureID?) {
        let sheet = RecordSheet(target: target, modeID: modeID)
        sheet.onFinish = { [weak self] in self?.reloadRows() }
        presentAsSheet(sheet)
    }
}
