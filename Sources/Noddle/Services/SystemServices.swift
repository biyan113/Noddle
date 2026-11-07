import AppKit
import ApplicationServices
import Carbon.HIToolbox
import NoddleCore
import ServiceManagement

enum Log {
    private static let url: URL = {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs/Noddle")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("noddle.log")
    }()

    nonisolated(unsafe) private static var buffer: [String] = []

    static func write(_ message: String) {
        let line = "\(Date().formatted(.iso8601)) \(message)\n"
        buffer.append(line)
        if buffer.count > 200 { buffer.removeFirst(100) }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    static var recent: String { buffer.suffix(60).joined() }
    static var fileURL: URL { url }
}

/// Watches for real mouse, trackpad and keyboard use. Listen-only: it can never block input.
@MainActor
final class RealInputMonitor {
    var onInput: ((_ isKeyboard: Bool) -> Void)?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    var isRunning: Bool { tap != nil }

    func start() {
        guard tap == nil, AXIsProcessTrusted() else { return }
        let types: [CGEventType] = [.mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseDragged,
                                    .rightMouseDragged, .scrollWheel, .keyDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        let me = Unmanaged.passUnretained(self).toOpaque()
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                eventsOfInterest: mask, callback: { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<RealInputMonitor>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.handle(type, event) }
            return Unmanaged.passUnretained(event)
        }, userInfo: me)
        guard let tap else { Log.write("event tap unavailable"); return }
        source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        // Two independent checks: mistaking our own events for a person would freeze the pointer.
        guard event.getIntegerValueField(.eventSourceUserData) != Injector.marker,
              event.getIntegerValueField(.eventSourceUnixProcessID) != Int64(getpid()) else { return }
        onInput?(type == .keyDown)
    }
}

/// Global shortcuts that work whatever the head, app or permissions are doing.
@MainActor
final class HotKeys {
    enum Command: UInt32 { case toggle = 1, recenter, nextMode }

    static let labels: [(Command, String, String)] = [
        (.toggle, "⌃⌥P", L("开启/暂停控制（紧急停止）", "Turn control on / off (emergency stop)")),
        (.recenter, "⌃⌥C", L("重新归中", "Recenter")),
        (.nextMode, "⌃⌥M", L("切换模式", "Next mode")),
    ]

    private var refs: [EventHotKeyRef?] = []
    var onCommand: ((Command) -> Void)?

    func install() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return noErr }
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            let keys = Unmanaged<HotKeys>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated {
                if let command = Command(rawValue: id.id) { keys.onCommand?(command) }
            }
            return noErr
        }, 1, &spec, me, nil)
        let modifiers = UInt32(controlKey | optionKey)
        register(.toggle, key: kVK_ANSI_P, modifiers)
        register(.recenter, key: kVK_ANSI_C, modifiers)
        register(.nextMode, key: kVK_ANSI_M, modifiers)
    }

    private func register(_ command: Command, key: Int, _ modifiers: UInt32) {
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x4E4F4444), id: command.rawValue)
        RegisterEventHotKey(UInt32(key), modifiers, id, GetApplicationEventTarget(), 0, &ref)
        refs.append(ref)
    }
}

enum Permissions {
    static var accessibility: Bool { AXIsProcessTrusted() }

    static func promptAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func open(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}

enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            Log.write("login item: \(error.localizedDescription)")
        }
    }
}
