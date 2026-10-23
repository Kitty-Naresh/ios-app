import Foundation
import Combine
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

// MARK: - What the conversation needs from a recogniser

/// The surface `VoiceConversation` listens through. Moonshine is the main recogniser (live, punctuated, with key terms);
/// Apple Speech is the fallback if the Moonshine model cannot load, and is what the "Hey Kitty" wake word uses.
@MainActor
protocol TurnRecognizer: AnyObject {
    /// The text of this listening session so far.
    var transcript: String { get }
    /// Words of the latest result. Confidence is 0 where the recogniser does not report one.
    var words: [SpokenWord] { get }
    var isRecording: Bool { get }
    var errorMessage: String? { get set }
    /// The last start-up failure cannot be fixed by trying again.
    var failureIsPermanent: Bool { get }
    /// Conversation mode: punctuation on, and never ends by itself on a pause.
    var continuous: Bool { get set }
    /// Echo-cancelled duplex session for hands-free "stop" while Kitty talks.
    var bargeIn: Bool { get set }
    /// Names and terms to expect. Asked for at the start of each session.
    var vocabulary: (@MainActor () -> [String])? { get set }
    var onPartial: ((String) -> Void)? { get set }
    var onFinished: ((String) -> Void)? { get set }

    func start() async
    func stop()
    func cancel()
    /// A fresh recognition on the microphone that is already running. False if it is not running.
    @discardableResult func restartRecognition() -> Bool
    func resetAudioEngine()
    /// The microphone stays open while Kitty talks, listening only for a stop word or real speech. False if it cannot.
    /// `restartRecognition()` brings the normal listening back afterwards.
    @discardableResult func beginSpeakingListen() -> Bool
}

// MARK: - Where the microphone goes

/// A consumer of the microphone. One engine and one tap serve whichever sink is current, so Kitty can hand the same running
/// microphone from Moonshine to Apple Speech (hands-free "stop" while she talks) and back without touching the audio session.
/// `append` is called on the audio thread: copy what you need and return quickly.
nonisolated protocol AudioSink: AnyObject {
    func append(_ buffer: AVAudioPCMBuffer)
    /// No more audio will arrive (swapped out or stopped).
    func finish()
}

nonisolated enum MonoAudio {
    /// All channels averaged into one array of Float samples in -1...1, which is what Moonshine takes.
    static func samples(from buffer: AVAudioPCMBuffer) -> [Float] {
        let frames = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard frames > 0, channels > 0 else { return [] }
        if let data = buffer.floatChannelData {
            if channels == 1 { return Array(UnsafeBufferPointer(start: data[0], count: frames)) }
            var out = [Float](repeating: 0, count: frames)
            for c in 0..<channels {
                let ch = data[c]
                for i in 0..<frames { out[i] += ch[i] }
            }
            let scale = 1 / Float(channels)
            for i in 0..<frames { out[i] *= scale }
            return out
        }
        if let data = buffer.int16ChannelData {
            var out = [Float](repeating: 0, count: frames)
            for c in 0..<channels {
                let ch = data[c]
                for i in 0..<frames { out[i] += Float(ch[i]) / 32768 }
            }
            let scale = 1 / Float(channels)
            for i in 0..<frames { out[i] *= scale }
            return out
        }
        return []
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
    private var sink: AudioSink?

    private func setSink(_ new: AudioSink?) {
        lock.lock(); let old = sink; sink = new; lock.unlock()
        if let old, old !== new { old.finish() }
    }

    private func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); let target = sink; lock.unlock()
        target?.append(buffer)
    }

    /// Point the running microphone at a new consumer (Apple Speech or Moonshine). No engine or session change.
    func swap(to newSink: AudioSink?) { setSink(newSink) }

    func start(feeding newSink: AudioSink, voiceProcessing: Bool = false) async throws {
        setSink(newSink)
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
                    if mode == .voiceChat { preferEchoCancellation(session) }
                    Breadcrumb.log("  route: \(describeRoute(session))")
                    cont.resume()
                } catch {
                    Breadcrumb.log("  queue: audio session failed: \(error.localizedDescription)")
                    cont.resume(throwing: error)
                }
            }
        }
    }

    /// Asks for the system's echo-cancelled input as well, where the device offers it. Voice-chat mode already cancels echo
    /// on most routes; this is a second request, and a refusal is harmless.
    private static func preferEchoCancellation(_ session: AVAudioSession) {
        if #available(iOS 18.2, *) {
            if session.isEchoCancelledInputAvailable {
                do {
                    try session.setPrefersEchoCancelledInput(true)
                    Breadcrumb.log("  echo-cancelled input: on")
                } catch {
                    Breadcrumb.log("  echo-cancelled input refused: \(error.localizedDescription)")
                }
            } else {
                Breadcrumb.log("  echo-cancelled input: not available on this route")
            }
        }
    }

    /// Which microphone and speaker are in use. Bluetooth and wired routes echo differently from the phone's own.
    static func describeRoute(_ session: AVAudioSession) -> String {
        let ins = session.currentRoute.inputs.map { $0.portType.rawValue }.joined(separator: ",")
        let outs = session.currentRoute.outputs.map { $0.portType.rawValue }.joined(separator: ",")
        return "in \(ins.isEmpty ? "none" : ins), out \(outs.isEmpty ? "none" : outs)"
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
                utterance.volume = 0.9                                           // a little under full: less of her voice reaches the mic
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
