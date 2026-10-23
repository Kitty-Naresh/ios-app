import Foundation
import whisper

// MARK: - The model on disk

nonisolated enum WhisperModel {
    /// Folders under the app's `Whisper` resource folder, best first. `sh Whisper/fetch-models.sh` fetches small.en;
    /// `sh Whisper/fetch-models.sh base` fetches the lighter one.
    static let folders = ["small.en", "base.en"]

    /// The model file (ggml-*.bin), or nil if none was bundled. The CoreML encoder sits next to it as `ggml-<size>-encoder.mlmodelc`.
    static var binaryURL: URL? {
        var directories: [URL] = []
        if let override = ProcessInfo.processInfo.environment["KITTY_WHISPER_MODEL"], !override.isEmpty {
            directories.append(URL(fileURLWithPath: override))
        }
        if let base = Bundle.main.resourceURL {
            for f in folders { directories.append(base.appendingPathComponent("Whisper").appendingPathComponent(f)) }
        }
        for dir in directories {
            let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            if let bin = files.sorted().first(where: { $0.hasPrefix("ggml-") && $0.hasSuffix(".bin") }) {
                return dir.appendingPathComponent(bin)
            }
        }
        return nil
    }

    static var isAvailable: Bool { binaryURL != nil }
}

nonisolated enum WhisperError: LocalizedError {
    case modelMissing
    case loadFailed

    var errorDescription: String? {
        switch self {
        case .modelMissing: return "The Whisper model is not in the app. Run Whisper/fetch-models.sh and build again."
        case .loadFailed: return "The Whisper model could not be loaded."
        }
    }
}

// MARK: - One pass of Whisper over a stretch of audio

nonisolated struct WhisperResult: Equatable, Sendable {
    var text: String
    var words: [SpokenWord]
    /// The highest "this is not speech" probability among the segments.
    var noSpeech: Float
    var meanConfidence: Float
}

/// The part of Whisper the session needs, so tests can stand in for the model.
nonisolated protocol WhisperTranscribing: AnyObject, Sendable {
    /// 16 kHz mono samples. Runs the model, so call it off the main thread. Nil if the model is not loaded.
    func transcribe(_ samples: [Float], prompt: String) -> WhisperResult?
}

// MARK: - The real engine: whisper.cpp with the CoreML encoder

