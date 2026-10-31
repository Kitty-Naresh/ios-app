import Foundation

/// One stretch of speech (between two pauses) that the accurate model transcribes on its own.
nonisolated struct SettledPhrase: Equatable, Sendable {
    var id: Int
    /// Where it sat on the audio clock (seconds since the microphone was opened).
    var start: Double
    var end: Double
    /// How many words Apple Speech had reported when the pause was seen. Used to find the phrase's words when Apple gives no timings.
    var appleCountAtEnd: Int
    /// What the accurate model heard. nil while it is still working, or if it failed: Apple's words for the stretch stand.
    /// Empty means the model called it noise: the stretch is dropped.
    var text: String?
    var words: [SpokenWord] = []
}

/// The transcript shown and acted on: what Apple Speech heard live, with each stretch the accurate model has settled replaced by
/// the accurate text. Pure, so it is tested without audio.
///
/// Which of Apple's words belong to a settled phrase (and are therefore replaced by its text):
///  1. Timed words belong to the phrase whose stretch holds their middle (± `slack`). With no times at all, the first
///     `appleCountAtEnd` words, in order, belong to each phrase.
///  2. Apple lags, so more of a phrase's words can arrive after its pause. The words that directly follow a phrase's own words
///     (and, when timed, come before the next phrase and within `lateWindow` of its end) join it when they CONTINUE the settled text
///     word by word from where the phrase's own words stopped. A word that does not continue it is new speech and stays.
///  3. A safety net: a run of two or more leftover Apple words right after a settled phrase that repeats the end of its text is
///     dropped, unless the settled text itself repeats there.
/// Apple's words for a stretch the accurate model has not settled (or failed on) always stand.
nonisolated enum HybridTranscript {
    struct Merged: Equatable {
        var text: String
        var words: [SpokenWord]
        /// Apple's words that were dropped by the safety net because they repeated the end of a settled phrase.
        var removed: [String] = []
        /// Apple's late words that were taken into the phrase they continue.
        var claimed: [String] = []
    }

    /// A word whose middle is this close to a stretch (seconds) still belongs to it: Apple's word times are rough.
    static let slack = 0.15
    /// How long after a stretch ends (seconds) a timed word may still be the late end of it. Under the quiet that ends a stretch
    /// (`WhisperTurnBuffer.Config.hangoverSeconds` less the tail it keeps), so it cannot reach into the next one.
    static let lateWindow = 0.5

    /// The same word as far as two recognisers' spellings go. Short words must match exactly: "no" and "to" are one letter apart.
    private static func same(_ a: String, _ b: String) -> Bool {
        if a == b { return !a.isEmpty }
        guard a.count >= 4, b.count >= 4 else { return false }
        return TurnAccumulator.sameWord(a, b)
    }

    /// `apple` are the words of Apple's current recognition, cumulative since it started; `origin` is the audio clock at that moment,
    /// so a word at `timestamp` was spoken at `origin + timestamp`.
    static func merge(phrases: [SettledPhrase], apple: [SpokenWord], origin: Double) -> Merged {
        struct Piece { var key: Double; var text: String; var words: [SpokenWord]; var settled: Bool; var lateLimit: Double? }
        let ordered = phrases.sorted { $0.start < $1.start }
        let n = apple.count
        let timed = apple.contains { $0.timestamp > 0 || $0.duration > 0 }
        let heard = apple.map { BargeIn.norm($0.text) }

        // Where each word sat, when any word has a time. A word with none (a partial that has not got one yet) sits between its timed
        // neighbours, not at the start of the recording.
        var middle = [Double](repeating: 0, count: n)
        if timed {
            func has(_ w: SpokenWord) -> Bool { w.timestamp > 0 || w.duration > 0 }
            var i = 0
            var previousEnd: Double?
            while i < n {
                if has(apple[i]) {
                    middle[i] = origin + apple[i].timestamp + apple[i].duration / 2
                    previousEnd = origin + apple[i].timestamp + apple[i].duration
                    i += 1
                    continue
                }
                var j = i
                while j < n, !has(apple[j]) { j += 1 }
                let nextStart = j < n ? origin + apple[j].timestamp : nil
                let from = previousEnd ?? nextStart ?? origin
                let to = max(nextStart ?? from, from)
                for k in i..<j { middle[k] = from + (to - from) * Double(k - i + 1) / Double(j - i + 1) }
                i = j
            }
        }

        var owners = [Int?](repeating: nil, count: n)
        var firstKey = [Double](repeating: 0, count: ordered.count)
        var claimed: [String] = []

        /// The words after `last` that continue phrase `k`'s text from where its `owned` words stopped.
        func extend(_ k: Int, after last: Int, owned: Int) -> Int {
            guard let text = ordered[k].text, !text.isEmpty else { return 0 }
            let settled = TurnAccumulator.words(text)
            var best = (length: 0, shift: 0)
            for shift in [0, -1, 1] {
                let start = owned + shift
                guard start >= 0, start < settled.count else { continue }
                var run = 0
                while start + run < settled.count, last + 1 + run < n, owners[last + 1 + run] == nil {
                    let j = last + 1 + run
                    if timed {
                        if middle[j] > ordered[k].end + lateWindow { break }
                        if k + 1 < ordered.count, middle[j] >= ordered[k + 1].start - slack { break }
                    }
                    guard same(settled[start + run], heard[j]) else { break }
                    run += 1
                }
                // A match one word off is only believed when it is a run of at least two words.
                if run >= (shift == 0 ? 1 : 2), run > best.length { best = (run, shift) }
            }
            for j in (last + 1)..<(last + 1 + best.length) { owners[j] = k }
            if best.length > 0 {
                claimed.append(apple[(last + 1)..<(last + 1 + best.length)].map(\.text).joined(separator: " "))
            }
            return best.length
        }

        if timed {
            for (i, _) in apple.enumerated() {
                owners[i] = ordered.firstIndex { middle[i] >= $0.start - slack && middle[i] <= $0.end + slack }
            }
            for k in ordered.indices {
                firstKey[k] = ordered[k].start
                let own = owners.indices.filter { owners[$0] == k }
                if let last = own.last { _ = extend(k, after: last, owned: own.count) }
            }
        } else {
            var next = 0                                  // the first word no phrase has taken
            for (k, p) in ordered.enumerated() {
                firstKey[k] = Double(next) - 0.5
                let upper = min(max(p.appleCountAtEnd, next), n)
                for i in next..<upper { owners[i] = k }
                let late = extend(k, after: upper - 1, owned: upper - next)
                next = upper + late
            }
        }

        var pieces: [Piece] = []
        for (k, p) in ordered.enumerated() {
            guard let text = p.text, !text.isEmpty else { continue }
            let words = p.words.isEmpty ? text.split(separator: " ").map { SpokenWord(text: String($0), confidence: 0) } : p.words
            pieces.append(Piece(key: firstKey[k], text: text, words: words, settled: true, lateLimit: timed ? p.end + lateWindow : nil))
        }
        for (i, w) in apple.enumerated() {
            if let k = owners[i], ordered[k].text != nil { continue }      // replaced (or dropped) by the accurate model
            pieces.append(Piece(key: timed ? middle[i] : Double(i), text: w.text, words: [w], settled: false, lateLimit: nil))
        }
        // Stable: pieces with the same key keep the order they were added in.
        let sorted = pieces.enumerated().sorted { ($0.element.key, $0.offset) < ($1.element.key, $1.offset) }.map(\.element)

        // The safety net. A run of leftover Apple words right after a settled phrase that repeats the end of its text is that text again.
        var kept: [Piece] = []
        var removed: [String] = []
        var tail: (words: [String], limit: Double?)?
        var i = 0
        while i < sorted.count {
            if sorted[i].settled {
                kept.append(sorted[i])
                tail = (TurnAccumulator.words(sorted[i].text), sorted[i].lateLimit)
                i += 1
                continue
            }
            var j = i
            while j < sorted.count, !sorted[j].settled { j += 1 }
            var run = Array(sorted[i..<j])
            if let tail, run.count >= 2, tail.limit.map({ run[0].key <= $0 }) ?? true {
                let heardRun = run.map { BargeIn.norm($0.text) }
                for length in stride(from: min(run.count, tail.words.count), through: 2, by: -1) {
                    let end = Array(tail.words.suffix(length))
                    guard zip(heardRun.prefix(length), end).allSatisfy({ same($0, $1) }) else { continue }
                    // Said twice on purpose: the settled text already repeats there.
                    if tail.words.count >= 2 * length, zip(tail.words.suffix(length), tail.words.dropLast(length).suffix(length)).allSatisfy({ same($0, $1) }) { break }
                    removed += run.prefix(length).map(\.text)
                    run.removeFirst(length)
                    break
                }
            }
            kept += run
            tail = nil
            i = j
        }

        let text = kept.map { $0.text.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
        return Merged(text: text, words: kept.flatMap(\.words), removed: removed, claimed: claimed)
    }

    /// The longest run of words that is immediately said again ("to buy milk to buy milk", "milk milk"), case and punctuation
    /// ignored; nil when there is none. For the trace only: a repeat said on purpose is reported too.
    static func repeatedRun(in text: String) -> [String]? {
        let words = TurnAccumulator.words(text)
        guard words.count >= 2 else { return nil }
        for length in stride(from: words.count / 2, through: 1, by: -1) {
            for start in 0...(words.count - 2 * length) where words[start..<(start + length)] == words[(start + length)..<(start + 2 * length)] {
                return Array(words[start..<(start + length)])
            }
        }
        return nil
    }
}
