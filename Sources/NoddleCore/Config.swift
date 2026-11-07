import Foundation

public struct KeyCombo: Codable, Equatable, Hashable, Sendable {
    public var keyCode: UInt16
    /// CGEventFlags raw value (command, shift, option, control only).
    public var modifiers: UInt64
    public var display: String

    public init(keyCode: UInt16, modifiers: UInt64 = 0, display: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.display = display
    }

    static let command: UInt64 = 0x100000
    static let shift: UInt64 = 0x20000
    static let option: UInt64 = 0x80000
    static let control: UInt64 = 0x40000

    public static let enter = KeyCombo(keyCode: 36, display: "↩")
    public static let escape = KeyCombo(keyCode: 53, display: "⎋")
    public static let space = KeyCombo(keyCode: 49, display: "␣")
    public static let left = KeyCombo(keyCode: 123, display: "←")
    public static let right = KeyCombo(keyCode: 124, display: "→")
    public static let down = KeyCombo(keyCode: 125, display: "↓")
    public static let up = KeyCombo(keyCode: 126, display: "↑")
    public static let pageUp = KeyCombo(keyCode: 116, display: "⇞")
    public static let pageDown = KeyCombo(keyCode: 121, display: "⇟")
    public static let copy = KeyCombo(keyCode: 8, modifiers: command, display: "⌘C")
    public static let paste = KeyCombo(keyCode: 9, modifiers: command, display: "⌘V")
    public static let undo = KeyCombo(keyCode: 6, modifiers: command, display: "⌘Z")
    public static let back = KeyCombo(keyCode: 33, modifiers: command, display: "⌘[")
    public static let forward = KeyCombo(keyCode: 30, modifiers: command, display: "⌘]")
    public static let switchApp = KeyCombo(keyCode: 48, modifiers: command, display: "⌘⇥")
    public static let closeTab = KeyCombo(keyCode: 13, modifiers: command, display: "⌘W")
    public static let nextTab = KeyCombo(keyCode: 30, modifiers: command | shift, display: "⇧⌘]")
    public static let previousTab = KeyCombo(keyCode: 33, modifiers: command | shift, display: "⇧⌘[")
    public static let missionControl = KeyCombo(keyCode: 126, modifiers: control, display: "⌃↑")
    public static let appWindows = KeyCombo(keyCode: 125, modifiers: control, display: "⌃↓")
    public static let spaceLeft = KeyCombo(keyCode: 123, modifiers: control, display: "⌃←")
    public static let spaceRight = KeyCombo(keyCode: 124, modifiers: control, display: "⌃→")
}

public enum MediaKey: String, Codable, CaseIterable, Sendable {
    case playPause, next, previous, volumeUp, volumeDown, mute

    public var label: String {
        switch self {
        case .playPause: L("播放/暂停", "Play / pause")
        case .next: L("下一首", "Next track")
        case .previous: L("上一首", "Previous track")
        case .volumeUp: L("音量增大", "Volume up")
        case .volumeDown: L("音量减小", "Volume down")
        case .mute: L("静音", "Mute")
        }
    }
}

public enum Action: Codable, Equatable, Hashable, Sendable {
    case none
    case leftClick, rightClick, middleClick, doubleClick, toggleDrag
    case pauseResume, recenter, nextMode
    case setMode(String)
    case key(KeyCombo)
    case media(MediaKey)
    case dictation
    case runShortcut(String)

    public var label: String {
        switch self {
        case .none: return L("无动作", "Nothing")
        case .leftClick: return L("左键单击", "Left click")
        case .rightClick: return L("右键单击", "Right click")
        case .middleClick: return L("中键单击", "Middle click")
        case .doubleClick: return L("双击", "Double click")
        case .toggleDrag: return L("开始/结束拖动", "Start / end drag")
        case .pauseResume: return L("暂停/恢复控制", "Pause / resume")
        case .recenter: return L("重新归中", "Recenter")
        case .nextMode: return L("切换到下一模式", "Next mode")
        case .setMode(let id): return L("进入", "Go to ") + (Mode.builtinName(id) ?? id)
        case .key(let combo):
            if let named = Self.keyPresets.first(where: { $0.combo == combo }) { return named.label }
            return L("按键 ", "Key ") + combo.display
        case .media(let key): return key.label
        case .dictation: return L("语音输入", "Dictation")
        case .runShortcut(let name): return L("运行快捷指令：", "Run Shortcut: ") + name
        }
    }

    /// True for actions that act on whatever is under the pointer.
    public var isPointerAction: Bool {
        switch self {
        case .leftClick, .rightClick, .middleClick, .doubleClick, .toggleDrag: true
        default: false
        }
    }