nonisolated final class WhisperEngine: StreamingEngine, WhisperTranscribing, @unchecked Sendable {
    private var context: OpaquePointer?
    private var prompt = ""
    private let lock = NSLock()

    func load(keyTerms: [String], boost: Double) throws {
        lock.lock(); defer { lock.unlock() }
        prompt = WhisperPrompt.build(from: keyTerms)
        if context != nil { return }
        guard let url = WhisperModel.binaryURL else { throw WhisperError.modelMissing }
        var params = whisper_context_default_params()
        #if targetEnvironment(simulator)
        params.use_gpu = false
        #endif
        let modelPath = Self.skipCoreML ? Self.withoutEncoder(url) : url
        guard let ctx = whisper_init_from_file_with_params(modelPath.path, params) else { throw WhisperError.loadFailed }
        context = ctx
        // The first pass compiles the CoreML encoder, which takes a few seconds: do it now, on the loading queue.
        _ = run(ctx, samples: [Float](repeating: 0, count: 17_600), prompt: "")
    }

    func setKeyTerms(_ terms: [String]) throws {
        lock.lock(); prompt = WhisperPrompt.build(from: terms); lock.unlock()
    }

    /// The CoreML encoder needs a real device: the simulator has no working Neural Engine path, so it runs the CPU encoder.
    /// `KITTY_WHISPER_NO_COREML=1` does the same on a device, to compare speed and heat.
    static var skipCoreML: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return ProcessInfo.processInfo.environment["KITTY_WHISPER_NO_COREML"] == "1"
        #endif
    }

    /// whisper.cpp looks for `<model>-encoder.mlmodelc` next to the model file. A link to the model in a folder of its own
    /// has no encoder beside it, so whisper.cpp falls back to the CPU encoder.
    static func withoutEncoder(_ model: URL) -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kitty-whisper-cpu", isDirectory: true)
        let link = dir.appendingPathComponent(model.lastPathComponent)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: link)
        do { try FileManager.default.createSymbolicLink(at: link, withDestinationURL: model); return link }
        catch { return model }
    }

    func openSession(onLine: @escaping @Sendable (TranscriptLineUpdate) -> Void) throws -> EngineSession {
        lock.lock(); let loaded = context != nil; let prompt = self.prompt; lock.unlock()
        guard loaded else { throw WhisperError.loadFailed }
        return WhisperSession(transcriber: self, prompt: prompt, onLine: onLine)
    }

    func unload() {
        lock.lock()
        if let ctx = context { whisper_free(ctx) }
        context = nil
        lock.unlock()
    }

    func transcribe(_ samples: [Float], prompt: String) -> WhisperResult? {
        lock.lock(); let ctx = context; lock.unlock()
        guard let ctx else { return nil }
        return run(ctx, samples: samples, prompt: prompt)
    }

    /// Whisper wants at least a second of audio, so a short stretch is padded with silence.
    private func run(_ ctx: OpaquePointer, samples input: [Float], prompt: String) -> WhisperResult? {
        var samples = input
        if samples.count < 17_600 { samples.append(contentsOf: [Float](repeating: 0, count: 17_600 - samples.count)) }

        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.n_threads = Int32(min(4, max(2, ProcessInfo.processInfo.activeProcessorCount - 2)))
        params.translate = false
        params.no_context = true              // every pass starts clean, so a pass never feeds on its own earlier text
        params.no_timestamps = true
        params.single_segment = samples.count <= 28 * 16_000
        params.print_special = false
        params.print_progress = false
        params.print_realtime = false
        params.print_timestamps = false
        params.suppress_blank = true
        params.suppress_nst = true
        params.temperature = 0
        params.temperature_inc = 0            // no re-decode at a higher temperature: it costs time and makes text jump
        params.detect_language = false

        let status: Int32 = "en".withCString { language in
            prompt.withCString { promptC in
                params.language = language
                params.initial_prompt = prompt.isEmpty ? nil : promptC
                return samples.withUnsafeBufferPointer { buf in
                    whisper_full(ctx, params, buf.baseAddress, Int32(buf.count))
                }
            }
        }
        guard status == 0 else { return nil }

        let eot = whisper_token_eot(ctx)
        var words: [SpokenWord] = []
        var current = ""
        var probabilities: [Float] = []
        var noSpeech: Float = 0
        func flush() {
            guard !current.isEmpty else { return }
            let mean = probabilities.isEmpty ? 0 : probabilities.reduce(0, +) / Float(probabilities.count)
            words.append(SpokenWord(text: current, confidence: mean))
            current = ""
            probabilities = []
        }
        for i in 0..<Int(whisper_full_n_segments(ctx)) {
            noSpeech = max(noSpeech, whisper_full_get_segment_no_speech_prob(ctx, Int32(i)))
            for j in 0..<Int(whisper_full_n_tokens(ctx, Int32(i))) {
                let data = whisper_full_get_token_data(ctx, Int32(i), Int32(j))
                if data.id >= eot { continue }               // special tokens: timestamps, language, end
                guard let c = whisper_full_get_token_text(ctx, Int32(i), Int32(j)) else { continue }
                let piece = String(cString: c)
                if piece.hasPrefix(" ") || current.isEmpty {
                    flush()
                    current = piece.trimmingCharacters(in: .whitespaces)
                } else {
                    current += piece
                }
                probabilities.append(data.p)
            }
        }
        flush()
        let all = words.map(\.confidence)
        let mean = all.isEmpty ? 0 : all.reduce(0, +) / Float(all.count)
        return WhisperResult(text: words.map(\.text).joined(separator: " "), words: words, noSpeech: noSpeech, meanConfidence: mean)
    }
}

// MARK: - A listening session: audio in, lines out

