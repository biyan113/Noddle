import AppKit
import NoddleCore

// Small AppKit helpers, so pages read as layout rather than boilerplate.

func text(_ string: String, size: CGFloat = 13, weight: NSFont.Weight = .regular,
          color: NSColor = .labelColor, wrap: Bool = false) -> NSTextField {
    let field = wrap ? NSTextField(wrappingLabelWithString: string) : NSTextField(labelWithString: string)
    field.font = .systemFont(ofSize: size, weight: weight)
    field.textColor = color
    field.isSelectable = false
    return field
}

func caption(_ string: String) -> NSTextField { text(string, size: 12, color: .secondaryLabelColor, wrap: true) }

func vstack(_ views: [NSView], spacing: CGFloat = 12, alignment: NSLayoutConstraint.Attribute = .leading) -> NSStackView {
    let stack = NSStackView(views: views)
    stack.orientation = .vertical
    stack.alignment = alignment
    stack.spacing = spacing
    return stack
}

func hstack(_ views: [NSView], spacing: CGFloat = 10) -> NSStackView {
    let stack = NSStackView(views: views)
    stack.orientation = .horizontal
    stack.alignment = .centerY
    stack.spacing = spacing
    return stack
}

/// Two columns: the first takes all spare width, the second keeps its size.
func columns(_ left: NSView, _ right: NSView, rightWidth: CGFloat? = nil) -> NSStackView {
    let stack = NSStackView(views: [left, right])
    stack.orientation = .horizontal
    stack.alignment = .top
    stack.distribution = .fill
    stack.spacing = 18
    left.setContentHuggingPriority(.init(1), for: .horizontal)
    if let rightWidth { right.widthAnchor.constraint(equalToConstant: rightWidth).isActive = true }
    if let inner = left as? NSStackView { inner.setHuggingPriority(.init(1), for: .horizontal) }
    return stack
}

func spacer() -> NSView {
    let view = NSView()
    view.setContentHuggingPriority(.init(1), for: .horizontal)
    view.setContentHuggingPriority(.init(1), for: .vertical)
    view.setContentCompressionResistancePriority(.init(1), for: .horizontal)
    return view
}

final class Button: NSButton {
    private var handler: (() -> Void)?

    convenience init(_ title: String, symbol: String? = nil, prominent: Bool = false, handler: @escaping () -> Void) {
        self.init(frame: .zero)
        self.title = title
        self.handler = handler
        bezelStyle = .push
        controlSize = .large
        target = self
        action = #selector(fire)
        if let symbol {
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            imagePosition = title.isEmpty ? .imageOnly : .imageLeading
        }
        if prominent { bezelColor = .controlAccentColor }
    }

    @objc private func fire() { handler?() }
}

final class Switch: NSSwitch {
    private var handler: ((Bool) -> Void)?

    convenience init(on: Bool, handler: @escaping (Bool) -> Void) {
        self.init(frame: .zero)
        state = on ? .on : .off
        self.handler = handler
        target = self
        action = #selector(fire)
    }

    @objc private func fire() { handler?(state == .on) }
}

final class Segments: NSSegmentedControl {
    private var handler: ((Int) -> Void)?

    convenience init(_ labels: [String], selected: Int, handler: @escaping (Int) -> Void) {
        self.init(labels: labels, trackingMode: .selectOne, target: nil, action: nil)
        selectedSegment = selected
        self.handler = handler
        target = self
        action = #selector(fire)
        controlSize = .large
    }

    @objc private func fire() { handler?(selectedSegment) }
}

final class Popup: NSPopUpButton {
    var onChange: ((NSMenuItem) -> Void)?

    convenience init() {
        self.init(frame: .zero, pullsDown: false)
        target = self
        action = #selector(fire)
    }

    @objc private func fire() { if let item = selectedItem { onChange?(item) } }
}

/// A titled slider that shows its value. Fires continuously.
final class SliderRow: NSStackView {
    private let slider = NSSlider()
    private let value = text("", size: 12, color: .secondaryLabelColor)
    private var handler: ((Double) -> Void)?
    private var format: (Double) -> String = { String(format: "%.1f", $0) }