    /// Control actions keep working while Noddle is yielding to a real mouse.
    public var isControlAction: Bool {
        switch self {
        case .pauseResume, .recenter, .nextMode, .setMode: true
        default: false
        }
    }

    public static let keyPresets: [(label: String, combo: KeyCombo)] = [
        (L("返回", "Back"), .back),
        (L("前进", "Forward"), .forward),
        (L("回车", "Return"), .enter),
        (L("Esc", "Escape"), .escape),
        (L("空格", "Space"), .space),
        (L("上一页", "Page up"), .pageUp),
        (L("下一页", "Page down"), .pageDown),
        (L("左方向键", "Left arrow"), .left),
        (L("右方向键", "Right arrow"), .right),
        (L("复制", "Copy"), .copy),
        (L("粘贴", "Paste"), .paste),
        (L("撤销", "Undo"), .undo),
        (L("切换应用", "Switch app"), .switchApp),
        (L("调度中心", "Mission Control"), .missionControl),
        (L("应用窗口", "App windows"), .appWindows),
        (L("左侧桌面", "Space left"), .spaceLeft),
        (L("右侧桌面", "Space right"), .spaceRight),
        (L("上一个标签页", "Previous tab"), .previousTab),
        (L("下一个标签页", "Next tab"), .nextTab),
        (L("关闭标签页", "Close tab"), .closeTab),
    ]
}

/// What head motion itself does in a mode.
public enum MotionTarget: String, Codable, CaseIterable, Sendable {
    case pointer, scroll, none

    public var label: String {
        switch self {
        case .pointer: L("移动指针", "Moves the pointer")
        case .scroll: L("滚动页面", "Scrolls")
        case .none: L("只识别手势", "Gestures only")
        }
    }
}

public struct Mode: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var motion: MotionTarget
    /// Gesture raw value → action.
    public var bindings: [String: Action]

    public init(id: String, name: String, motion: MotionTarget, bindings: [GestureID: Action]) {
        self.id = id
        self.name = name
        self.motion = motion
        self.bindings = Dictionary(uniqueKeysWithValues: bindings.map { ($0.key.rawValue, $0.value) })
    }

    public static let pointerID = "pointer"
    public static let scrollID = "scroll"
    public static let presentID = "present"
    public static let mediaID = "media"

    public static func builtinName(_ id: String) -> String? {
        switch id {
        case pointerID: L("鼠标模式", "Pointer")
        case scrollID: L("阅读模式", "Reading")
        case presentID: L("演示模式", "Presenting")
        case mediaID: L("媒体模式", "Media")
        default: nil
        }
    }

    public var displayName: String { Mode.builtinName(id) ?? name }

    public static let defaults: [Mode] = [
        Mode(id: pointerID, name: "Pointer", motion: .pointer, bindings: [
            // The head aims and a tap on the earbud clicks: a nod moves the very pointer it would click with.
            .budTap: .leftClick,
            .doubleNod: .doubleClick,
            .shake: .pauseResume,
            .tiltLeft: .key(.back),
            .tiltRight: .key(.forward),
            .tiltRightHold: .rightClick,
            .tiltLeftHold: .toggleDrag,
            .stemSingle: .leftClick,
            .stemDouble: .rightClick,
            .stemTriple: .setMode(scrollID),
        ]),
        Mode(id: scrollID, name: "Reading", motion: .scroll, bindings: [
            .budTap: .leftClick,
            .shake: .setMode(pointerID),
            .tiltLeft: .key(.pageUp),
            .tiltRight: .key(.pageDown),
            .stemSingle: .leftClick,
            .stemTriple: .setMode(pointerID),
        ]),
        Mode(id: presentID, name: "Presenting", motion: .none, bindings: [
            .budTap: .key(.right),
            .nod: .key(.right),
            .flickUp: .key(.left),
            .tiltRight: .key(.right),
            .tiltLeft: .key(.left),
            .shake: .pauseResume,
            .stemSingle: .key(.right),
            .stemDouble: .key(.left),
            .stemTriple: .setMode(pointerID),
        ]),
        Mode(id: mediaID, name: "Media", motion: .none, bindings: [
            .nod: .media(.playPause),
            .tiltLeft: .media(.previous),
            .tiltRight: .media(.next),
            .lookUp: .media(.volumeUp),
            .lookDown: .media(.volumeDown),
            .shake: .pauseResume,
            .doubleNod: .setMode(pointerID),
        ]),
    ]
}

/// An app that overrides some bindings, and optionally forces a mode when it comes to the front.
public struct AppProfile: Codable, Equatable, Identifiable, Sendable {
    public var bundleID: String
    public var name: String
    public var preferredMode: String?
    /// Mode id → gesture raw value → action.
    public var overrides: [String: [String: Action]]
    public var disabled: Bool

