import Foundation
import AVFoundation
import MoonshineVoice

// MARK: - The model on disk

nonisolated enum MoonshineModel {
    /// Folder name under the app's `Moonshine` resource folder. Run `sh Moonshine/fetch-models.sh` to download it.
    static let folderName = "medium-streaming-en"

    /// Where the model files are, or nil if they were not bundled (a fresh clone before running the fetch script).
    static var directory: URL? {
        var candidates: [URL] = []
        if let override = ProcessInfo.processInfo.environment["KITTY_MOONSHINE_MODEL"], !override.isEmpty {
            candidates.append(URL(fileURLWithPath: override))
        }
        if let base = Bundle.main.resourceURL {
            candidates.append(base.appendingPathComponent("Moonshine").appendingPathComponent(folderName))
        }
        return candidates.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("streaming_config.json").path) }
    }

    static var isAvailable: Bool { directory != nil }
}

nonisolated enum MoonshineSettings {
    static let boostKey = "kitty.moonshineBoost"
    /// How strongly key terms pull the decoder. 2.0 is the default; 3.0 helps brands more but costs a little on other words.
    static var boost: Double {
        get { (UserDefaults.standard.object(forKey: boostKey) as? Double) ?? 2.0 }
        set { UserDefaults.standard.set(newValue, forKey: boostKey) }
    }
}

// MARK: - The engine behind a small seam (so tests do not need the model)

/// One line of what the engine has heard. A line grows while it is the current one and is complete once the speaker pauses.
nonisolated struct TranscriptLineUpdate: Equatable, Sendable {
    var id: UInt64
    var text: String
    var isComplete: Bool
    var latencyMs: UInt32 = 0
}

nonisolated protocol EngineSession: AnyObject, Sendable {
    /// Mono Float samples at any sample rate. Runs inference when enough audio has arrived, so call it off the main thread.
    func add(_ samples: [Float], sampleRate: Int32) throws
    /// Process what is left, emit the final lines, and release the stream.
    func flushAndClose()
}

nonisolated protocol StreamingEngine: AnyObject, Sendable {
    func load(keyTerms: [String], boost: Double) throws
    func setKeyTerms(_ terms: [String]) throws
    func openSession(onLine: @escaping @Sendable (TranscriptLineUpdate) -> Void) throws -> EngineSession
    func unload()
}

/// The real engine: Moonshine Voice, medium streaming English.
nonisolated final class MoonshineEngine: StreamingEngine, @unchecked Sendable {
    private var transcriber: Transcriber?
    private let lock = NSLock()

    func load(keyTerms: [String], boost: Double) throws {
        lock.lock(); defer { lock.unlock() }
        if transcriber != nil { return }
        guard let dir = MoonshineModel.directory else {
            throw MoonshineError.custom(message: "The speech model is not in the app. Run Moonshine/fetch-models.sh and build again.", code: -1)
        }
        var options = [TranscriberOption(name: "keyterm_boost", value: String(boost))]
        if !keyTerms.isEmpty { options.append(TranscriberOption(name: "keyterms", value: keyTerms.joined(separator: ","))) }
        transcriber = try Transcriber(modelPath: dir.path, modelArch: .mediumStreaming, options: options)
    }

    func setKeyTerms(_ terms: [String]) throws {
        lock.lock(); let t = transcriber; lock.unlock()
        try t?.setKeyterms(terms)
    }

    func openSession(onLine: @escaping @Sendable (TranscriptLineUpdate) -> Void) throws -> EngineSession {
        lock.lock(); let t = transcriber; lock.unlock()
        guard let t else { throw MoonshineError.custom(message: "The speech model is not loaded.", code: -1) }
        let stream = try t.createStream(updateInterval: 0.5)
        stream.addListener { event in
            if event is TranscriptError { return }
            if event is LineSpeakersChanged { return }
            let line = event.line
            onLine(TranscriptLineUpdate(id: line.lineId, text: line.text,
                                        isComplete: event is LineCompleted || line.isComplete,
                                        latencyMs: line.lastTranscriptionLatencyMs))
        }
        try stream.start()
        return MoonshineEngineSession(stream: stream)
    }

    func unload() {
        lock.lock(); transcriber?.close(); transcriber = nil; lock.unlock()
    }
}

nonisolated final class MoonshineEngineSession: EngineSession, @unchecked Sendable {
    private let stream: MoonshineVoice.Stream
    init(stream: MoonshineVoice.Stream) { self.stream = stream }
    func add(_ samples: [Float], sampleRate: Int32) throws { try stream.addAudio(samples, sampleRate: sampleRate) }
    func flushAndClose() {
        try? stream.stop()
        stream.close()
    }
}

// MARK: - The microphone sink for Moonshine

