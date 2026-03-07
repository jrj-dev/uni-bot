import AVFoundation
import Speech

@MainActor
final class SpeechService: ObservableObject {
    @Published var isListening = false
    @Published var isSpeaking = false
    @Published var transcript = ""
    @Published var micPermissionGranted = false
    @Published var speechPermissionGranted = false

    private let synthesizer = AVSpeechSynthesizer()
    private var recognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()
    private var hasInputTap = false
    private var synthDelegate: SynthDelegate?

    var selectedVoiceIdentifier: String = "" {
        didSet { UserDefaults.standard.set(selectedVoiceIdentifier, forKey: "selectedVoiceID") }
    }

    var voiceEnabled: Bool = false {
        didSet { UserDefaults.standard.set(voiceEnabled, forKey: "voiceEnabled") }
    }

    static var availableVoices: [(id: String, name: String, language: String)] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") }
            .sorted { $0.name < $1.name }
            .map { (id: $0.identifier, name: $0.name, language: $0.language) }
    }

    init() {
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        selectedVoiceIdentifier = UserDefaults.standard.string(forKey: "selectedVoiceID") ?? ""
        voiceEnabled = UserDefaults.standard.bool(forKey: "voiceEnabled")

        synthDelegate = SynthDelegate { [weak self] in
            DispatchQueue.main.async {
                self?.isSpeaking = false
            }
        }
        synthesizer.delegate = synthDelegate
    }

    // MARK: - Permissions

    func requestPermissions() async {
        let micStatus = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
        micPermissionGranted = micStatus

        let speechStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
        speechPermissionGranted = speechStatus
    }

    // MARK: - Speech-to-Text

    func startListening() {
        guard !isListening, micPermissionGranted, speechPermissionGranted else { return }
        guard let recognizer, recognizer.isAvailable else { return }

        // Stop any ongoing speech output
        stopSpeaking()

        transcript = ""
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest else { return }
        recognitionRequest.shouldReportPartialResults = true

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
            guard buffer.frameLength > 0 else { return }
            recognitionRequest.append(buffer)
        }
        hasInputTap = true

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            debugLog("Speech startListening audio setup failed: \(error.localizedDescription)", category: "Speech")
            cleanupRecognition()
            return
        }

        recognitionTask = recognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if let result {
                    self.transcript = result.bestTranscription.formattedString
                }
                if error != nil || (result?.isFinal ?? false) {
                    self.cleanupRecognition()
                }
            }
        }

        isListening = true
    }

    func stopListening() -> String {
        let finalText = transcript
        recognitionRequest?.endAudio()
        cleanupRecognition()
        return finalText
    }

    private func cleanupRecognition() {
        audioEngine.stop()
        if hasInputTap {
            audioEngine.inputNode.removeTap(onBus: 0)
            hasInputTap = false
        }
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        isListening = false
    }

    // MARK: - Text-to-Speech

    func speak(_ text: String) {
        guard voiceEnabled, !text.isEmpty else { return }

        stopSpeaking()

        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate

        if !selectedVoiceIdentifier.isEmpty,
           let voice = AVSpeechSynthesisVoice(identifier: selectedVoiceIdentifier) {
            utterance.voice = voice
        } else {
            utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        }

        isSpeaking = true
        synthesizer.speak(utterance)
    }

    func stopSpeaking() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        isSpeaking = false
    }
}

// MARK: - Synth Delegate

private final class SynthDelegate: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    let onFinish: () -> Void
    init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        onFinish()
    }
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        onFinish()
    }
}
