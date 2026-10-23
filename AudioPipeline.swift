import Foundation
import AVFoundation

// The pieces every speech engine shares: the lines an engine reports, the seam tests use instead of a real model, and the hop
// from the microphone's audio thread to the engine's own queue.

/// One line of what the engine has heard. A line grows while it is the current one and is complete once the speaker pauses.
nonisolated struct TranscriptLineUpdate: Equatable, Sendable {
    var id: UInt64
    var text: String
    var isComplete: Bool
    var latencyMs: UInt32 = 0
    /// Per-word confidence where the engine has it.
    var words: [SpokenWord] = []
}

nonisolated protocol EngineSession: AnyObject, Sendable {
    /// Mono Float samples at any sample rate. Runs inference when enough audio has arrived, so call it off the main thread.
    func add(_ samples: [Float], sampleRate: Int32) throws
    /// Process what is left, emit the final lines, and release the stream.
    func flushAndClose()
    /// Release the stream without waiting for results nobody wants (a restart or a cancel). Defaults to `flushAndClose`.
    func discard()
}

extension EngineSession {
    func discard() { flushAndClose() }
}

nonisolated protocol StreamingEngine: AnyObject, Sendable {
    func load(keyTerms: [String], boost: Double) throws
    func setKeyTerms(_ terms: [String]) throws
    func openSession(onLine: @escaping @Sendable (TranscriptLineUpdate) -> Void) throws -> EngineSession
    func unload()
}

/// How long the inference passes took in one session: logged at the end with the thermal state, for battery and heat checks.
nonisolated final class PassStats: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var total = 0.0
    private var worst = 0.0
    private var latencies: [UInt32] = []
    private let label: String

    init(label: String = "whisper") { self.label = label }

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
        return "\(label): \(count) passes, avg \(avg) ms, worst \(Int(worst)) ms, end-of-phrase latency avg \(lat) ms, thermal \(Self.thermalName)"
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
nonisolated final class AudioHopSink: AudioSink, @unchecked Sendable {
    private let session: EngineSession
    private let queue: DispatchQueue
    private let stats: PassStats
    private let lock = NSLock()
    private var closed = false
    private var reportedError = false
    private var appended = 0.0

    /// Seconds of microphone audio that have arrived (not yet processed) since this sink was made: the audio clock.
    var secondsAppended: Double { lock.lock(); defer { lock.unlock() }; return appended }

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
        lock.lock(); appended += Double(samples.count) / Double(max(rate, 1)); lock.unlock()
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
                if first { Breadcrumb.log("audio add failed: \(error.localizedDescription)") }
            }
            stats.record(milliseconds: Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        }
    }

    /// Swapped out of the capture: nothing more is added.
    func finish() {}

    /// Stop taking audio, then process what is left and release the stream on the engine queue.
    func close(discard: Bool = false, then completion: (@Sendable () -> Void)? = nil) {
        lock.lock(); closed = true; lock.unlock()
        queue.async { [session] in
            if discard { session.discard() } else { session.flushAndClose() }
            completion?()
        }
    }
}

nonisolated enum TranscriptJoin {
    /// Lines joined with single spaces; empty ones are left out.
    static func join(_ parts: [String]) -> String {
        parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: " ")
    }
}