    convenience init(_ title: String, value current: Double, range: ClosedRange<Double>,
                     format: @escaping (Double) -> String, handler: @escaping (Double) -> Void) {
        self.init(frame: .zero)
        orientation = .horizontal
        spacing = 10
        self.handler = handler
        self.format = format
        let name = text(title)
        name.widthAnchor.constraint(equalToConstant: 104).isActive = true
        slider.minValue = range.lowerBound
        slider.maxValue = range.upperBound
        slider.doubleValue = current
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(fire)
        slider.widthAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true
        value.alignment = .right
        value.widthAnchor.constraint(equalToConstant: 52).isActive = true
        value.stringValue = format(current)
        addArrangedSubview(name)
        addArrangedSubview(slider)
        addArrangedSubview(value)
    }

    @objc private func fire() {
        value.stringValue = format(slider.doubleValue)
        handler?(slider.doubleValue)
    }
}

enum Theme {
    /// The surface cards and the figure's paper share, so the head's fill is invisible.
    static let surface = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.145, green: 0.145, blue: 0.155, alpha: 1)
            : NSColor(srgbRed: 0.992, green: 0.992, blue: 0.988, alpha: 1)
    }
}

/// A rounded surface that follows light and dark mode.
final class Card: NSView {
    init(_ content: NSView? = nil, padding: CGFloat = 16) {
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        if let content {
            content.translatesAutoresizingMaskIntoConstraints = false
            addSubview(content)
            NSLayoutConstraint.activate([
                content.topAnchor.constraint(equalTo: topAnchor, constant: padding),
                content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -padding),
                content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding),
                content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padding),
            ])
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = Theme.surface.cgColor
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.separatorColor.cgColor
    }
}

/// A coloured dot and label, for status lists.
final class StatusRow: NSStackView {
    private let dot = NSView()
    private let label = text("")

    convenience init(_ title: String) {
        self.init(frame: .zero)
        orientation = .horizontal
        spacing = 8
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        dot.widthAnchor.constraint(equalToConstant: 8).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 8).isActive = true
        label.stringValue = title
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        setHuggingPriority(.required, for: .horizontal)
        addArrangedSubview(dot)
        addArrangedSubview(label)
    }

    func set(_ title: String, ok: Bool?) {
        label.stringValue = title
        let color: NSColor = ok == nil ? .tertiaryLabelColor : (ok! ? .systemGreen : .systemOrange)
        dot.layer?.backgroundColor = color.cgColor
    }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

extension NSStackView {
    /// Stretches every arranged subview to the stack's width.
    @discardableResult func filling() -> Self {
        for view in arrangedSubviews {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.leadingAnchor.constraint(equalTo: leadingAnchor).isActive = true
            view.trailingAnchor.constraint(equalTo: trailingAnchor).isActive = true
        }
        return self
    }
}

/// Base for settings pages: a scrolling body, and bus subscriptions tied to visibility.
class Page: NSViewController {
    let body = NSStackView()
    private var tokens: [() -> Void] = []
    var controller: AppController { .shared }

    override func loadView() {
        let root = NSView()
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 18
        body.edgeInsets = NSEdgeInsets(top: 34, left: 28, bottom: 26, right: 28)
        body.translatesAutoresizingMaskIntoConstraints = false
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(body)
        scroll.documentView = document
        root.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: root.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            body.topAnchor.constraint(equalTo: document.topAnchor),
            body.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            body.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: document.trailingAnchor),
        ])
        view = root
        build()
    }

    /// Adds a full-width view to the page.
    func add(_ view: NSView) {
        body.addArrangedSubview(view)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: 28).isActive = true
        view.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -28).isActive = true
    }

    func heading(_ title: String, _ subtitle: String) {
        add(vstack([text(title, size: 24, weight: .semibold), caption(subtitle)], spacing: 4))
    }

    func section(_ title: String, _ content: NSView) {
        add(titled(title, content))
    }

    func titled(_ title: String, _ content: NSView) -> NSView {
        vstack([text(title, size: 13, weight: .semibold, color: .secondaryLabelColor), Card(content)], spacing: 6).filling()
    }

    func build() {}
    func refresh() {}
    func subscribe() {}

    func onPose(_ handler: @escaping (TrackedPose) -> Void) {
        let id = controller.poses.listen(handler)
        tokens.append { [weak controller] in controller?.poses.remove(id) }
    }

    func onGesture(_ handler: @escaping (RecognisedGesture) -> Void) {
        let id = controller.gestures.listen(handler)
        tokens.append { [weak controller] in controller?.gestures.remove(id) }
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        let id = controller.changes.listen { [weak self] in self?.refresh() }
        tokens.append { [weak controller] in controller?.changes.remove(id) }
        subscribe()
        refresh()
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        tokens.forEach { $0() }
        tokens.removeAll()
    }
}
