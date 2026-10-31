import Foundation
import AVFoundation

/// Live speech to text with Whisper (small.en for the live text, CoreML encoder on a real device; with `accurate`, large-v3-turbo
/// settles each phrase when you pause): punctuation, capitals, and names and brands carried in the prompt. Whisper is not a streaming model, so `WhisperSession` re-transcribes the turn about every 0.6 s
/// while someone talks. All inference runs on its own queue; only published values and callbacks are on the main actor.
@MainActor
final class WhisperRecognizer: TurnRecognizer {
    private(set) var transcript = ""
    private(set) var words: [SpokenWord] = []
    private(set) var isRecording = false
    var errorMessage: String?
    private(set) var failureIsPermanent = false
    /// The model could not be loaded: the conversation switches to Apple Speech.
    private(set) var modelLoadFailed = false

    var continuous = false
    var bargeIn = false
    var vocabulary: (@MainActor () -> [String])?
    var onPartial: ((String) -> Void)?
    var onFinished: ((String) -> Void)?

    private let engine: StreamingEngine
    private let capture: AudioCapture
    private let queue = DispatchQueue(label: "kitty.whisper", qos: .userInitiated)
    private let stopListener = AppleStopListener()
    private var sink: AudioHopSink?                   // the hop from the audio thread to the engine queue
    private var stats = PassStats(label: "whisper")
    private var loaded = false
    private(set) var sessionID = 0
    private var delivered = false
    private var lines: [(id: UInt64, text: String, complete: Bool, words: [SpokenWord])] = []
    private var unloadTask: Task<Void, Never>?
    private var protectedNames: [String] = []
    /// The accurate model, when this recogniser is the hybrid. Nil for small.en alone.
    private let accurateModel: WhisperAccurate?
    var accurate: Bool { accurateModel != nil }

    init(engine: StreamingEngine = WhisperEngine(), capture: AudioCapture = AudioCapture(), accurate: WhisperAccurate? = nil) {
        self.engine = engine
        self.capture = capture
        self.accurateModel = accurate
        if let live = engine as? WhisperEngine, let accurate { live.accurateProvider = accurate.provider }
    }

    // MARK: Model

    /// Loads the model off the main thread (a few seconds the first time, while CoreML compiles). Safe to call more than once.
    func prepare() async {
        unloadTask?.cancel()
        guard !loaded else { return }
        let terms = keyTerms()
        let engine = engine
        let started = Date()
        let error: String? = await withCheckedContinuation { cont in
            queue.async {
                do { try engine.load(keyTerms: terms, boost: 0); cont.resume(returning: nil) }
                catch { cont.resume(returning: error.localizedDescription) }
            }
        }
        if let error {
            modelLoadFailed = true
            Breadcrumb.log("whisper model failed to load: \(error)")
            errorMessage = "Couldn't load the speech model."
            failureIsPermanent = true
        } else {
            loaded = true
            modelLoadFailed = false
            Breadcrumb.log("whisper model loaded in \(Int(Date().timeIntervalSince(started) * 1000)) ms (\(terms.count) prompt terms)")
        }
    }

