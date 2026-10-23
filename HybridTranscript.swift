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
nonisolated enum HybridTranscript {
    struct Merged: Equatable {
        var text: String
        var words: [SpokenWord]
    }

    /// A word whose middle is this close to a stretch (seconds) still belongs to it: Apple's word times are rough.
    static let slack = 0.15

    /// `apple` are the words of Apple's current recognition, cumulative since it started; `origin` is the audio clock at that moment,
    /// so a word at `timestamp` was spoken at `origin + timestamp`.
    static func merge(phrases: [SettledPhrase], apple: [SpokenWord], origin: Double) -> Merged {
        struct Piece { var key: Double; var text: String; var words: [SpokenWord] }
        let ordered = phrases.sorted { $0.start < $1.start }
        let timed = apple.contains { $0.timestamp > 0 || $0.duration > 0 }
        var pieces: [Piece] = []

        // Which phrase, if any, owns each of Apple's words.
        var owners = [Int?](repeating: nil, count: apple.count)
        var claimStart = [Int](repeating: 0, count: ordered.count)
        if timed {
            for (i, w) in apple.enumerated() {
                let middle = origin + w.timestamp + w.duration / 2
                owners[i] = ordered.firstIndex { middle >= $0.start - slack && middle <= $0.end + slack }
            }
        } else {
            var previous = 0
            for (k, p) in ordered.enumerated() {
                let upper = min(max(p.appleCountAtEnd, previous), apple.count)
                claimStart[k] = previous
                for i in previous..<upper { owners[i] = k }
                previous = upper
            }
        }

        for (k, p) in ordered.enumerated() {
            guard let text = p.text, !text.isEmpty else { continue }
            let words = p.words.isEmpty ? text.split(separator: " ").map { SpokenWord(text: String($0), confidence: 0) } : p.words
            pieces.append(Piece(key: timed ? p.start : Double(claimStart[k]) - 0.5, text: text, words: words))
        }
        for (i, w) in apple.enumerated() {
            if let k = owners[i], ordered[k].text != nil { continue }      // replaced (or dropped) by the accurate model
            let key = timed ? origin + w.timestamp + w.duration / 2 : Double(i)
            pieces.append(Piece(key: key, text: w.text, words: [w]))
        }
        // Stable: pieces with the same key keep the order they were added in.
        let sorted = pieces.enumerated().sorted { ($0.element.key, $0.offset) < ($1.element.key, $1.offset) }.map(\.element)
        let text = sorted.map { $0.text.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
        return Merged(text: text, words: sorted.flatMap(\.words))
    }
}