    public var id: String { bundleID }

    public init(bundleID: String, name: String, preferredMode: String? = nil,
                overrides: [String: [String: Action]] = [:], disabled: Bool = false) {
        self.bundleID = bundleID
        self.name = name
        self.preferredMode = preferredMode
        self.overrides = overrides
        self.disabled = disabled
    }
}

public struct CustomGesture: Codable, Equatable, Identifiable, Sendable {
    public var id: GestureID
    public var name: String
    public var template: GestureTemplate

    public init(id: GestureID = GestureID("custom.\(UUID().uuidString)"), name: String, template: GestureTemplate) {
        self.id = id
        self.name = name
        self.template = template
    }
}

public struct SafetySettings: Codable, Equatable, Sendable {
    /// How long Noddle stays out of the way after real mouse or keyboard input.
    public var yieldTime = 0.9
    public var yieldToKeyboard = true
    /// Claims AirPods stem presses while control is on. Media keys stop reaching your player.
    public var captureStem = true
    public var keepAudioAlive = true
    public var soundFeedback = false
    public var showHUD = true
    public init() {}
}

public struct Config: Codable, Equatable, Sendable {
    public var version = 4
    /// How hard a tap on the earbud must be, in g. On a real pair, accepted taps were 0.40 and
    /// up, while talking and small movements mostly stayed under 0.30.
    public var tapStrength = 0.38
    /// A stem press lands this long after you decided to click: the press jolts the head, and
    /// the AirPods wait to see whether more presses follow. Clicks go where you aimed before it.
    public var stemLookback = 0.3
    public var pointer = PointerSettings()
    public var scroll = ScrollSettings()
    public var dwell = DwellSettings()
    public var gestures = GestureSettings()
    public var safety = SafetySettings()
    public var modes = Mode.defaults
    public var activeMode = Mode.pointerID
    public var customGestures: [CustomGesture] = []
    /// Built-in gesture raw value → the user's own recorded version.
    public var recordedBuiltins: [String: GestureTemplate] = [:]
    public var apps: [AppProfile] = []
    public var dictationLocale = "zh-CN"
    public var onboarded = false

    public init() {}

