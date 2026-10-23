import Foundation

/// Listens to the same microphone as Apple Speech, finds where each stretch of speech starts and stops, and has the accurate model
/// (large-v3-turbo) transcribe each stretch once it is over. It shows no live text of its own: while you talk there is only a cheap
/// energy detector running, and the model runs once per pause, on a queue of its own.
///
/// `add`, `reset` and `flushAndClose` are called on the engine queue only (the `AudioHopSink`'s queue).
nonisolated final class TurboSettler: EngineSession, @unchecked Sendable {
    enum Event: Equatable, Sendable {
        /// A stretch of speech is over (its place on the audio clock, in seconds). Its words are being transcribed.
        case phraseEnded(id: Int, start: Double, end: Double)
        /// The accurate model's text for that stretch. Empty means it was noise.
        case settled(id: Int, text: String, words: [SpokenWord], latencyMs: UInt32)
    }

    private let accurate: @Sendable () -> WhisperTranscribing?
    private let onEvent: @Sendable (Event) -> Void
    private let finalQueue: DispatchQueue
    private let finals = DispatchGroup()
    private let finalTimeout: Double
    private var buffer: WhisperTurnBuffer
    private var resampler: StreamResampler?
    private var nextID = 0
    private var closed = false

    private let lock = NSLock()
    private var _prompt: String
    private var generation = 0

    init(accurate: @escaping @Sendable () -> WhisperTranscribing?,
         prompt: String,
         config: WhisperTurnBuffer.Config = .init(),
         finalQueue: DispatchQueue = DispatchQueue(label: "kitty.whisper.final", qos: .userInitiated),
         finalTimeout: Double = 6,
         onEvent: @escaping @Sendable (Event) -> Void) {
        self.accurate = accurate
        self._prompt = prompt
        self.finalQueue = finalQueue
        self.finalTimeout = finalTimeout
        self.onEvent = onEvent
        self.buffer = WhisperTurnBuffer(config: config)
    }

    var prompt: String {
        get { lock.lock(); defer { lock.unlock() }; return _prompt }
        set { lock.lock(); _prompt = newValue; lock.unlock() }
    }

    func add(_ samples: [Float], sampleRate: Int32) throws {
        guard !closed else { return }
        if resampler?.inputRate != Double(sampleRate) { resampler = StreamResampler(inputRate: Double(sampleRate)) }
        let mono = resampler?.process(samples) ?? samples
        let events = buffer.append(mono)
        var ranges = buffer.takeRanges()[...]
        for event in events {
            switch event {
            case .started:
                break
            case .ended(let stretch, let voiced):
                let range = ranges.popFirst()
                if voiced, let range { settle(stretch, range: range) }
            case .capped(let stretch):
                if let range = ranges.popFirst() { settle(stretch, range: range) }
            }
        }
    }

    /// A new recognition started (Apple Speech was restarted): what is being collected or still being transcribed is not wanted.
    func reset() {
        lock.lock(); generation += 1; lock.unlock()
        buffer.reset()
    }

    /// The microphone was closed to deliver the result: settle the stretch being spoken, and wait (a few seconds at most) for the
    /// passes still running.
    func flushAndClose() {
        guard !closed else { return }
        let start = buffer.currentStart
        let (stretch, voiced) = buffer.drain()
        if voiced { settle(stretch, range: start..<(start + stretch.count)) }
        closed = true
        if finals.wait(timeout: .now() + finalTimeout) == .timedOut {
            Breadcrumb.log("whisper-turbo: a pass was still running after \(Int(finalTimeout)) s; Apple Speech's words stand for it")
        }
    }

    /// Not wanted (a restart or the conversation closed): stop without waiting for anything.
    func discard() {
        closed = true
        lock.lock(); generation += 1; lock.unlock()
    }

    // MARK: A stretch

    private func settle(_ stretch: [Float], range: Range<Int>) {
        nextID += 1
        let id = nextID
        let rate = WhisperTurnBuffer.rate
        onEvent(.phraseEnded(id: id, start: Double(range.lowerBound) / rate, end: Double(range.upperBound) / rate))
        guard let engine = accurate() else { return }       // not loaded (yet): Apple Speech's words stand
        lock.lock(); let gen = generation; let prompt = _prompt; lock.unlock()
        let seconds = Double(stretch.count) / rate
        let onEvent = onEvent
        finals.enter()
        finalQueue.async { [self] in
            defer { finals.leave() }
            let started = DispatchTime.now().uptimeNanoseconds
            guard let result = engine.transcribe(stretch, prompt: prompt) else { return }     // failed: Apple Speech's words stand
            let ms = UInt32(min(Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000, Double(UInt32.max)))
            lock.lock(); let current = generation == gen; lock.unlock()
            guard current else { return }
            let joined = result.text
            let text = WhisperText.clean(joined, voicedSeconds: seconds, noSpeech: result.noSpeech, meanConfidence: result.meanConfidence)
            onEvent(.settled(id: id, text: text, words: text == joined ? result.words : [], latencyMs: ms))
        }
    }
}
