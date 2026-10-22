import Foundation
import Combine
import Speech
import AVFoundation

// MARK: - Diagnostics (temporary): remembers the last steps so a freeze can be located

nonisolated enum Breadcrumb {
    private static let key = "kitty.breadcrumbs"

    static func log(_ text: String) {
        print("KITTY", text)
        let time = Date().formatted(date: .omitted, time: .standard)
        var lines = UserDefaults.standard.stringArray(forKey: key) ?? []
        lines.append("\(time)  \(text)")
        UserDefaults.standard.set(Array(lines.suffix(40)), forKey: key)
    }

    static var lines: [String] { UserDefaults.standard.stringArray(forKey: key) ?? [] }
    static func clear() { UserDefaults.standard.removeObject(forKey: key) }
}

// MARK: - Spoken words (per-word confidence and timing)

/// One recognised word with what the recogniser knows about it.
/// Confidence is 0...1; it is often 0 on partial results, so treat 0 as "unknown".
nonisolated struct SpokenWord: Equatable, Sendable {
    var text: String
    var confidence: Float
    var timestamp: TimeInterval
    var duration: TimeInterval
    var alternatives: [String] = []

    init(text: String, confidence: Float = 0, timestamp: TimeInterval = 0,
         duration: TimeInterval = 0, alternatives: [String] = []) {
        self.text = text
        self.confidence = confidence
        self.timestamp = timestamp
        self.duration = duration
        self.alternatives = alternatives
    }
}

/// Phase 0 spike: what does SFSpeechRecognizer actually report for confidence?
/// Collects stats per session and prints one summary line when the session ends.
/// Read the "KITTY spike" lines in the console to decide how read-back is triggered.
nonisolated struct ConfidenceSpike {
    var onDevice = false
    var partials = 0
    var partialsWithConfidence = 0
    var partialWords = 0
    var partialWordsWithConfidence = 0
    var finalWords = 0
    var finalWordsWithConfidence = 0
    var finalLowConfidence = 0        // 0 < confidence < 0.5
    var finalWithAlternatives = 0
    var lastLogged = Date.distantPast

    mutating func record(_ words: [SpokenWord], isFinal: Bool) {
        let withConf = words.filter { $0.confidence > 0 }.count
        if isFinal {
            finalWords += words.count
            finalWordsWithConfidence += withConf
            finalLowConfidence += words.filter { $0.confidence > 0 && $0.confidence < 0.5 }.count
            finalWithAlternatives += words.filter { !$0.alternatives.isEmpty }.count
        } else {
            partials += 1
            if withConf > 0 { partialsWithConfidence += 1 }
            partialWords += words.count
            partialWordsWithConfidence += withConf
        }
    }

    var summary: String {
        "spike(\(onDevice ? "on-device" : "server")): partials \(partialsWithConfidence)/\(partials) with confidence, "
        + "words \(partialWordsWithConfidence)/\(partialWords); final words \(finalWordsWithConfidence)/\(finalWords) with confidence, "
        + "\(finalLowConfidence) low, \(finalWithAlternatives) with alternatives"
    }
}

// MARK: - Speech to text

@MainActor
final class SpeechRecognizer: ObservableObject {
    @Published private(set) var transcript = ""
    @Published private(set) var isRecording = false
    @Published var errorMessage: String?

    /// The last start-up failure cannot be fixed by trying again (permission off, recogniser unavailable).
    private(set) var failureIsPermanent = false

    /// When true, listening stops by itself after a pause in speech
    /// (used by hands-free conversation mode).
    var autoStopOnSilence = false

    /// Conversation mode: adds punctuation and never ends by itself on a pause.
    /// The owner decides when you have finished (see VoiceConversation).
    var continuous = false

    /// For the always-on "Hey Kitty" listener: recognise on the device when supported, and don't duck music.
    var lightweight = false

    /// Listening while Kitty is talking (hands-free "stop"): a voice-chat session with echo cancellation, so she mostly does not
    /// hear herself, and a session that is not shut off if the recogniser ends while she is still speaking.
    var bargeIn = false

    /// With `lightweight`: try on-device recognition first. Turned off for good if it fails to start.
    var preferOnDevice = true

    /// Called once per listening session with the final transcript (may be empty).
    var onFinished: ((String) -> Void)?

    /// Called with the live transcript as you speak (and with "" when a session starts).
    var onPartial: ((String) -> Void)?

    /// Words of the latest result (partial or final), with confidence and timing.
    private(set) var words: [SpokenWord] = []

    private var spike = ConfidenceSpike()