/// How long the inference passes took in one session: logged at the end with the thermal state, for battery and heat checks.
nonisolated final class PassStats: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var total = 0.0
    private var worst = 0.0
    private var latencies: [UInt32] = []

    /// A call that took long enough to be an inference pass rather than just buffering.
    func record(milliseconds: Double) {
        guard milliseconds >= 25 else { return }
        lock.lock(); count += 1; total += milliseconds; worst = max(worst, milliseconds); lock.unlock()
    }

    func recordLatency(_ ms: UInt32) {
        guard ms > 0 else { return }
        lock.lock(); latencies.append(ms); lock.unlock()
    }

    var summary: String {
        lock.lock(); defer { lock.unlock() }
        let avg = count > 0 ? Int(total / Double(count)) : 0
        let lat = latencies.isEmpty ? 0 : Int(latencies.reduce(0) { $0 + Int($1) } / latencies.count)
        return "moonshine: \(count) passes, avg \(avg) ms, worst \(Int(worst)) ms, end-of-phrase latency avg \(lat) ms, thermal \(Self.thermalName)"
    }

    static var thermalName: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
}

/// Takes the microphone buffers on the audio thread, copies them to mono, and hands them to the engine on its own queue.
nonisolated final class MoonshineSink: AudioSink, @unchecked Sendable {
    private let session: EngineSession
    private let queue: DispatchQueue
    private let stats: PassStats
    private let lock = NSLock()
    private var closed = false
    private var reportedError = false

    init(session: EngineSession, queue: DispatchQueue, stats: PassStats) {
        self.session = session
        self.queue = queue
        self.stats = stats
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); let isClosed = closed; lock.unlock()
        guard !isClosed else { return }
        let samples = MonoAudio.samples(from: buffer)
        guard !samples.isEmpty else { return }
        let rate = Int32(buffer.format.sampleRate.rounded())
        feed(samples, sampleRate: rate)
    }

    /// The engine queue does the work, never the audio thread.
    func feed(_ samples: [Float], sampleRate: Int32) {
        queue.async { [self] in
            lock.lock(); let isClosed = closed; lock.unlock()
            guard !isClosed else { return }
            let start = DispatchTime.now().uptimeNanoseconds
            do { try session.add(samples, sampleRate: sampleRate) }
            catch {
                lock.lock(); let first = !reportedError; reportedError = true; lock.unlock()
                if first { Breadcrumb.log("moonshine add failed: \(error.localizedDescription)") }
            }
            stats.record(milliseconds: Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        }
    }

    /// Swapped out of the capture: nothing more is added.
    func finish() {}

    /// Stop taking audio, then process what is left and release the stream on the engine queue.
    func close(then completion: (@Sendable () -> Void)? = nil) {
        lock.lock(); closed = true; lock.unlock()
        queue.async { [session] in
            session.flushAndClose()
            completion?()
        }
    }
}

// MARK: - The recogniser

/// Live speech to text with Moonshine Streaming: partials as you speak, punctuation and capitals, key terms for names and
/// brands. All inference runs on its own queue; only published values and callbacks are on the main actor.
@MainActor
final class MoonshineRecognizer: TurnRecognizer {
    private(set) var transcript = ""
    private(set) var words: [SpokenWord] = []          // Moonshine reports no per-word confidence here; unknown is empty
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
    private let queue = DispatchQueue(label: "kitty.moonshine", qos: .userInitiated)
    private let stopListener = AppleStopListener()
    private var sink: MoonshineSink?
    private var stats = PassStats()
    private var loaded = false
    private var sessionID = 0
    private var delivered = false
    private var lines: [(id: UInt64, text: String, complete: Bool)] = []
    private var unloadTask: Task<Void, Never>?

    init(engine: StreamingEngine = MoonshineEngine(), capture: AudioCapture = AudioCapture()) {
        self.engine = engine
        self.capture = capture
    }

    // MARK: Model

