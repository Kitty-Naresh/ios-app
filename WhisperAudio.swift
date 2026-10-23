import Foundation

// MARK: - 16 kHz mono, which is what Whisper takes

/// Turns the microphone's samples (44.1 or 48 kHz, mono already) into 16 kHz, one chunk at a time, keeping its place between
/// chunks. Each output sample is the average of the input samples it covers, which is a plain low-pass for a down-sample.
nonisolated final class StreamResampler {
    static let whisperRate = 16_000.0

    let inputRate: Double
    private let ratio: Double          // input samples per output sample
    private var filled = 0.0           // how much of the current output sample is covered so far
    private var sum = 0.0

    init(inputRate: Double, outputRate: Double = StreamResampler.whisperRate) {
        self.inputRate = inputRate
        self.ratio = max(inputRate, 1) / outputRate
    }

    func process(_ input: [Float]) -> [Float] {
        if ratio == 1 { return input }
        var out: [Float] = []
        out.reserveCapacity(Int(Double(input.count) / ratio) + 2)
        for x in input {
            var remaining = 1.0
            while remaining > 1e-9 {
                let take = min(ratio - filled, remaining)
                sum += Double(x) * take
                filled += take
                remaining -= take
                if filled >= ratio - 1e-9 {
                    out.append(Float(sum / ratio))
                    sum = 0
                    filled = 0
                }
            }
        }
        return out
    }
}

// MARK: - Where speech starts and stops

/// Collects one spoken stretch of 16 kHz audio and says when speech started and when it ended, with a plain energy detector.
/// Whisper only runs while someone is talking, which is most of the battery saving. A stretch is capped at `maxTurnSeconds`.
nonisolated struct WhisperTurnBuffer {
    struct Config {
        var frameSamples = 320                   // 20 ms
        var startFrames = 4                      // 80 ms of voice starts a stretch
        var hangoverSeconds = 0.9                // this much quiet ends it
        var minSpeechSeconds = 0.25              // less voice than this is a click or a cough; a short "yes" is longer
        var preRollSeconds = 0.3                 // audio kept from just before the voice, so the first word is not clipped
        var tailSeconds = 0.25                   // quiet kept after the last word
        var maxTurnSeconds = 60.0
        var minThreshold: Float = 0.008          // RMS, about -42 dBFS
        var noiseMultiplier: Float = 3
    }

    enum Event: Equatable {
        case started
        /// The speaker stopped; `samples` is the whole stretch. `voiced` is false for a click or a cough too short to be speech.
        case ended(samples: [Float], voiced: Bool)
        /// The stretch reached the cap: `samples` is what was collected, and a new stretch begins straight away.
        case capped(samples: [Float])
    }

    static let rate = 16_000.0

    let config: Config
    private(set) var samples: [Float] = []        // the current stretch, empty when nobody is talking
    private(set) var inSpeech = false
    private var pending: [Float] = []             // less than one frame
    private var preRoll: [[Float]] = []
    private var loudRun = 0
    private var quietRun = 0
    private var voicedFrames = 0                  // loud frames in the current stretch
    private var noiseFloor: Float = 0.003

    init(config: Config = Config()) { self.config = config }

    var seconds: Double { Double(samples.count) / Self.rate }

    var threshold: Float { max(config.minThreshold, noiseFloor * config.noiseMultiplier) }

    mutating func append(_ new: [Float]) -> [Event] {
        var events: [Event] = []
        pending.append(contentsOf: new)
        let n = config.frameSamples
        var offset = 0
        while pending.count - offset >= n {
            let frame = Array(pending[offset..<(offset + n)])
            offset += n
            consume(frame, into: &events)
        }
        if offset > 0 { pending.removeFirst(offset) }
        return events
    }

    /// The current stretch handed over and cleared, for a last pass when the microphone is closed mid-sentence.
    mutating func drain() -> (samples: [Float], voiced: Bool) {
        let out = samples
        let voiced = inSpeech && Double(voicedFrames * config.frameSamples) / Self.rate >= config.minSpeechSeconds
        reset()
        return (out, voiced)
    }

    mutating func reset() {
        samples = []
        pending = []
        preRoll = []
        inSpeech = false
        loudRun = 0
        quietRun = 0
        voicedFrames = 0
    }

    private static func rms(_ frame: [Float]) -> Float {
        var sum: Float = 0
        for x in frame { sum += x * x }
        return (sum / Float(max(frame.count, 1))).squareRoot()
    }

    private mutating func consume(_ frame: [Float], into events: inout [Event]) {
        let level = Self.rms(frame)
        let loud = level > threshold
        let frameSeconds = Double(config.frameSamples) / Self.rate

        if !inSpeech {
            if !loud { noiseFloor = noiseFloor * 0.95 + level * 0.05 }
            preRoll.append(frame)
            let keep = max(Int(config.preRollSeconds / frameSeconds), config.startFrames)
            if preRoll.count > keep { preRoll.removeFirst(preRoll.count - keep) }
            loudRun = loud ? loudRun + 1 : 0
            if loudRun >= config.startFrames {
                inSpeech = true
                quietRun = 0
                voicedFrames = loudRun
                samples = preRoll.flatMap { $0 }
                preRoll = []
                events.append(.started)
            }
            return
        }

        samples.append(contentsOf: frame)
        quietRun = loud ? 0 : quietRun + 1
        if loud { voicedFrames += 1 }
        if Double(quietRun) * frameSeconds >= config.hangoverSeconds {
            let tailFrames = Int(config.tailSeconds / frameSeconds)
            let trim = max(quietRun - tailFrames, 0) * config.frameSamples
            if trim > 0 { samples.removeLast(min(trim, samples.count)) }
            let voiced = Double(voicedFrames * config.frameSamples) / Self.rate >= config.minSpeechSeconds
            inSpeech = false
            loudRun = 0
            quietRun = 0
            voicedFrames = 0
            let out = samples
            samples = []
            events.append(.ended(samples: out, voiced: voiced))
            return
        }
        if seconds >= config.maxTurnSeconds {
            let out = samples
            samples = []
            quietRun = 0
            voicedFrames = 0
            events.append(.capped(samples: out))
        }
    }
}

