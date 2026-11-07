import AppKit
import NoddleCore

/// The recording flow: do the movement three times, then try it, then keep it.
final class RecordSheet: NSViewController {
    private enum Step { case takes, verify }

    var onFinish: (() -> Void)?
    private let target: GestureID?
    private let modeID: String
    private let controller = AppController.shared

    private let stage = Stage(height: 320)
    private let nameField = NSTextField()
    private let dots = NSStackView()
    private let status = caption("")
    private let notes = caption("")
    private let confidence = NSProgressIndicator()
    private var saveButton: Button!
    private var redoButton: Button!

    private var step = Step.takes
    private var recorder = GestureRecorder()
    private var segmenter = MotionSegmenter()
    private var template: GestureTemplate?
    private var token: UUID?
    private var hits = 0

    init(target: GestureID?, modeID: String) {
        self.target = target
        self.modeID = modeID
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 640))
        let config = controller.config
        let title = target.map { L("录制你的“\(config.name(of: $0))”", "Record your \"\(config.name(of: $0))\"") }
            ?? L("录制新手势", "Record a Gesture")

        nameField.placeholderString = L("给它起个名字", "Give it a name")
        nameField.stringValue = target == nil ? L("我的手势", "My Gesture") : ""
        nameField.isHidden = target != nil
        nameField.widthAnchor.constraint(equalToConstant: 220).isActive = true

        dots.orientation = .horizontal
        dots.spacing = 10
        for _ in 0..<GestureTemplate.requiredTakes {
            let dot = NSView()
            dot.wantsLayer = true
            dot.layer?.cornerRadius = 6
            dot.layer?.borderWidth = 1.5
            dot.layer?.borderColor = NSColor.controlAccentColor.cgColor
            dot.widthAnchor.constraint(equalToConstant: 12).isActive = true
            dot.heightAnchor.constraint(equalToConstant: 12).isActive = true
            dots.addArrangedSubview(dot)
        }

        confidence.style = .bar
        confidence.isIndeterminate = false
        confidence.minValue = 0
        confidence.maxValue = 1
        confidence.isHidden = true
        confidence.widthAnchor.constraint(equalToConstant: 240).isActive = true

        status.alignment = .center
        notes.alignment = .center
        redoButton = Button(L("重录", "Start Over")) { [weak self] in self?.restart() }
        saveButton = Button(L("保存", "Save"), prominent: true) { [weak self] in self?.save() }
        saveButton.isEnabled = false
        let cancel = Button(L("取消", "Cancel")) { [weak self] in self?.close() }

        let stack = vstack([text(title, size: 18, weight: .semibold), nameField, stage, dots, status, confidence, notes,
                            hstack([cancel, spacer(), redoButton, saveButton])],
                           spacing: 12, alignment: .centerX)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -22),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -18),
            stage.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            stage.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            status.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            status.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            notes.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            notes.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            stack.arrangedSubviews.last!.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            stack.arrangedSubviews.last!.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
        ])
        view = root
        stage.title.stringValue = L("做一遍给我看", "Show me")
        stage.subtitle.stringValue = L("人物会跟着你动", "The figure moves with you")
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        controller.isRecording = true
        token = controller.poses.listen { [weak self] pose in self?.receive(pose) }
        restart()
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        controller.poses.remove(token)
        controller.isRecording = false
    }

    private func close() {
        dismiss(nil)
    }

    private func restart() {
        step = .takes
        recorder.restart()
        segmenter.reset()
        template = nil
        hits = 0
        saveButton.isEnabled = false
        confidence.isHidden = true
        notes.stringValue = ""
        stage.figure.play(.live)
        paintDots()
        if controller.isReceivingMotion {
            status.stringValue = L("先保持不动，然后做你的动作。做完停住。共 3 次。",
                                   "Hold still, make your movement, then stop. Three times.")
        } else {
            status.stringValue = L("请戴上 AirPods 并连接这台 Mac。", "Put on your AirPods, connected to this Mac.")
        }
    }

    private func paintDots() {
        for (i, dot) in dots.arrangedSubviews.enumerated() {
            dot.layer?.backgroundColor = i < recorder.takes.count ? NSColor.controlAccentColor.cgColor : NSColor.clear.cgColor
        }
    }

    private func receive(_ pose: TrackedPose) {
        switch step {
        case .takes:
            guard recorder.push(pose) != nil else { return }
            stage.figure.pulse()
            paintDots()
            if recorder.isComplete {
                finishTakes()
            } else {
                status.stringValue = L("很好。第 \(recorder.takes.count + 1) 次。", "Good. Take \(recorder.takes.count + 1).")
            }
        case .verify:
            guard let segment = segmenter.push(pose), let template else { return }
            let distance = template.compare(segment)
            let match = TemplateMatch(gesture: GestureID("preview"), distance: distance, threshold: template.effectiveThreshold)
            confidence.doubleValue = match.confidence
            if match.accepted {
                hits += 1
                stage.figure.pulse()
                status.stringValue = L("认出来了（第 \(hits) 次）。可以保存了。", "Recognised (\(hits)). Ready to save.")
                saveButton.isEnabled = true
            } else {
                status.stringValue = L("这次不像。再试一次，或者重录。", "That didn't match. Try again, or start over.")
            }
        }
    }

    private func finishTakes() {
        guard let made = recorder.makeTemplate() else {
            status.stringValue = L("三次差别太大，换个更固定的做法再录一次。", "Those three were too different. Try a more consistent movement.")
            recorder.restart()
            paintDots()
            return
        }
        template = made
        step = .verify
        segmenter.reset()
        confidence.isHidden = false
        confidence.doubleValue = 0
        status.stringValue = L("学会了！再做一次，确认能认出来。", "Learned! Do it once more to check.")
        stage.title.stringValue = L("这是你的动作", "This is your movement")
        stage.subtitle.stringValue = L("回放中", "Replaying")
        stage.figure.play(.replay(made.reference))

        var warnings: [String] = []
        let config = controller.config
        if config.mode(modeID)?.motion == .pointer, made.looksLikePointing {
            warnings.append(L("这个动作和平时移动指针很像，鼠标模式下可能误触。加一点歪头或来回会更稳。",
                              "This looks like ordinary pointing and may misfire in Pointer mode. Add a tilt or a back-and-forth."))
        }
        for (id, other) in config.templates where id != target && made.isConfusable(with: other) {
            warnings.append(L("和“\(config.name(of: id))”太像，可能认错。", "Too similar to \"\(config.name(of: id))\"."))
        }
        notes.stringValue = warnings.joined(separator: "\n")
    }

    private func save() {
        guard let template else { return }
        let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        controller.update { config in
            if let target {
                if target.isCustom, let i = config.customGestures.firstIndex(where: { $0.id == target }) {
                    config.customGestures[i].template = template
                } else {
                    config.recordedBuiltins[target.rawValue] = template
                }
            } else {
                config.customGestures.append(CustomGesture(name: name.isEmpty ? L("我的手势", "My Gesture") : name, template: template))
            }
        }
        onFinish?()
        close()
    }
}