    /// Asked for at the start of every recognition session, so names added a moment ago are expected right away.
    var vocabulary: (@MainActor () -> [String])?

    /// Created again at each start so the English (India) setting takes effect on the next listen.
    private var recognizer = SpeechLocalePreference.makeRecognizer()
    private let capture = AudioCapture()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var timerTask: Task<Void, Never>?
    private var delivered = false
    private var sessionID = 0   // ignores late callbacks from an earlier session

    func toggle() async {
        if isRecording { stop() } else { await start() }
    }

    func start() async {
        guard !isRecording else { return }
        errorMessage = nil
        failureIsPermanent = false
        transcript = ""
        words = []
        spike = ConfidenceSpike()
        onPartial?("")
        delivered = false
        sessionID += 1
        let id = sessionID

        Breadcrumb.log("1 start: checking recognizer")
        recognizer = SpeechLocalePreference.makeRecognizer()
        guard let recognizer, recognizer.isAvailable else {
            errorMessage = "Speech recognition isn't available right now. Check your internet connection and try again."
            failureIsPermanent = true
            Breadcrumb.log("start failed: recogniser unavailable")
            return
        }
        Breadcrumb.log("2 asking for speech permission")
        guard await Self.speechAuthorized() else {
            errorMessage = "Speech Recognition is off for Kitty. Turn it on in Settings > Kitty."
            failureIsPermanent = true
            Breadcrumb.log("start failed: speech permission off")
            return
        }
        Breadcrumb.log("3 asking for microphone permission")
        guard await AVAudioApplication.requestRecordPermission() else {
            errorMessage = "Microphone is off for Kitty. Turn it on in Settings > Kitty."
            failureIsPermanent = true
            Breadcrumb.log("start failed: microphone permission off")
            return
        }

        do {
            // Off the main thread: activating the session on main can freeze the UI.
            Breadcrumb.log("4 configuring audio session")
            if bargeIn {
                try await AudioSessionControl.configure(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth])
            } else if lightweight {
                // "Mix with others" is not allowed with the plain record category, so use play-and-record.
                // (Asking for an invalid combination fails, and the listener would never start.)
                try await AudioSessionControl.configure(.playAndRecord, mode: .default, options: [.mixWithOthers])
            } else {
                try await AudioSessionControl.configure(.record, mode: .measurement, options: .duckOthers)
            }
            guard sessionID == id else { return }   // cancelled while waiting

            let request = makeRequest(for: recognizer)

            // Mic setup runs off the main thread so the UI never freezes.
            Breadcrumb.log("5 starting microphone")
            try await capture.start(feeding: request, voiceProcessing: bargeIn)
            Breadcrumb.log("6 microphone running")
            guard sessionID == id else { capture.stop(); return }   // cancelled while starting

            beginTask(recognizer: recognizer, request: request, id: id)
            isRecording = true
            Breadcrumb.log("7 listening")
            if autoStopOnSilence { armTimer(seconds: 8) }   // give up if nobody speaks
        } catch {
            errorMessage = "Couldn't start listening: \(error.localizedDescription)"
            Breadcrumb.log("start failed: \(error.localizedDescription) [\(String(describing: type(of: error)))]")
            cleanup()
        }
    }

    private func makeRequest(for recognizer: SFSpeechRecognizer) -> SFSpeechAudioBufferRecognitionRequest {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.contextualStrings = vocabulary?() ?? []
        if continuous {
            request.addsPunctuation = true
            request.taskHint = .dictation
        }
        if (lightweight && preferOnDevice || bargeIn), recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        self.request = request
        spike.onDevice = request.requiresOnDeviceRecognition
        return request
    }

    private func beginTask(recognizer: SFSpeechRecognizer, request: SFSpeechAudioBufferRecognitionRequest, id: Int) {
        task = Self.startTask(recognizer: recognizer, request: request) { [weak self] text, words, isFinal, done in
            guard let self else { return }
            Task { @MainActor in
                guard self.sessionID == id else { return }
                if let text {
                    self.words = words
                    self.spike.record(words, isFinal: isFinal)
                    self.transcript = text
                    self.onPartial?(text)
                    if self.autoStopOnSilence && !text.isEmpty { self.armTimer(seconds: 1.6) }
                }
                if done { self.finish() }
            }
        }
    }

    /// Ends the current recognition and starts a fresh one on the microphone that is already running. The audio session and
    /// engine are not touched, so nothing can fail on the audio side and no speech is missed. False if the mic is not running.
    @discardableResult
    func restartRecognition() -> Bool {
        guard isRecording, let recognizer, recognizer.isAvailable else { return false }
        sessionID += 1
        let id = sessionID
        task?.cancel()
        task = nil
        request?.endAudio()
        transcript = ""
        words = []
        delivered = false
        let request = makeRequest(for: recognizer)
        capture.swap(to: request)
        beginTask(recognizer: recognizer, request: request, id: id)
        Breadcrumb.log("recognition restarted on the running mic")
        return true
    }

    /// A fresh audio engine for the next start (used by the last retry after a failure).
    func resetAudioEngine() { capture.recreateEngine() }

    func stop() {
        guard isRecording else { return }
        Breadcrumb.log("stop tapped")
        isRecording = false
        timerTask?.cancel()
        capture.stop()
        request?.endAudio()
        let id = sessionID
        // Safety net in case the recognizer never sends a final result.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            if self.sessionID == id { self.finish() }
        }
    }

    /// Abort without delivering a result.
    func cancel() {
        Breadcrumb.log("cancel")
        delivered = true
        sessionID += 1
        cleanup()
    }

    private func armTimer(seconds: Double) {
        timerTask?.cancel()
        timerTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self, self.isRecording else { return }
            self.stop()
        }
    }

    private func finish() {
        guard !delivered else { return }
        delivered = true
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        Breadcrumb.log(spike.summary)
        cleanup()
        onFinished?(text)
    }

    private func cleanup() {
        timerTask?.cancel()
        timerTask = nil
        capture.stop()
        task?.cancel()
        task = nil
        request = nil
        isRecording = false
        if !bargeIn { AudioSessionControl.deactivate() }      // the session is still needed for Kitty's voice
    }

    // Nonisolated so these system callbacks (which run on background queues)
    // don't inherit the main actor.
    nonisolated private static func speechAuthorized() async -> Bool {
        await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status == .authorized)
            }
        }
    }

    nonisolated private static func startTask(recognizer: SFSpeechRecognizer,
                                              request: SFSpeechAudioBufferRecognitionRequest,
                                              onUpdate: @escaping @Sendable (String?, [SpokenWord], Bool, Bool) -> Void) -> SFSpeechRecognitionTask {
        recognizer.recognitionTask(with: request) { result, error in
            let isFinal = result?.isFinal ?? false
            onUpdate(result?.bestTranscription.formattedString,
                     result.map { spokenWords(from: $0.bestTranscription) } ?? [],
                     isFinal,
                     isFinal || error != nil)
        }
    }

    /// Full-transcription view: every segment with confidence, timing and the recogniser's alternatives.
    nonisolated static func spokenWords(from transcription: SFTranscription) -> [SpokenWord] {
        transcription.segments.map { seg in
            SpokenWord(text: seg.substring, confidence: seg.confidence,
                       timestamp: seg.timestamp, duration: seg.duration,
                       alternatives: seg.alternativeSubstrings)
        }
    }
}

