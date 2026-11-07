import AVFoundation
import NoddleCore
import Speech

/// Toggle dictation: speak, and the words are typed into whatever has focus.
/// Recognition stays on this Mac when the language supports it.
@MainActor
final class VoiceService {
    var onPartial: ((String) -> Void)?
    var onFinished: ((String) -> Void)?
    var onState: ((Bool) -> Void)?
    var onError: ((String) -> Void)?
    private(set) var isListening = false

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var silenceTimer: Timer?
    private var latest = ""

    static var isAuthorized: Bool {
        SFSpeechRecognizer.authorizationStatus() == .authorized &&
            AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    func requestAccess(then done: @escaping @MainActor (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            AVCaptureDevice.requestAccess(for: .audio) { mic in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { done(status == .authorized && mic) }
                }
            }
        }
    }

    func toggle(locale: String) {
        if isListening {
            finish()
        } else {
            requestAccess { [weak self] granted in
                guard let self else { return }
                if granted {
                    self.begin(locale: locale)
                } else {
                    self.onError?(L("需要麦克风和语音识别权限", "Microphone and Speech Recognition access needed"))
                }
            }
        }
    }

    private func begin(locale: String) {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale)), recognizer.isAvailable else {
            onError?(L("这种语言的语音识别当前不可用", "Speech recognition is unavailable for this language"))
            return
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
        self.request = request
        latest = ""

        let input = engine.inputNode
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in
            request.append(buffer)
        }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            onError?(error.localizedDescription)
            return
        }
        isListening = true
        onState?(true)
        armSilenceTimer()
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let done = (result?.isFinal ?? false) || error != nil
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.isListening else { return }
                    if let text, text != self.latest {
                        self.latest = text
                        self.onPartial?(text)
                        self.armSilenceTimer()
                    }
                    if done { self.finish() }
                }
            }
        }
    }

    private func armSilenceTimer() {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish() }
        }
    }

    func finish() {
        guard isListening else { return }
        isListening = false
        silenceTimer?.invalidate()
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        onState?(false)
        if !latest.isEmpty { onFinished?(latest) }
    }
}
