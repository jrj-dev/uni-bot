import AVFoundation
import Speech

@MainActor
final class SpeechService: ObservableObject {
    enum TTSProvider: String, CaseIterable, Identifiable {
        case local
        case openAINeural

        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .local: return "Local"
            case .openAINeural: return "OpenAI Neural"
            }
        }
    }

    @Published var isListening = false
    @Published var isSpeaking = false
    @Published var transcript = ""
    @Published var micPermissionGranted = false
    @Published var speechPermissionGranted = false
    @Published var ttsProvider: TTSProvider = .local {
        didSet { UserDefaults.standard.set(ttsProvider.rawValue, forKey: "ttsProvider") }
    }
    @Published var openAICloudVoice: String = "alloy" {
        didSet { UserDefaults.standard.set(openAICloudVoice, forKey: "openAICloudVoice") }
    }

    private let synthesizer = AVSpeechSynthesizer()
    private var recognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()
    private var hasInputTap = false
    private var synthDelegate: SynthDelegate?
    private var playerDelegate: PlayerDelegate?
    private var audioPlayer: AVAudioPlayer?
    private var cloudSpeakTask: Task<Void, Never>?
    private let defaultSpeechRate: Float = 0.50

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

    static let availableCloudVoices: [String] = [
        "alloy", "ash", "ballad", "coral", "echo", "sage", "shimmer", "verse",
    ]

    init() {
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        selectedVoiceIdentifier = UserDefaults.standard.string(forKey: "selectedVoiceID") ?? ""
        voiceEnabled = UserDefaults.standard.bool(forKey: "voiceEnabled")
        if let storedProvider = UserDefaults.standard.string(forKey: "ttsProvider"),
           let provider = TTSProvider(rawValue: storedProvider)
        {
            ttsProvider = provider
        } else {
            ttsProvider = .local
        }
        openAICloudVoice = UserDefaults.standard.string(forKey: "openAICloudVoice") ?? "alloy"

        synthDelegate = SynthDelegate { [weak self] in
            DispatchQueue.main.async {
                self?.isSpeaking = false
            }
        }
        synthesizer.delegate = synthDelegate
        playerDelegate = PlayerDelegate { [weak self] in
            DispatchQueue.main.async {
                self?.isSpeaking = false
                self?.audioPlayer = nil
            }
        }
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

    func stopListening() async -> String {
        recognitionRequest?.endAudio()
        // Stop UI transcript mirroring immediately.
        isListening = false
        // Give Speech a brief moment to deliver a final transcription chunk.
        try? await Task.sleep(nanoseconds: 300_000_000)
        let finalText = transcript
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

        switch ttsProvider {
        case .local:
            speakLocal(text)
        case .openAINeural:
            cloudSpeakTask = Task { [weak self] in
                guard let self else { return }
                await self.speakWithOpenAI(text)
            }
        }
    }

    private func speakLocal(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = defaultSpeechRate
        utterance.preUtteranceDelay = 0
        utterance.postUtteranceDelay = 0

        if !selectedVoiceIdentifier.isEmpty,
           let voice = AVSpeechSynthesisVoice(identifier: selectedVoiceIdentifier) {
            utterance.voice = voice
        } else {
            utterance.voice = defaultVoice()
        }

        isSpeaking = true
        synthesizer.speak(utterance)
    }

    func stopSpeaking() {
        cloudSpeakTask?.cancel()
        cloudSpeakTask = nil

        audioPlayer?.stop()
        audioPlayer = nil

        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        isSpeaking = false
    }

    private func speakWithOpenAI(_ text: String) async {
        guard let rawKey = KeychainHelper.loadString(key: .openaiAPIKey) else {
            debugLog("OpenAI TTS key missing; falling back to local voice", category: "Speech")
            speakLocal(text)
            return
        }
        let apiKey = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            debugLog("OpenAI TTS key empty; falling back to local voice", category: "Speech")
            speakLocal(text)
            return
        }

        guard let url = URL(string: "https://api.openai.com/v1/audio/speech") else {
            speakLocal(text)
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30

        let body: [String: Any] = [
            "model": "gpt-4o-mini-tts",
            "voice": openAICloudVoice,
            "input": text,
            "response_format": "mp3",
        ]
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            debugLog("OpenAI TTS request started (voice=\(openAICloudVoice))", category: "Speech")
            let startedAt = Date()
            let (data, response) = try await URLSession.shared.data(for: request)
            if Task.isCancelled { return }
            let elapsedMS = Int(Date().timeIntervalSince(startedAt) * 1000)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            debugLog("OpenAI TTS response HTTP \(status) in \(elapsedMS)ms", category: "Speech")
            guard (200..<300).contains(status) else {
                debugLog("OpenAI TTS failed HTTP \(status); falling back to local voice", category: "Speech")
                speakLocal(text)
                return
            }

            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.duckOthers])
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let player = try AVAudioPlayer(data: data)
            player.delegate = playerDelegate
            audioPlayer = player
            player.prepareToPlay()
            isSpeaking = player.play()
            if !isSpeaking {
                debugLog("OpenAI TTS audio playback failed; falling back to local voice", category: "Speech")
                speakLocal(text)
            }
        } catch {
            debugLog("OpenAI TTS error: \(error.localizedDescription); falling back to local voice", category: "Speech")
            if !Task.isCancelled {
                speakLocal(text)
            }
        }
    }

    private func defaultVoice() -> AVSpeechSynthesisVoice? {
        let englishVoices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("en") }
        if let premiumUS = englishVoices.first(where: { $0.language == "en-US" && $0.quality == .premium }) {
            return premiumUS
        }
        if let enhancedUS = englishVoices.first(where: { $0.language == "en-US" && $0.quality == .enhanced }) {
            return enhancedUS
        }
        return AVSpeechSynthesisVoice(language: "en-US")
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

private final class PlayerDelegate: NSObject, AVAudioPlayerDelegate, @unchecked Sendable {
    let onFinish: () -> Void
    init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        onFinish()
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        onFinish()
    }
}