/// Whisper does not stream, so this makes it look live: while someone talks, the turn so far is transcribed again about every
/// 0.6 s of new audio, and when they stop (or the 60 s cap is hit) one last pass settles the line. Silence is never sent to the model.
/// Called on the engine queue only.
nonisolated final class WhisperSession: EngineSession, @unchecked Sendable {
    private let transcriber: WhisperTranscribing
    private let prompt: String
    private let onLine: @Sendable (TranscriptLineUpdate) -> Void
    private let passSamples: Int
    private var buffer: WhisperTurnBuffer
    private var resampler: StreamResampler?
    private var lineID: UInt64 = 0
    private var samplesSincePass = 0
    private var lastText = ""
    private var lastWords: [SpokenWord] = []
    private var closed = false
    private var lastPassSeconds = 0.0            // how long the last live pass took
    private var lastPassEnd = DispatchTime.now().uptimeNanoseconds

    init(transcriber: WhisperTranscribing, prompt: String, passInterval: Double = 0.6,
         config: WhisperTurnBuffer.Config = .init(), onLine: @escaping @Sendable (TranscriptLineUpdate) -> Void) {
        self.transcriber = transcriber
        self.prompt = prompt
        self.onLine = onLine
        self.passSamples = Int(passInterval * WhisperTurnBuffer.rate)
        self.buffer = WhisperTurnBuffer(config: config)
    }

    func add(_ samples: [Float], sampleRate: Int32) throws {
        guard !closed else { return }
        if resampler?.inputRate != Double(sampleRate) { resampler = StreamResampler(inputRate: Double(sampleRate)) }
        let mono = resampler?.process(samples) ?? samples
        let events = buffer.append(mono)
        for event in events {
            switch event {
            case .started:
                lineID += 1
                samplesSincePass = 0
                lastText = ""
                lastWords = []
            case .ended(let stretch, let voiced):
                if voiced { finalPass(stretch) }
                lastText = ""
                lastWords = []
            case .capped(let stretch):
                finalPass(stretch)
                lineID += 1
                samplesSincePass = 0
                lastText = ""
                lastWords = []
            }
        }
        guard buffer.inSpeech else { return }
        samplesSincePass += mono.count
        if samplesSincePass >= passSamples && buffer.seconds >= 0.5 && restedEnough() {
            samplesSincePass = 0
            partialPass(buffer.samples)
        }
    }

    func flushAndClose() {
        guard !closed else { return }
        let (stretch, voiced) = buffer.drain()
        if voiced { finalPass(stretch) }
        closed = true
    }

    // MARK: Passes

    private func cleaned(_ result: WhisperResult, seconds: Double) -> (text: String, words: [SpokenWord]) {
        let joined = result.text
        let text = WhisperText.clean(joined, voicedSeconds: seconds, noSpeech: result.noSpeech, meanConfidence: result.meanConfidence)
        return (text, text == joined ? result.words : [])
    }

    /// A slow phone must not run the model flat out: after a pass, wait half as long as it took before the next live one.
    /// A fast pass (a few hundred ms) makes this wait irrelevant next to the 0.6 s of new audio.
    private func restedEnough() -> Bool {
        let idle = Double(DispatchTime.now().uptimeNanoseconds - lastPassEnd) / 1_000_000_000
        return idle >= lastPassSeconds * 0.5
    }

    private func partialPass(_ stretch: [Float]) {
        let started = DispatchTime.now().uptimeNanoseconds
        defer {
            lastPassEnd = DispatchTime.now().uptimeNanoseconds
            lastPassSeconds = Double(lastPassEnd - started) / 1_000_000_000
        }
        guard let result = transcriber.transcribe(stretch, prompt: prompt) else { return }
        let (text, words) = cleaned(result, seconds: Double(stretch.count) / WhisperTurnBuffer.rate)
        guard !text.isEmpty, text != lastText else { return }
        lastText = text
        lastWords = words
        onLine(TranscriptLineUpdate(id: lineID, text: text, isComplete: false, words: words))
    }

    private func finalPass(_ stretch: [Float]) {
        let started = DispatchTime.now().uptimeNanoseconds
        let result = transcriber.transcribe(stretch, prompt: prompt)
        let ms = UInt32(min(Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000, Double(UInt32.max)))
        guard let result else {
            if !lastText.isEmpty { onLine(TranscriptLineUpdate(id: lineID, text: lastText, isComplete: true, latencyMs: ms, words: lastWords)) }
            return
        }
        let (text, words) = cleaned(result, seconds: Double(stretch.count) / WhisperTurnBuffer.rate)
        // An empty final over a non-empty partial means the partial was noise: the line is blanked and closed.
        guard !text.isEmpty || !lastText.isEmpty else { return }
        onLine(TranscriptLineUpdate(id: lineID, text: text, isComplete: true, latencyMs: ms, words: words))
    }
}