// MARK: - What Whisper says, cleaned up

/// Whisper's habits on weak audio: bracketed noise labels, "Thank you for watching", and loops of the same words.
nonisolated enum WhisperText {
    private static let phantoms: Set<String> = [
        "thanks for watching", "thank you for watching", "please subscribe", "you", "bye", "the end",
        "subtitles by the amaraorg community", "like and subscribe",
    ]

    /// The text to show, or "" if it was only noise. `voicedSeconds` is how much speech the detector heard.
    static func clean(_ raw: String, voicedSeconds: Double = 10, noSpeech: Float = 0, meanConfidence: Float = 1) -> String {
        var text = raw
        // [BLANK_AUDIO], (music), *sigh*, and the music note
        for pattern in ["\\[[^\\]]*\\]", "\\([^)]*\\)", "\\*[^*]*\\*", "[♪♫]+"] {
            text = text.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        text = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !text.isEmpty else { return "" }
        text = collapseLoops(text)
        if noSpeech > 0.6 && meanConfidence < 0.5 { return "" }
        if voicedSeconds < 1.5, phantoms.contains(normalised(text)) { return "" }
        return text
    }

    private static func normalised(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber || $0 == " " }
            .split(separator: " ").joined(separator: " ")
    }

    /// A word or short phrase repeated four or more times in a row is a decoder loop: keep one run of it.
    static func collapseLoops(_ text: String) -> String {
        var words = text.split(separator: " ").map(String.init)
        guard words.count >= 4 else { return text }
        let key: (String) -> String = { $0.lowercased().filter { $0.isLetter || $0.isNumber } }
        for n in 1...6 {
            var i = 0
            while i + n * 4 <= words.count {
                var reps = 1
                while i + (reps + 1) * n <= words.count,
                      (0..<n).allSatisfy({ key(words[i + $0]) == key(words[i + reps * n + $0]) }) {
                    reps += 1
                }
                if reps >= 4 {
                    words.removeSubrange((i + n)..<(i + reps * n))
                    i += n
                } else {
                    i += 1
                }
            }
        }
        return words.joined(separator: " ")
    }
}

// MARK: - The prompt that carries names and brands

nonisolated enum WhisperPrompt {
    static let maxCharacters = 450

    /// Household names first, then the bundled Indian brands, as a plain list: Whisper spells these the way it was shown.
    static func build(from terms: [String]) -> String {
        var out = ""
        for term in terms {
            let piece = out.isEmpty ? term : ", " + term
            if out.count + piece.count + 1 > maxCharacters { break }
            out += piece
        }
        return out.isEmpty ? "" : out + "."
    }
}