    /// Tolerates files from older versions: what is missing takes its default, and modes added
    /// since then appear, so upgrading never loses anyone's settings.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let base = Config()
        let savedVersion = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        stemLookback = try c.decodeIfPresent(Double.self, forKey: .stemLookback) ?? base.stemLookback
        tapStrength = try c.decodeIfPresent(Double.self, forKey: .tapStrength) ?? base.tapStrength
        pointer = try c.decodeIfPresent(PointerSettings.self, forKey: .pointer) ?? base.pointer
        scroll = try c.decodeIfPresent(ScrollSettings.self, forKey: .scroll) ?? base.scroll
        dwell = try c.decodeIfPresent(DwellSettings.self, forKey: .dwell) ?? base.dwell
        gestures = try c.decodeIfPresent(GestureSettings.self, forKey: .gestures) ?? base.gestures
        safety = try c.decodeIfPresent(SafetySettings.self, forKey: .safety) ?? base.safety
        // One mode this version can't read must not cost the user all the others.
        modes = (try c.decodeIfPresent([LossyMode].self, forKey: .modes))?.compactMap(\.mode) ?? base.modes
        activeMode = try c.decodeIfPresent(String.self, forKey: .activeMode) ?? base.activeMode
        customGestures = try c.decodeIfPresent([CustomGesture].self, forKey: .customGestures) ?? []
        recordedBuiltins = try c.decodeIfPresent([String: GestureTemplate].self, forKey: .recordedBuiltins) ?? [:]
        apps = try c.decodeIfPresent([AppProfile].self, forKey: .apps) ?? []
        dictationLocale = try c.decodeIfPresent(String.self, forKey: .dictationLocale) ?? base.dictationLocale
        onboarded = try c.decodeIfPresent(Bool.self, forKey: .onboarded) ?? false
        for mode in Mode.defaults where !modes.contains(where: { $0.id == mode.id }) { modes.append(mode) }
        if !modes.contains(where: { $0.id == activeMode }) { activeMode = Mode.pointerID }
        // v2 moved clicking to the stem. A nod the user bound to something else stays theirs.
        if savedVersion < 2, let i = modes.firstIndex(where: { $0.id == Mode.pointerID }),
           modes[i].bindings[GestureID.nod.rawValue] == .leftClick {
            modes[i].bindings[GestureID.nod.rawValue] = nil
        }
        // v4 retuned the default from real taps. A value the user chose stays.
        if savedVersion < 4, tapStrength == 0.35 { tapStrength = base.tapStrength }
        // v3 added tapping the earbud, in the modes that used a stem press for the same job.
        if savedVersion < 3 {
            for i in modes.indices {
                guard let fresh = Mode.defaults.first(where: { $0.id == modes[i].id })?.bindings[GestureID.budTap.rawValue] else { continue }
                modes[i].bindings[GestureID.budTap.rawValue] = fresh
            }
        }
    }

    public func mode(_ id: String) -> Mode? { modes.first { $0.id == id } }
    public var currentMode: Mode { mode(activeMode) ?? modes.first ?? Mode.defaults[0] }

    public func name(of gesture: GestureID) -> String {
        gesture.builtinName ?? customGestures.first { $0.id == gesture }?.name ?? gesture.rawValue
    }

    public var allGestures: [GestureID] {
        GestureID.taps + GestureID.headBuiltins + GestureID.stems + customGestures.map(\.id)
    }

    public func template(for gesture: GestureID) -> GestureTemplate? {
        customGestures.first { $0.id == gesture }?.template ?? recordedBuiltins[gesture.rawValue]
    }

    public var templates: [GestureID: GestureTemplate] {
        var all: [GestureID: GestureTemplate] = [:]
        for (raw, template) in recordedBuiltins { all[GestureID(raw)] = template }
        for custom in customGestures { all[custom.id] = custom.template }
        return all
    }

    /// The action for a gesture: app override first, then the mode.
    public func action(for gesture: GestureID, mode modeID: String, app bundleID: String?) -> Action {
        if let bundleID, let profile = apps.first(where: { $0.bundleID == bundleID }),
           let action = profile.overrides[modeID]?[gesture.rawValue] {
            return action
        }
        return mode(modeID)?.bindings[gesture.rawValue] ?? .none
    }

    /// Everything the recogniser should listen for right now. Unbound gestures are skipped,
    /// which also keeps a held-back nod from delaying clicks when nothing needs a double nod.
    public func enabledGestures(mode modeID: String, app bundleID: String?) -> Set<GestureID> {
        guard let mode = mode(modeID) else { return [] }
        var ids = Set(allGestures.filter { action(for: $0, mode: modeID, app: bundleID) != .none })
        if mode.motion == .pointer {
            ids = ids.filter { !$0.conflictsWithPointer }
        }
        return ids
    }

    /// Stem presses are only claimed when this mode uses them, so music keeps working otherwise.
    public func usesStem(mode modeID: String, app bundleID: String?) -> Bool {
        GestureID.stems.contains { action(for: $0, mode: modeID, app: bundleID) != .none }
    }

    /// Gestures worth listing for a mode.
    public func gestures(for mode: Mode) -> [GestureID] {
        allGestures.filter { !(mode.motion == .pointer && $0.conflictsWithPointer) }
    }

    /// True if nothing but the global hot key could turn control off in this mode.
    public func hasGesturePause(mode modeID: String) -> Bool {
        allGestures.contains { action(for: $0, mode: modeID, app: nil) == .pauseResume }
    }

    /// Other gestures in the mode already doing this action; several gestures may share one.
    public func gestures(boundTo action: Action, mode modeID: String) -> [GestureID] {
        allGestures.filter { self.action(for: $0, mode: modeID, app: nil) == action }
    }

    public mutating func bind(_ gesture: GestureID, to action: Action, mode modeID: String) {
        guard let i = modes.firstIndex(where: { $0.id == modeID }) else { return }
        modes[i].bindings[gesture.rawValue] = action == .none ? nil : action
    }

    public mutating func removeCustomGesture(_ id: GestureID) {
        customGestures.removeAll { $0.id == id }
        for i in modes.indices { modes[i].bindings[id.rawValue] = nil }
        for i in apps.indices {
            for key in apps[i].overrides.keys { apps[i].overrides[key]?[id.rawValue] = nil }
        }
    }
}

private struct LossyMode: Decodable {
    let mode: Mode?
    init(from decoder: Decoder) { mode = try? Mode(from: decoder) }
}

/// Reads and writes the configuration as readable JSON.
public struct ConfigStore: Sendable {
    public let url: URL

    public init(url: URL) { self.url = url }

    public static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Noddle/config.json")
    }

    public func load() -> Config {
        guard let data = try? Data(contentsOf: url) else { return Config() }
        do {
            return try Self.decode(data)
        } catch {
            // Never destroy a file we could not read.
            let backup = url.deletingPathExtension().appendingPathExtension("broken.json")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.copyItem(at: url, to: backup)
            return Config()
        }
    }

    public func save(_ config: Config) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encode(config).write(to: url, options: .atomic)
    }

    public static func encode(_ config: Config) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(config)
    }

    public static func decode(_ data: Data) throws -> Config {
        try JSONDecoder().decode(Config.self, from: data)
    }
}
