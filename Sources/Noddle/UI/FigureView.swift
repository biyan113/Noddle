import AppKit
import NoddleCore
import QuartzCore

/// The living line figure. Follows the real head, or demonstrates a gesture.
final class FigureView: NSView {
    enum Source: Equatable {
        case live
        case demo(GestureID)
        case replay(MotionSegment)
    }

    /// With live data, a demo plays this many times and hands back to the live head.
    var demoLoops = 2
    private(set) var source = Source.live
    private var sourceStart = 0.0

    private var shown = HeadPose.zero
    private var echoes: [HeadPose] = []
    private var lastEcho = 0.0
    private var lastFrame = 0.0
    private var pulseStart: Double?
    private var glow = 0.0
    private var link: CADisplayLink?
    private var gestureToken: UUID?

    private var controller: AppController { .shared }
    private var now: Double { ProcessInfo.processInfo.systemUptime }

    func play(_ next: Source) {
        source = next
        sourceStart = now
    }

    /// Plays the "recognised" ripple.
    func pulse() {
        pulseStart = now
        glow = 1
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        link?.invalidate()
        link = nil
        controller.gestures.remove(gestureToken)
        gestureToken = nil
        guard window != nil else { return }
        let display = displayLink(target: self, selector: #selector(tick))
        display.add(to: .main, forMode: .common)
        link = display
        gestureToken = controller.gestures.listen { [weak self] _ in self?.pulse() }
    }

    private func target(at t: Double) -> HeadPose {
        let elapsed = t - sourceStart
        let liveData = controller.isReceivingMotion
        switch source {
        case .live:
            if liveData, let pose = controller.latest?.pose { return pose }
            // No sensor: breathe, so the figure never looks broken.
            return HeadPose(yaw: 2 * sin(t * 0.5), pitch: 1.2 * sin(t * 0.8), roll: 0.8 * sin(t * 0.37))
        case .demo(let gesture):
            let duration = GestureDemo.duration(of: gesture)
            if liveData, elapsed > duration * Double(demoLoops) { source = .live }
            return GestureDemo.pose(of: gesture, elapsed: elapsed)
        case .replay(let segment):
            return GestureDemo.pose(of: segment, elapsed: elapsed)
        }
    }

    @objc private func tick() {
        let t = now
        let dt = min(max(t - lastFrame, 0.001), 0.05)
        lastFrame = t

        // Sensors tick at ~25-50 Hz, the display at up to 120: ease between them.
        shown = shown.mixed(with: target(at: t), 1 - exp(-dt * 24))

        if t - lastEcho > 0.05 {
            lastEcho = t
            echoes.append(shown)
            if echoes.count > 5 { echoes.removeFirst() }
        }
        let wanted = controller.isReceivingMotion ? 0.55 : 0.0
        glow += (wanted - glow) * (1 - exp(-dt * 3))
        if let start = pulseStart, t - start > 0.8 { pulseStart = nil }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        var style: FigureStyle!
        effectiveAppearance.performAsCurrentDrawingAppearance {
            style = FigureStyle(ink: NSColor.labelColor.cgColor, accent: NSColor.controlAccentColor.cgColor,
                                paper: Theme.surface.cgColor)
        }
        let state = FigureState(
            pose: shown,
            echoes: echoes,
            pulse: pulseStart.map { (now - $0) / 0.8 },
            budGlow: glow,
            dimmed: source == .live && !controller.isReceivingMotion
        )
        FigureRenderer.draw(in: ctx, rect: bounds, state: state, style: style)
    }
}

/// A figure on its card with a caption underneath.
final class Stage: NSView {
    let figure = FigureView()
    let title = text("", size: 15, weight: .semibold)
    let subtitle = caption("")

    init(height: CGFloat = 320) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        title.alignment = .center
        subtitle.alignment = .center
        let stack = vstack([figure, title, subtitle], spacing: 6, alignment: .centerX)
        let card = Card(stack, padding: 14)
        addSubview(card)
        figure.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: topAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),
            card.leadingAnchor.constraint(equalTo: leadingAnchor),
            card.trailingAnchor.constraint(equalTo: trailingAnchor),
            figure.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            figure.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            figure.heightAnchor.constraint(equalToConstant: height),
            subtitle.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            subtitle.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// A practice area with a virtual pointer: tune the feel without moving the real one.
final class TestPad: NSView {
    private var engine = PointerEngine()
    private var position: CGPoint?
    private var trail: [CGPoint] = []
    private var link: CADisplayLink?
    private var token: UUID?
    private var lastFrame = 0.0
    private var controller: AppController { .shared }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        link?.invalidate()
        link = nil
        controller.poses.remove(token)
        token = nil
        guard window != nil else { return }
        let display = displayLink(target: self, selector: #selector(tick))
        display.add(to: .main, forMode: .common)
        link = display
        token = controller.poses.listen { [weak self] pose in
            guard let self else { return }
            self.engine.settings = self.controller.config.pointer
            self.engine.update(pose)
        }
    }

    @objc private func tick() {
        let t = ProcessInfo.processInfo.systemUptime
        let dt = min(t - lastFrame, 0.05)
        lastFrame = t
        var p = position ?? CGPoint(x: bounds.midX, y: bounds.midY)
        let d = engine.step(now: t, dt: dt)
        p.x = min(max(p.x + d.x * 0.45, 8), bounds.maxX - 8)
        p.y = min(max(p.y - d.y * 0.45, 8), bounds.maxY - 8) // view y grows upward
        position = p
        trail.append(p)
        if trail.count > 40 { trail.removeFirst() }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let frame = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 10, yRadius: 10)
        NSColor.separatorColor.setStroke()
        frame.stroke()
        let cross = NSBezierPath()
        cross.move(to: NSPoint(x: bounds.midX, y: 0))
        cross.line(to: NSPoint(x: bounds.midX, y: bounds.height))
        cross.move(to: NSPoint(x: 0, y: bounds.midY))
        cross.line(to: NSPoint(x: bounds.width, y: bounds.midY))
        NSColor.separatorColor.withAlphaComponent(0.4).setStroke()
        cross.stroke()
        for (i, p) in trail.enumerated() {
            NSColor.controlAccentColor.withAlphaComponent(Double(i) / Double(trail.count) * 0.35).setFill()
            NSBezierPath(ovalIn: NSRect(x: p.x - 2, y: p.y - 2, width: 4, height: 4)).fill()
        }
        if let p = position {
            NSColor.controlAccentColor.setFill()
            NSBezierPath(ovalIn: NSRect(x: p.x - 6, y: p.y - 6, width: 12, height: 12)).fill()
        }
    }
}

/// A centred bar for one angle.
final class AngleMeter: NSView {
    var value = 0.0 { didSet { needsDisplay = true } }
    var limit = 45.0

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 8) }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
        let extent = bounds.width / 2 * min(abs(value) / limit, 1)
        let bar = NSRect(x: value < 0 ? bounds.midX - extent : bounds.midX, y: 0, width: extent, height: bounds.height)
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: bar, xRadius: 4, yRadius: 4).fill()
    }
}