    /// Loads the model off the main thread (a second or two). Safe to call early and more than once.
    func prepare() async {
        unloadTask?.cancel()
        guard !loaded else { return }
        let terms = keyTerms()
        let engine = engine
        let boost = MoonshineSettings.boost
        let started = Date()
        let error: String? = await withCheckedContinuation { cont in
            queue.async {
                do { try engine.load(keyTerms: terms, boost: boost); cont.resume(returning: nil) }
                catch { cont.resume(returning: error.localizedDescription) }
            }
        }
        if let error {
            modelLoadFailed = true
            Breadcrumb.log("moonshine model failed to load: \(error)")
            errorMessage = "Couldn't load the speech model."
            failureIsPermanent = true
        } else {
            loaded = true
            modelLoadFailed = false
            Breadcrumb.log("moonshine model loaded in \(Int(Date().timeIntervalSince(started) * 1000)) ms (\(terms.count) key terms, boost \(MoonshineSettings.boost))")
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
            Breadcrumb.log("moonshine model unloaded")
        }
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
        Breadcrumb.log("m1 start: moonshine")

        guard await AVAudioApplication.requestRecordPermission() else {
            errorMessage = "Microphone is off for Kitty. Turn it on in Settings > Kitty."
            failureIsPermanent = true
            Breadcrumb.log("start failed: microphone permission off")
            return
        }
        await prepare()
        guard sessionID == id else { return }
        guard loaded else { return }               // prepare() has set the error

        do {
            Breadcrumb.log("m2 configuring audio session")
            if bargeIn {
                try await AudioSessionControl.configure(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetooth])
            } else {
                try await AudioSessionControl.configure(.record, mode: .measurement, options: .duckOthers)
            }
            guard sessionID == id else { return }
            refreshKeyTerms()
            let newSink = try openSink(id: id)
            Breadcrumb.log("m3 starting microphone")
            try await capture.start(feeding: newSink, voiceProcessing: bargeIn)
            guard sessionID == id else { capture.stop(); closeSink(); return }
            isRecording = true
            Breadcrumb.log("m4 listening (moonshine)")
        } catch {
            errorMessage = "Couldn't start listening: \(error.localizedDescription)"
            Breadcrumb.log("start failed: \(error.localizedDescription) [\(String(describing: type(of: error)))]")
            cleanup()
        }
    }

    /// The names added a minute ago should be expected from the next turn on.
    private func refreshKeyTerms() {
        let terms = keyTerms()
        let engine = engine
        queue.async { try? engine.setKeyTerms(terms) }
    }

    private func openSink(id: Int) throws -> MoonshineSink {
        stats = PassStats()
        let stats = stats
        let session = try engine.openSession { [weak self] update in
            stats.recordLatency(update.latencyMs)
            // In order, on the main actor: a late line of an old session is dropped by the session check.
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.received(update, session: id) } }
        }
        let newSink = MoonshineSink(session: session, queue: queue, stats: stats)
        sink = newSink
        return newSink
    }

    private func closeSink(then completion: (@Sendable () -> Void)? = nil) {
        guard let old = sink else { completion?(); return }
        sink = nil
        Breadcrumb.log(stats.summary)
        old.close(then: completion)
    }

    /// One line event from the engine: update the transcript and tell the conversation.
    func received(_ update: TranscriptLineUpdate, session id: Int) {
        guard id == sessionID else { return }
        if let i = lines.firstIndex(where: { $0.id == update.id }) {
            lines[i].text = update.text
            lines[i].complete = lines[i].complete || update.isComplete
        } else {
            lines.append((update.id, update.text, update.isComplete))
        }
        let text = Self.join(lines.map(\.text))
        guard text != transcript else { return }
        transcript = text
        onPartial?(text)
    }

    nonisolated static func join(_ parts: [String]) -> String {
        parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// A fresh recognition on the microphone that is already running. Also brings Moonshine back after a stop-listen.
    @discardableResult
    func restartRecognition() -> Bool {
        guard isRecording else { return false }
        sessionID += 1
        let id = sessionID
        stopListener.stop()
        closeSink()
        transcript = ""
        words = []
        lines = []
        delivered = false
        refreshKeyTerms()
        guard let newSink = try? openSink(id: id) else {
            Breadcrumb.log("moonshine restart: could not open a stream")
            return false
        }
        capture.swap(to: newSink)
        Breadcrumb.log("moonshine recognition restarted on the running mic")
        return true
    }

    /// While Kitty talks: hand the running microphone to Apple Speech, which is light and tuned for a short "stop".
    /// If Apple Speech is not allowed or not available, Moonshine keeps listening instead.
    @discardableResult
    func beginSpeakingListen() -> Bool {
        guard isRecording else { return false }
        sessionID += 1
        let id = sessionID
        closeSink()
        transcript = ""
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
                Breadcrumb.log("apple stop-listener unavailable: moonshine keeps listening")
                self.restartRecognition()
            }
        }
        return true
    }

    func resetAudioEngine() { capture.recreateEngine() }

    func stop() {
        guard isRecording else { return }
        Breadcrumb.log("stop tapped (moonshine)")
        isRecording = false
        stopListener.stop()
        capture.stop()
        let id = sessionID
        closeSink { DispatchQueue.main.async { MainActor.assumeIsolated { self.finishIfCurrent(id) } } }
    }

    private func finishIfCurrent(_ id: Int) {
        guard sessionID == id else { return }
        finish()
    }

    /// Abort without delivering a result.
    func cancel() {
        Breadcrumb.log("cancel (moonshine)")
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
        closeSink()
        isRecording = false
        if !bargeIn { AudioSessionControl.deactivate() }
    }
}