    /// Frees the model's memory a little while after the conversation closes (reopening within that time is instant).
    func unloadSoon(after seconds: TimeInterval = 120) {
        unloadTask?.cancel()
        unloadTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self, !self.isRecording else { return }
            self.loaded = false
            let engine = self.engine
            self.queue.async { engine.unload() }
            Breadcrumb.log("whisper model unloaded")
        }
        accurateModel?.unloadSoon()
    }

    private func keyTerms() -> [String] { KeyTerms.build(household: vocabulary?() ?? []) }

    // MARK: Listening

    func start() async {
        guard !isRecording else { return }
        errorMessage = nil
        failureIsPermanent = false
        transcript = ""
        words = []
        lines = []
        delivered = false
        onPartial?("")
        sessionID += 1
        let id = sessionID
        Breadcrumb.log("w1 start: whisper")

        guard await AVAudioApplication.requestRecordPermission() else {
            errorMessage = "Microphone is off for Kitty. Turn it on in Settings > Kitty."
            failureIsPermanent = true
            Breadcrumb.log("start failed: microphone permission off")
            return
        }
        accurateModel?.prepare(keyTerms: keyTerms())      // in the background: the first conversation never waits for it
        await prepare()
        guard sessionID == id else { return }
        guard loaded else { return }

        do {
            Breadcrumb.log("w2 configuring audio session")
            if bargeIn {
                try await AudioSessionControl.configure(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth])
            } else {
                try await AudioSessionControl.configure(.record, mode: .measurement, options: .duckOthers)
            }
            guard sessionID == id else { return }
            refreshKeyTerms()
            let newSink = try openSink(id: id)
            Breadcrumb.log("w3 starting microphone")
            try await capture.start(feeding: newSink, voiceProcessing: bargeIn)
            guard sessionID == id else { capture.stop(); closeSink(discard: true); return }
            isRecording = true
            Breadcrumb.log("w4 listening (whisper)")
        } catch {
            errorMessage = "Couldn't start listening: \(error.localizedDescription)"
            Breadcrumb.log("start failed: \(error.localizedDescription) [\(String(describing: type(of: error)))]")
            cleanup()
        }
    }

    /// The names added a minute ago should be in the prompt from the next turn on.
    private func refreshKeyTerms() {
        protectedNames = vocabulary?() ?? []
        let terms = KeyTerms.build(household: protectedNames)
        let engine = engine
        queue.async { try? engine.setKeyTerms(terms) }
    }

    private func openSink(id: Int) throws -> AudioHopSink {
        stats = PassStats(label: "whisper")
        let stats = stats
        let session = try engine.openSession { [weak self] update in
            stats.recordLatency(update.latencyMs)
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.received(update, session: id) } }
        }
        let newSink = AudioHopSink(session: session, queue: queue, stats: stats)
        sink = newSink
        return newSink
    }

    /// `discard`: nobody wants what is left (a restart or a cancel), so nothing is waited for. Without it, the last words are
    /// settled first, including any accurate pass still running.
    private func closeSink(discard: Bool = false, then completion: (@Sendable () -> Void)? = nil) {
        guard let old = sink else { completion?(); return }
        sink = nil
        Breadcrumb.log(stats.summary)
        old.close(discard: discard, then: completion)
    }

    /// One line from the engine: update the transcript and tell the conversation.
    func received(_ rawUpdate: TranscriptLineUpdate, session id: Int) {
        guard id == sessionID else { return }
        let update = rawUpdate
        if let i = lines.firstIndex(where: { $0.id == update.id }) {
            lines[i].text = update.text
            lines[i].words = update.words
            lines[i].complete = lines[i].complete || update.isComplete
        } else {
            lines.append((update.id, update.text, update.isComplete, update.words))
        }
        let text = TranscriptJoin.join(lines.map(\.text))
        words = lines.flatMap(\.words)
        guard text != transcript else { return }
        transcript = text
        onPartial?(text)
    }

    /// A fresh recognition on the microphone that is already running. Also brings Whisper back after a stop-listen.
    @discardableResult
    func restartRecognition() -> Bool {
        guard isRecording else { return false }
        sessionID += 1
        let id = sessionID
        stopListener.stop()
        closeSink(discard: true)
        transcript = ""
        words = []
        lines = []
        delivered = false
        refreshKeyTerms()
        guard let newSink = try? openSink(id: id) else {
            Breadcrumb.log("whisper restart: could not open a session")
            return false
        }
        capture.swap(to: newSink)
        Breadcrumb.log("whisper recognition restarted on the running mic")
        return true
    }

    /// While Kitty talks: hand the running microphone to Apple Speech, which is light and tuned for a short "stop".
    /// If Apple Speech is not allowed or not available, Whisper keeps listening instead.
    @discardableResult
    func beginSpeakingListen() -> Bool {
        guard isRecording else { return false }
        sessionID += 1
        let id = sessionID
        closeSink(discard: true)
        transcript = ""
        words = []
        lines = []
        capture.swap(to: nil)
        let terms = vocabulary?() ?? []
        Task { @MainActor [weak self] in
            guard let self else { return }
            let ok = await self.stopListener.start(on: self.capture, vocabulary: ["stop"] + terms) { [weak self] text in
                guard let self, self.sessionID == id else { return }
                self.transcript = text
                self.onPartial?(text)
            }
            guard self.sessionID == id, self.isRecording else { return }
            if !ok {
                Breadcrumb.log("apple stop-listener unavailable: whisper keeps listening")
                self.restartRecognition()
            }
        }
        return true
    }

    func resetAudioEngine() { capture.recreateEngine() }

    /// For tests: a listening session with no microphone and no model load, so lines can be fed in by hand.
    func beginWithoutAudio() throws {
        loaded = true
        sessionID += 1
        transcript = ""
        words = []
        lines = []
        delivered = false
        refreshKeyTerms()
        _ = try openSink(id: sessionID)
        isRecording = true
    }

    func stop() {
        guard isRecording else { return }
        Breadcrumb.log("stop tapped (whisper)")
        isRecording = false
        stopListener.stop()
        capture.stop()
        let id = sessionID
        // The last pass runs on the engine queue before this completes, so the final text is the settled one.
        closeSink { DispatchQueue.main.async { MainActor.assumeIsolated { self.finishIfCurrent(id) } } }
    }

    private func finishIfCurrent(_ id: Int) {
        guard sessionID == id else { return }
        finish()
    }

    /// Abort without delivering a result.
    func cancel() {
        Breadcrumb.log("cancel (whisper)")
        delivered = true
        sessionID += 1
        cleanup()
    }

    private func finish() {
        guard !delivered else { return }
        delivered = true
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        cleanup()
        onFinished?(text)
    }

    private func cleanup() {
        stopListener.stop()
        capture.stop()
        closeSink(discard: true)
        isRecording = false
        if !bargeIn { AudioSessionControl.deactivate() }
    }
}
