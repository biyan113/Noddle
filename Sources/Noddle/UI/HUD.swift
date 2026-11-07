import AppKit
import NoddleCore

/// Small, non-activating feedback: a capsule at the bottom of the screen and a hover-click ring.
@MainActor
final class HUDController {
    private var panel: NSPanel?
    private let label = NSTextField(labelWithString: "")
    private let icon = NSImageView()
    private var hideTimer: Timer?
    private var ring: NSPanel?
    private var ringView: RingView?

    private func overlay(size: NSSize) -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        return panel
    }

    private func capsule() -> NSPanel {
        if let panel { return panel }
        let made = overlay(size: NSSize(width: 300, height: 44))
        let blur = NSVisualEffectView(frame: made.contentView!.bounds)
        blur.autoresizingMask = [.width, .height]
        blur.material = .hudWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 22
        blur.layer?.masksToBounds = true
        made.contentView?.addSubview(blur)

        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.lineBreakMode = .byTruncatingHead
        icon.contentTintColor = .controlAccentColor
        let stack = NSStackView(views: [icon, label])
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        blur.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerYAnchor.constraint(equalTo: blur.centerYAnchor),
            stack.centerXAnchor.constraint(equalTo: blur.centerXAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: blur.leadingAnchor, constant: 18),
        ])
        panel = made
        return made
    }

    func show(_ text: String, symbol: String, sticky: Bool = false) {
        guard AppController.shared.config.safety.showHUD || sticky else { return }
        let panel = capsule()
        label.stringValue = text
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        let width = min(max(label.intrinsicContentSize.width + 76, 170), 640)
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            panel.setFrame(NSRect(x: f.midX - width / 2, y: f.minY + 72, width: width, height: 44), display: true)
        }
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        hideTimer?.invalidate()
        guard !sticky else { return }
        hideTimer = Timer.scheduledTimer(withTimeInterval: 1.3, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
    }

    func hide() {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated { panel.orderOut(nil) }
        })
    }

    /// Shows hover-click progress at a point in CoreGraphics coordinates; nil hides it.
    func dwell(_ progress: Double?, at point: CGPoint) {
        guard let progress else { ring?.orderOut(nil); return }
        if ring == nil {
            let made = overlay(size: NSSize(width: 44, height: 44))
            let view = RingView(frame: made.contentView!.bounds)
            made.contentView?.addSubview(view)
            ring = made
            ringView = view
        }
        let height = NSScreen.screens.first?.frame.height ?? 0
        ring?.setFrameOrigin(NSPoint(x: point.x - 22, y: height - point.y - 22))
        ringView?.progress = progress
        ring?.orderFrontRegardless()
    }
}

private final class RingView: NSView {
    var progress = 0.0 { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let box = bounds.insetBy(dx: 6, dy: 6)
        let track = NSBezierPath(ovalIn: box)
        track.lineWidth = 3
        NSColor.black.withAlphaComponent(0.18).setStroke()
        track.stroke()
        let arc = NSBezierPath()
        arc.appendArc(withCenter: NSPoint(x: bounds.midX, y: bounds.midY), radius: box.width / 2,
                      startAngle: 90, endAngle: 90 - 360 * progress, clockwise: true)
        arc.lineWidth = 3
        arc.lineCapStyle = .round
        NSColor.controlAccentColor.setStroke()
        arc.stroke()
    }
}
