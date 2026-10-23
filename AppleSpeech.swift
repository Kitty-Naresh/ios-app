import Foundation
import Combine
import Speech
import AVFoundation

// The only file that imports Speech: Apple's on-device and server recogniser.
// Kitty uses it for the "Hey Kitty" wake word, for hands-free "stop" while she talks, and as the fallback if the
// Moonshine model cannot load.

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
final class SpeechRecognizer: ObservableObject, TurnRecognizer {
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
            try await capture.start(feeding: AppleAudioSink(request), voiceProcessing: bargeIn)
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
        capture.swap(to: AppleAudioSink(request))
        beginTask(recognizer: recognizer, request: request, id: id)
        Breadcrumb.log("recognition restarted on the running mic")
        return true
    }

    /// Apple Speech is already listening through the whole of Kitty's turn, so the same fresh recognition does it.
    @discardableResult
    func beginSpeakingListen() -> Bool { restartRecognition() }

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


// MARK: - Apple Speech as an audio sink

nonisolated final class AppleAudioSink: AudioSink, @unchecked Sendable {
    let request: SFSpeechAudioBufferRecognitionRequest
    init(_ request: SFSpeechAudioBufferRecognitionRequest) { self.request = request }
    func append(_ buffer: AVAudioPCMBuffer) { request.append(buffer) }
    func finish() { request.endAudio() }
}

extension SpeechLocalePreference {
    static func makeRecognizer() -> SFSpeechRecognizer? {
        SFSpeechRecognizer(locale: locale)
            ?? SFSpeechRecognizer(locale: .current)
            ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    }
}

nonisolated enum AppleSpeechAccess {
    static func authorized() async -> Bool {
        if SFSpeechRecognizer.authorizationStatus() == .authorized { return true }
        return await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0 == .authorized) }
        }
    }
}

/// Listens on a microphone that is already running (owned by `AudioCapture`) for a stop word or real speech while Kitty talks.
/// Short, on-device where supported, with no punctuation: much cheaper than keeping the main recogniser busy on echo.
@MainActor
final class AppleStopListener {
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var token = 0
    private(set) var isRunning = false

    /// Starts feeding `capture` into a fresh Apple recognition. `onText` gets the cumulative text of this listen.
    /// False if Apple Speech is not available or not allowed, in which case the caller keeps its own recogniser on the mic.
    func start(on capture: AudioCapture, vocabulary: [String], onText: @escaping @MainActor (String) -> Void) async -> Bool {
        stop()
        guard await AppleSpeechAccess.authorized(),
              let recognizer = SpeechLocalePreference.makeRecognizer(), recognizer.isAvailable else { return false }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.contextualStrings = vocabulary
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        token += 1
        let mine = token
        self.request = request
        task = recognizer.recognitionTask(with: request) { [weak self] result, _ in
            guard let text = result?.bestTranscription.formattedString else { return }
            Task { @MainActor in
                guard let self, self.token == mine else { return }
                onText(text)
            }
        }
        capture.swap(to: AppleAudioSink(request))
        isRunning = true
        Breadcrumb.log("apple stop-listener on")
        return true
    }

    func stop() {
        token += 1
        task?.cancel()
        task = nil
        request?.endAudio()
        request = nil
        isRunning = false
    }
}
