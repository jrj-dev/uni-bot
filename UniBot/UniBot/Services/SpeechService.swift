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
    private let openAITTSMaxAttempts = 4
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

    /// Requests microphone and speech-recognition permissions needed for push-to-talk.
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

    /// Starts a new speech-recognition session and begins streaming microphone audio.
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

    /// Stops the active recognition session and returns the final transcribed text.
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

    /// Tears down the current recognition request, task, and audio tap.
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

    /// Speaks a response using either OpenAI TTS or the local system voice.
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

    /// Speaks text with AVSpeechSynthesizer when cloud TTS is unavailable or disabled.
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

    /// Stops any in-flight speech playback and resets speaking state.
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

    /// Requests OpenAI TTS audio, retries transient failures, and plays the returned clip.
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

        do {
            let data = try await fetchOpenAITTSAudio(apiKey: apiKey, voice: openAICloudVoice, input: cloudInput)
            try playOpenAITTSAudio(data)
        } catch {
            if isTimeoutError(error), cloudInput.count > openAITTSRetryMaxCharacters {
                debugLog(
                    "OpenAI TTS timed out; retrying once with shorter input (\(openAITTSRetryMaxCharacters) chars)",
                    category: "Speech"
                )
                do {
                    let shortInput = String(cloudInput.prefix(openAITTSRetryMaxCharacters))
                    let data = try await fetchOpenAITTSAudio(apiKey: apiKey, voice: openAICloudVoice, input: shortInput)
                    try playOpenAITTSAudio(data)
                    return
                } catch {
                    let nsError = error as NSError
                    debugLog(
                        "OpenAI TTS short retry failed domain=\(nsError.domain) code=\(nsError.code) description=\(error.localizedDescription)",
                        category: "Speech"
                    )
                }
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

    /// Trims and bounds text before it is sent to the cloud TTS endpoint.
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

    /// Fetches synthesized speech audio from the OpenAI TTS API.
    private func fetchOpenAITTSAudio(apiKey: String, voice: String, input: String) async throws -> Data {
        guard let url = URL(string: "https://api.openai.com/v1/audio/speech") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = openAITTSTimeoutSeconds
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": "gpt-4o-mini-tts",
            "voice": voice,
            "input": input,
            "response_format": "mp3",
        ])

        var attempt = 1
        while true {
            debugLog(
                "OpenAI TTS request started (voice=\(voice), inputChars=\(input.count), timeout=\(Int(openAITTSTimeoutSeconds))s, attempt=\(attempt)/\(openAITTSMaxAttempts))",
                category: "Speech"
            )
            let startedAt = Date()
            do {
                let (data, response) = try await dataForOpenAITTS(request, timeoutSeconds: openAITTSTimeoutSeconds)
                if Task.isCancelled {
                    debugLog("OpenAI TTS task cancelled after HTTP response", category: "Speech")
                    throw CancellationError()
                }
                guard let http = response as? HTTPURLResponse else {
                    throw URLError(.badServerResponse)
                }

                let elapsedMS = Int(Date().timeIntervalSince(startedAt) * 1000)
                let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? "unknown"
                let requestID = http.value(forHTTPHeaderField: "x-request-id") ?? "n/a"
                debugLog(
                    "OpenAI TTS response HTTP \(http.statusCode) in \(elapsedMS)ms (bytes=\(data.count), contentType=\(contentType), requestID=\(requestID), attempt=\(attempt)/\(openAITTSMaxAttempts))",
                    category: "Speech"
                )

                if (200..<300).contains(http.statusCode) {
                    return data
                }

                if shouldRetryOpenAITTS(statusCode: http.statusCode), attempt < openAITTSMaxAttempts {
                    let delay = openAITTSRetryDelay(statusCode: http.statusCode, headers: http.allHeaderFields, attempt: attempt)
                    debugLog(
                        "OpenAI TTS throttled/transient HTTP \(http.statusCode); retrying in \(String(format: "%.2f", delay))s (attempt=\(attempt + 1)/\(openAITTSMaxAttempts))",
                        category: "Speech"
                    )
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    attempt += 1
                    continue
                }

                let bodyPreview = String(data: data.prefix(400), encoding: .utf8)?
                    .replacingOccurrences(of: "\n", with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    ?? "<non-utf8 body>"
                throw NSError(
                    domain: "OpenAITTSHTTP",
                    code: http.statusCode,
                    userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode) bodyPreview=\(bodyPreview)"]
                )
            } catch {
                if Task.isCancelled { throw error }
                if isRetryableOpenAITTSNetworkError(error), attempt < openAITTSMaxAttempts {
                    let delay = openAITTSRetryDelay(statusCode: nil, headers: [:], attempt: attempt)
                    let nsError = error as NSError
                    debugLog(
                        "OpenAI TTS network error domain=\(nsError.domain) code=\(nsError.code); retrying in \(String(format: "%.2f", delay))s (attempt=\(attempt + 1)/\(openAITTSMaxAttempts))",
                        category: "Speech"
                    )
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    attempt += 1
                    continue
                }
                throw error
            }
        }
    }

    /// Configures the audio player and starts playback of OpenAI TTS data.
    private func playOpenAITTSAudio(_ data: Data) throws {
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
        guard isSpeaking else {
            throw NSError(domain: "OpenAITTSPlayback", code: -1, userInfo: [NSLocalizedDescriptionKey: "AVAudioPlayer.play returned false"])
        }
        debugLog("OpenAI TTS playback started", category: "Speech")
    }

    /// Runs the OpenAI TTS request with an explicit timeout wrapper.
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

    /// Returns true when an error represents a timeout condition.
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

    /// Returns true when an OpenAI TTS HTTP status should be retried.
    private func shouldRetryOpenAITTS(statusCode: Int) -> Bool {
        statusCode == 429 || statusCode == 408 || statusCode == 500 || statusCode == 502 || statusCode == 503 || statusCode == 504
    }

    /// Calculates the backoff delay before retrying an OpenAI TTS request.
    private func openAITTSRetryDelay(statusCode: Int?, headers: [AnyHashable: Any], attempt: Int) -> TimeInterval {
        if statusCode == 429 {
            if let retryAfter = headerValue("Retry-After", headers: headers),
               let parsed = parseRetryAfterSeconds(retryAfter) {
                return min(max(parsed, 0.5), 30)
            }
            if let reset = headerValue("x-ratelimit-reset-requests", headers: headers),
               let parsed = parseResetDurationSeconds(reset) {
                return min(max(parsed, 0.5), 30)
            }
        }

        let base = min(pow(2.0, Double(attempt - 1)), 8.0)
        let jitter = Double.random(in: 0...0.35)
        return base + jitter
    }

    /// Looks up an HTTP header value case-insensitively.
    private func headerValue(_ key: String, headers: [AnyHashable: Any]) -> String? {
        for (headerKey, value) in headers {
            if String(describing: headerKey).caseInsensitiveCompare(key) == .orderedSame {
                return String(describing: value)
            }
        }
        return nil
    }

    /// Parses a Retry-After header value expressed in seconds.
    private func parseRetryAfterSeconds(_ value: String) -> TimeInterval? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let seconds = Double(trimmed) { return seconds }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
        guard let date = formatter.date(from: trimmed) else { return nil }
        return date.timeIntervalSinceNow
    }

    /// Parses a reset-duration header value expressed in seconds.
    private func parseResetDurationSeconds(_ value: String) -> TimeInterval? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let seconds = Double(trimmed) { return seconds }
        if trimmed.hasSuffix("ms"), let ms = Double(trimmed.dropLast(2)) { return ms / 1000.0 }
        if trimmed.hasSuffix("s"), let s = Double(trimmed.dropLast(1)) { return s }
        if trimmed.hasSuffix("m"), let m = Double(trimmed.dropLast(1)) { return m * 60 }
        return nil
    }

    /// Returns true when the OpenAI TTS network error is likely transient.
    private func isRetryableOpenAITTSNetworkError(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost, .dnsLookupFailed, .notConnectedToInternet:
            return true
        default:
            return false
        }
    }

    /// Returns the preferred local system voice for on-device speech fallback.
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

    /// Resets state after the local speech synthesizer finishes or is cancelled.
    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        onFinish()
    }
    /// Resets state after the local speech synthesizer finishes or is cancelled.
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

    /// Clears playback state after OpenAI TTS audio finishes.
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        debugLog("OpenAI TTS playback finished (success=\(flag))", category: "Speech")
        onFinish(flag)
    }

    /// Clears playback state when the audio player cannot decode TTS audio.
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
