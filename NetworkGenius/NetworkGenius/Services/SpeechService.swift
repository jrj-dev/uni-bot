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
    private var pendingCloudFallbackText: String?
    private let defaultSpeechRate: Float = 0.50
    private let openAITTSTimeoutSeconds: TimeInterval = 25
    private let openAITTSMaxCharacters = 650
    private let openAITTSRetryMaxCharacters = 220

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
        playerDelegate = PlayerDelegate(
            onFinish: { [weak self] success in
                guard let self else { return }
                DispatchQueue.main.async {
                    self.isSpeaking = false
                    self.audioPlayer = nil
                    if success {
                        self.pendingCloudFallbackText = nil
                    } else if let text = self.pendingCloudFallbackText {
                        debugLog(
                            "OpenAI TTS playback finished unsuccessfully; falling back to local voice",
                            category: "Speech"
                        )
                        self.pendingCloudFallbackText = nil
                        self.speakLocal(text)
                    }
                }
            },
            onDecodeError: { [weak self] in
                guard let self else { return }
                DispatchQueue.main.async {
                    self.isSpeaking = false
                    self.audioPlayer = nil
                    if let text = self.pendingCloudFallbackText {
                        debugLog("OpenAI TTS decode failed; falling back to local voice", category: "Speech")
                        self.pendingCloudFallbackText = nil
                        self.speakLocal(text)
                    }
                }
            }
        )
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
        // Ensure a clean audio graph before creating a new input tap.
        cleanupRecognition()
        audioEngine.reset()

        transcript = ""

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
            guard let recognitionRequest else { return }
            recognitionRequest.shouldReportPartialResults = true

            let inputNode = audioEngine.inputNode
            // Use the live hardware format by passing nil. This avoids stale format mismatches
            // when switching between playback and record routes.
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in
                guard buffer.frameLength > 0 else { return }
                recognitionRequest.append(buffer)
            }
            hasInputTap = true

            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            debugLog("Speech startListening audio setup failed: \(error.localizedDescription)", category: "Speech")
            cleanupRecognition()
            return
        }

        guard let recognitionRequest else {
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

        debugLog(
            "Speak requested (provider=\(ttsProvider.rawValue), voiceEnabled=\(voiceEnabled), textChars=\(text.count))",
            category: "Speech"
        )
        stopSpeaking()

        switch ttsProvider {
        case .local:
            debugLog("Routing speech to local synthesizer", category: "Speech")
            speakLocal(text)
        case .openAINeural:
            debugLog("Routing speech to OpenAI neural TTS", category: "Speech")
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
        if cloudSpeakTask != nil || audioPlayer != nil || synthesizer.isSpeaking || isSpeaking {
            debugLog(
                "Stop speaking requested (cloudTaskActive=\(cloudSpeakTask != nil), playerActive=\(audioPlayer != nil), localSpeaking=\(synthesizer.isSpeaking), wasSpeaking=\(isSpeaking))",
                category: "Speech"
            )
        }
        cloudSpeakTask?.cancel()
        cloudSpeakTask = nil
        pendingCloudFallbackText = nil

        audioPlayer?.stop()
        audioPlayer = nil

        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        isSpeaking = false
    }

    private func speakWithOpenAI(_ text: String) async {
        pendingCloudFallbackText = text
        let cloudInput = trimmedCloudTTSInput(from: text)

        guard let rawKey = KeychainHelper.loadString(key: .openaiAPIKey) else {
            debugLog("OpenAI TTS key missing; falling back to local voice", category: "Speech")
            pendingCloudFallbackText = nil
            speakLocal(text)
            return
        }
        let apiKey = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            debugLog("OpenAI TTS key empty; falling back to local voice", category: "Speech")
            pendingCloudFallbackText = nil
            speakLocal(text)
            return
        }

        guard let url = URL(string: "https://api.openai.com/v1/audio/speech") else {
            pendingCloudFallbackText = nil
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
            "input": cloudInput,
            "response_format": "mp3",
        ]
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            debugLog(
                "OpenAI TTS request started (voice=\(openAICloudVoice), inputChars=\(cloudInput.count), timeout=\(Int(openAITTSTimeoutSeconds))s)",
                category: "Speech"
            )
            let startedAt = Date()
            let (data, response) = try await dataForOpenAITTS(request, timeoutSeconds: openAITTSTimeoutSeconds)
            if Task.isCancelled {
                debugLog("OpenAI TTS task cancelled after HTTP response", category: "Speech")
                return
            }
            let elapsedMS = Int(Date().timeIntervalSince(startedAt) * 1000)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if let http = response as? HTTPURLResponse {
                let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? "unknown"
                let requestID = http.value(forHTTPHeaderField: "x-request-id") ?? "n/a"
                debugLog(
                    "OpenAI TTS response HTTP \(status) in \(elapsedMS)ms (bytes=\(data.count), contentType=\(contentType), requestID=\(requestID))",
                    category: "Speech"
                )
            } else {
                debugLog(
                    "OpenAI TTS response non-HTTP in \(elapsedMS)ms (bytes=\(data.count))",
                    category: "Speech"
                )
            }
            guard (200..<300).contains(status) else {
                let bodyPreview = String(data: data.prefix(400), encoding: .utf8)?
                    .replacingOccurrences(of: "\n", with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    ?? "<non-utf8 body>"
                debugLog(
                    "OpenAI TTS failed HTTP \(status) bodyPreview=\(bodyPreview); falling back to local voice",
                    category: "Speech"
                )
                pendingCloudFallbackText = nil
                speakLocal(text)
                return
            }

            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.duckOthers])
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            debugLog("OpenAI TTS audio session configured for playback", category: "Speech")

            let player = try AVAudioPlayer(data: data)
            player.delegate = playerDelegate
            audioPlayer = player
            player.prepareToPlay()
            debugLog(
                "OpenAI TTS player prepared (duration=\(String(format: "%.2f", player.duration))s, channels=\(player.numberOfChannels), rate=\(player.rate))",
                category: "Speech"
            )
            isSpeaking = player.play()
            if !isSpeaking {
                debugLog("OpenAI TTS audio playback failed; falling back to local voice", category: "Speech")
                pendingCloudFallbackText = nil
                speakLocal(text)
            } else {
                debugLog("OpenAI TTS playback started", category: "Speech")
            }
        } catch {
            if isTimeoutError(error), cloudInput.count > openAITTSRetryMaxCharacters {
                debugLog(
                    "OpenAI TTS timed out; retrying once with shorter input (\(openAITTSRetryMaxCharacters) chars)",
                    category: "Speech"
                )
                await retryOpenAITTSWithShorterInput(
                    originalText: text,
                    apiKey: apiKey,
                    voice: openAICloudVoice,
                    input: String(cloudInput.prefix(openAITTSRetryMaxCharacters))
                )
                return
            }

            let nsError = error as NSError
            debugLog(
                "OpenAI TTS error domain=\(nsError.domain) code=\(nsError.code) description=\(error.localizedDescription); falling back to local voice",
                category: "Speech"
            )
            if !Task.isCancelled {
                pendingCloudFallbackText = nil
                speakLocal(text)
            } else {
                debugLog("OpenAI TTS task cancelled during error handling", category: "Speech")
            }
        }
    }

    private func trimmedCloudTTSInput(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > openAITTSMaxCharacters else { return trimmed }
        let prefix = String(trimmed.prefix(openAITTSMaxCharacters))
        debugLog(
            "OpenAI TTS input truncated from \(trimmed.count) to \(prefix.count) chars to reduce latency",
            category: "Speech"
        )
        return prefix
    }

    private func dataForOpenAITTS(_ request: URLRequest, timeoutSeconds: TimeInterval) async throws -> (Data, URLResponse) {
        try await withThrowingTaskGroup(of: (Data, URLResponse).self) { group in
            group.addTask {
                try await URLSession.shared.data(for: request)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                throw URLError(.timedOut)
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
    }

    private func retryOpenAITTSWithShorterInput(
        originalText: String,
        apiKey: String,
        voice: String,
        input: String
    ) async {
        guard let url = URL(string: "https://api.openai.com/v1/audio/speech") else {
            pendingCloudFallbackText = nil
            speakLocal(originalText)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = openAITTSTimeoutSeconds

        let body: [String: Any] = [
            "model": "gpt-4o-mini-tts",
            "voice": voice,
            "input": input,
            "response_format": "mp3",
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let startedAt = Date()
            let (data, response) = try await dataForOpenAITTS(request, timeoutSeconds: openAITTSTimeoutSeconds)
            if Task.isCancelled { return }
            let elapsedMS = Int(Date().timeIntervalSince(startedAt) * 1000)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            debugLog(
                "OpenAI TTS retry response HTTP \(status) in \(elapsedMS)ms (bytes=\(data.count), inputChars=\(input.count))",
                category: "Speech"
            )
            guard (200..<300).contains(status) else {
                pendingCloudFallbackText = nil
                speakLocal(originalText)
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
                pendingCloudFallbackText = nil
                speakLocal(originalText)
            } else {
                debugLog("OpenAI TTS retry playback started", category: "Speech")
            }
        } catch {
            let nsError = error as NSError
            debugLog(
                "OpenAI TTS retry failed domain=\(nsError.domain) code=\(nsError.code) description=\(error.localizedDescription); falling back to local voice",
                category: "Speech"
            )
            if !Task.isCancelled {
                pendingCloudFallbackText = nil
                speakLocal(originalText)
            }
        }
    }

    private func isTimeoutError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == URLError.timedOut.rawValue {
            return true
        }
        if let urlError = error as? URLError, urlError.code == .timedOut {
            return true
        }
        return false
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
    let onFinish: (Bool) -> Void
    let onDecodeError: () -> Void

    init(onFinish: @escaping (Bool) -> Void, onDecodeError: @escaping () -> Void) {
        self.onFinish = onFinish
        self.onDecodeError = onDecodeError
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        debugLog("OpenAI TTS playback finished (success=\(flag))", category: "Speech")
        onFinish(flag)
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        if let error {
            let nsError = error as NSError
            debugLog(
                "OpenAI TTS decode error domain=\(nsError.domain) code=\(nsError.code) description=\(error.localizedDescription)",
                category: "Speech"
            )
        } else {
            debugLog("OpenAI TTS decode error occurred (no error payload)", category: "Speech")
        }
        onDecodeError()
    }
}
