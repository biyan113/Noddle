import AppKit
import ApplicationServices
import NoddleCore

/// Posts synthetic mouse and keyboard events. Everything it sends carries `marker`, which is
/// how the real-input monitor tells Noddle's events from a person's.
@MainActor
final class Injector {
    static let marker: Int64 = 0x4E4F44444C45
    private let source = CGEventSource(stateID: .privateState)
    private(set) var isDragging = false
    private var scrollRemainder = Vec2.zero

    var location: CGPoint { CGEvent(source: nil)?.location ?? .zero }

    private func post(_ event: CGEvent?) {
        guard let event else { return }
        event.setIntegerValueField(.eventSourceUserData, value: Self.marker)
        event.post(tap: .cghidEventTap)
    }

    func move(to point: CGPoint) {
        let type: CGEventType = isDragging ? .leftMouseDragged : .mouseMoved
        post(CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left))
    }

    func click(_ button: CGMouseButton, at point: CGPoint, count: Int = 1) {
        let (down, up): (CGEventType, CGEventType) = switch button {
        case .left: (.leftMouseDown, .leftMouseUp)
        case .right: (.rightMouseDown, .rightMouseUp)
        default: (.otherMouseDown, .otherMouseUp)
        }
        for n in 1...max(count, 1) {
            for type in [down, up] {
                let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: button)
                event?.setIntegerValueField(.mouseEventClickState, value: Int64(n))
                post(event)
            }
        }
    }

    func beginDrag(at point: CGPoint) {
        guard !isDragging else { return }
        isDragging = true
        post(CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left))
    }

    /// Always safe to call: every pause path ends here, so a button is never left held down.
    func endDrag() {
        guard isDragging else { return }
        isDragging = false
        post(CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: location, mouseButton: .left))
    }

    func scroll(_ delta: Vec2) {
        scrollRemainder = scrollRemainder + delta
        let x = Int32(scrollRemainder.x), y = Int32(scrollRemainder.y)
        guard x != 0 || y != 0 else { return }
        scrollRemainder = scrollRemainder - Vec2(Double(x), Double(y))
        post(CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: y, wheel2: x, wheel3: 0))
    }

    func press(_ combo: KeyCombo) {
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: combo.keyCode, keyDown: down)
            event?.flags = CGEventFlags(rawValue: combo.modifiers)
            post(event)
        }
    }

    func type(_ text: String) {
        // Key events carry at most 20 UTF-16 units.
        let units = Array(text.utf16)
        var index = 0
        while index < units.count {
            let chunk = Array(units[index..<min(index + 20, units.count)])
            for down in [true, false] {
                let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)
                chunk.withUnsafeBufferPointer {
                    event?.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress)
                }
                post(event)
            }
            index += 20
        }
    }

    func media(_ key: MediaKey) {
        let code: Int32 = switch key {
        case .volumeUp: 0
        case .volumeDown: 1
        case .mute: 7
        case .playPause: 16
        case .next: 17
        case .previous: 18
        }
        for down in [true, false] {
            let flags = NSEvent.ModifierFlags(rawValue: down ? 0xA00 : 0xB00)
            let data = Int((code << 16) | ((down ? 0xA : 0xB) << 8))
            let event = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: flags, timestamp: 0,
                                           windowNumber: 0, context: nil, subtype: 8, data1: data, data2: -1)
            event?.cgEvent?.post(tap: .cghidEventTap)
        }
    }
}

/// Keeps a point on some display, in CoreGraphics global coordinates.
enum ScreenBounds {
    private static func frames() -> [CGRect] {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        return ids.map { CGDisplayBounds($0) }
    }

    static func clamp(_ p: CGPoint) -> CGPoint {
        let screens = frames()
        if screens.contains(where: { $0.contains(p) }) { return p }
        var best = p
        var bestDistance = CGFloat.infinity
        for f in screens {
            let c = CGPoint(x: min(max(p.x, f.minX), f.maxX - 1), y: min(max(p.y, f.minY), f.maxY - 1))
            let d = hypot(c.x - p.x, c.y - p.y)
            if d < bestDistance { bestDistance = d; best = c }
        }
        return best
    }
}

/// Is the thing under the pointer something a person would click? Keeps hover-click off text.
enum ClickableProbe {
    private static let roles: Set<String> = [
        "AXButton", "AXLink", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuItem", "AXMenuBarItem",
        "AXMenuButton", "AXTab", "AXDockItem", "AXTextField", "AXSearchField", "AXComboBox", "AXDisclosureTriangle",
        "AXSegment", "AXToolbarButton",
    ]

    static func isClickable(at point: CGPoint) -> Bool {
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &element) == .success,
              let element else { return false }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value) == .success,
              let role = value as? String else { return false }
        return roles.contains(role)
    }
}