// MARK: - Microphone capture (all engine work happens on its own queue)

nonisolated enum CaptureError: LocalizedError {
    case noMic
    var errorDescription: String? { "The microphone isn't available right now." }
}

nonisolated final class AudioCapture: @unchecked Sendable {
    private var engine = AVAudioEngine()
    private let queue = DispatchQueue(label: "kitty.audiocapture")
    private var tapInstalled = false

    /// Where the microphone buffers go. It can be swapped while the engine keeps running (see `swap(to:)`).
    private let lock = NSLock()
    private var sink: SFSpeechAudioBufferRecognitionRequest?

    private func setSink(_ request: SFSpeechAudioBufferRecognitionRequest?) {
        lock.lock(); sink = request; lock.unlock()
    }

    private func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); let target = sink; lock.unlock()
        target?.append(buffer)
    }

    /// Point the running microphone at a new recognition request. No engine or session change.
    func swap(to request: SFSpeechAudioBufferRecognitionRequest) { setSink(request) }

    func start(feeding request: SFSpeechAudioBufferRecognitionRequest, voiceProcessing: Bool = false) async throws {
        setSink(request)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    Breadcrumb.log("  queue: touching input node")
                    let input = self.engine.inputNode
                    // Echo cancellation while Kitty speaks. Not every device or the simulator supports it: carry on without.
                    if input.isVoiceProcessingEnabled != voiceProcessing {
                        do { try input.setVoiceProcessingEnabled(voiceProcessing) }
                        catch { Breadcrumb.log("  queue: voice processing unavailable: \(error.localizedDescription)") }
                    }
                    let format = input.outputFormat(forBus: 0)
                    guard format.sampleRate > 0, format.channelCount > 0 else { throw CaptureError.noMic }
                    if self.tapInstalled {
                        input.removeTap(onBus: 0)
                        self.tapInstalled = false
                    }
                    input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                        self?.append(buffer)
                    }
                    self.tapInstalled = true
                    Breadcrumb.log("  queue: starting engine")
                    self.engine.prepare()
                    try self.engine.start()
                    Breadcrumb.log("  queue: engine started")
                    cont.resume()
                } catch {
                    Breadcrumb.log("  queue: engine failed: \(error.localizedDescription)")
                    cont.resume(throwing: error)
                }
            }
        }
    }

    /// Safe to call any time, even if nothing was started.
    func stop() {
        setSink(nil)
        queue.async {
            if self.engine.isRunning { self.engine.stop() }
            if self.tapInstalled {
                self.engine.inputNode.removeTap(onBus: 0)
                self.tapInstalled = false
            }
        }
    }

    /// A brand new engine for the next start, in case the old one is stuck after a route or session change.
    func recreateEngine() {
        queue.async {
            if self.engine.isRunning { self.engine.stop() }
            if self.tapInstalled {
                self.engine.inputNode.removeTap(onBus: 0)
                self.tapInstalled = false
            }
            self.engine = AVAudioEngine()
            Breadcrumb.log("  queue: audio engine recreated")
        }
    }
}

// MARK: - Audio session (always off the main thread)

nonisolated enum AudioSessionControl {
    private static let queue = DispatchQueue(label: "kitty.audiosession")

    static func configure(_ category: AVAudioSession.Category,
                          mode: AVAudioSession.Mode,
                          options: AVAudioSession.CategoryOptions = []) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    Breadcrumb.log("  queue: setting audio category")
                    let session = AVAudioSession.sharedInstance()
                    try session.setCategory(category, mode: mode, options: options)
                    Breadcrumb.log("  queue: activating audio session")
                    try session.setActive(true)
                    Breadcrumb.log("  queue: audio session active")
                    cont.resume()
                } catch {
                    Breadcrumb.log("  queue: audio session failed: \(error.localizedDescription)")
                    cont.resume(throwing: error)
                }
            }
        }
    }

    /// Fire-and-forget. Runs in order after any earlier configure call.
    static func deactivate() {
        queue.async {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
}

// MARK: - Text to speech

@MainActor
final class Speaker: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = Speaker()
    private static var current: Speaker?

    /// Stops speech only if Kitty has already spoken (never creates the synthesizer).
    static func stopIfActive() { current?.stop() }

    private let synthesizer = AVSpeechSynthesizer()
    private var continuation: CheckedContinuation<Void, Never>?
    private var generation = 0
    private var pending = 0

    private override init() {
        super.init()
        synthesizer.delegate = self
        Speaker.current = self
    }

    /// Speak and return immediately.
    func say(_ text: String) {
        Task { await speakAndWait(text) }
    }

    /// Speak and wait until Kitty has finished talking (or was stopped).
    /// `duplex`: the microphone is open at the same time (hands-free "stop"), so keep the voice-chat session.
    func speakAndWait(_ text: String, duplex: Bool = false) async {
        Breadcrumb.log("speak: begin")
        resolve()
        let g = generation
        if duplex {
            try? await AudioSessionControl.configure(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth])
        } else {
            try? await AudioSessionControl.configure(.playback, mode: .spokenAudio)
        }
        guard g == generation else { return }   // stopped while waiting
        Breadcrumb.log("speak: starting synthesizer")

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            continuation = cont
            // One utterance per sentence, with a small breath between them, sounds like a person reading, not a machine.
            let sentences = Self.sentences(of: Self.speakable(text))
            pending = max(sentences.count, 1)
            let voice = Self.bestVoice()
            for (i, sentence) in sentences.enumerated() {
                let utterance = AVSpeechUtterance(string: sentence)
                utterance.voice = voice
                utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.94          // a touch slower than the default
                utterance.pitchMultiplier = 1.03
                utterance.volume = 1
                utterance.preUtteranceDelay = i == 0 ? 0.08 : 0
                utterance.postUtteranceDelay = Self.pause(after: sentence)
                synthesizer.speak(utterance)
            }
            if sentences.isEmpty { pending = 0; resolve() }

            // Never hang the conversation if the delegate callback doesn't arrive.
            let words = max(text.split(separator: " ").count, 1)
            let limit = Double(words) * 0.6 + 4
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(limit))
                if self.generation == g, self.continuation != nil { self.resolve() }
            }
        }
    }

    func stop() {
        generation += 1
        synthesizer.stopSpeaking(at: .immediate)
        resolve()
    }

    private func resolve() {
        continuation?.resume()
        continuation = nil
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.pending -= 1
            if self.pending <= 0 { self.pending = 0; self.resolve() }       // only after the last sentence
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.pending = 0; self.resolve() }
    }

    // MARK: Sounding like a person

    /// The most natural voice installed for the language: Premium, then Enhanced, then a good standard one. The default
    /// "compact" voice is the one that sounds robotic. Download Premium or Enhanced voices in
    /// Settings > Accessibility > Spoken Content > Voices.
    static func bestVoice() -> AVSpeechSynthesisVoice? {
        let language = AVSpeechSynthesisVoice.currentLanguageCode()
        let prefix = String(language.prefix(2))
        let candidates = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix(prefix) }
        let liked = ["ava", "zoe", "evan", "nathan", "samantha", "allison", "susan", "tom", "serena", "daniel", "karen", "moira", "rishi", "veena"]
        func score(_ v: AVSpeechSynthesisVoice) -> Int {
            var n = 0
            switch v.quality {
            case .premium: n += 300
            case .enhanced: n += 200
            default: n += 0
            }
            if v.language == language { n += 40 }
            if let i = liked.firstIndex(where: { v.name.lowercased().contains($0) }) { n += 30 - i }
            if v.name.lowercased().contains("eloquence") || v.identifier.lowercased().contains("eloquence") { n -= 500 }   // the novelty voices
            if v.identifier.lowercased().contains("speech.synthesis.voice") { n -= 100 }                                  // old robot voices
            return n
        }
        return candidates.max { score($0) < score($1) } ?? AVSpeechSynthesisVoice(language: language)
    }

    /// Writes the reply the way it is said: no emoji, no brackets, no symbols read out loud.
    nonisolated static func speakable(_ text: String) -> String {
        var t = text
        t = t.replacingOccurrences(of: "\\([^)]*\\)", with: "", options: .regularExpression)       // "(Me)", "(2 days late)"
        t = String(t.unicodeScalars.filter { !($0.properties.isEmojiPresentation || $0.value == 0xFE0F) })
        for (a, b) in [(" — ", ", "), (" – ", ", "), ("—", ", "), (" & ", " and "), ("•", ","), ("·", ","), (";", ","), ("…", "."),
                       ("+", " plus "), ("%", " percent"), ("/", " or "), ("“", ""), ("”", ""), ("\"", "")] {
            t = t.replacingOccurrences(of: a, with: b)
        }
        t = t.replacingOccurrences(of: "\\bTasks: ", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: " ,", with: ",").replacingOccurrences(of: ",,", with: ",")
        t = t.replacingOccurrences(of: " .", with: ".").replacingOccurrences(of: " ?", with: "?").replacingOccurrences(of: " !", with: "!")
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// What Kitty says aloud for a reply. A list is read as it is. Only a very long one is cut at a natural break, with a
    /// note that the rest is on screen, so she never talks for minutes. A narrowing `hint` is always the last thing said.
    nonisolated static func spokenForm(of message: String, isList: Bool, hint: String? = nil, maxWords: Int = 140) -> String {
        guard isList else { return message }
        var body = message
        if let hint { body = body.replacingOccurrences(of: " " + hint, with: "") }
        let words = body.split(whereSeparator: { $0.isWhitespace })
        if words.count > maxWords {
            var cut = words.prefix(maxWords).joined(separator: " ")
            if let r = cut.range(of: "[,.;]", options: [.regularExpression, .backwards]),
               cut.distance(from: cut.startIndex, to: r.lowerBound) > cut.count * 6 / 10 {
                cut = String(cut[..<r.lowerBound])
            }
            body = cut + ". The rest are on the screen."
        }
        return [body, hint].compactMap { $0 }.joined(separator: " ")
    }

    nonisolated static func sentences(of text: String) -> [String] {
        var out: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: [.bySentences, .substringNotRequired]) { _, range, _, _ in
            let s = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty { out.append(s) }
        }
        return out.isEmpty && !text.isEmpty ? [text] : out
    }

    /// A question hangs a little longer than a statement, like a person waiting for an answer.
    nonisolated static func pause(after sentence: String) -> TimeInterval {
        if sentence.hasSuffix("?") { return 0.22 }
        if sentence.hasSuffix("!") { return 0.18 }
        return 0.16
    }
}
