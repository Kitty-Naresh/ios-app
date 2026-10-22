import Foundation

// MARK: - Sound-alike matching against the names Kitty knows

/// Maps what the recogniser heard to a name the household really uses: "Rainy" to "Rani".
/// A sound-alike key (consonant skeleton) plus edit distance, so it works with no confidence data at all.
nonisolated enum VocabularyMatcher {
    enum Match: Equatable {
        case exact(String)          // the same name
        case strong(String)         // one close, sound-alike name: safe to use
        case medium([String])       // sounds alike but could be someone else: ask first
        case none
    }

    static func match(_ heard: String, in vocabulary: [String]) -> Match {
        let h = letters(heard)
        guard h.count >= 2 else { return .none }
        var strong: [(String, Int)] = []
        var medium: [(String, Int)] = []
        for candidate in vocabulary {
            let c = letters(candidate)
            guard c.count >= 2 else { continue }
            if c == h { return .exact(candidate) }
            let d = editDistance(h, c)
            let shortest = min(h.count, c.count), longest = max(h.count, c.count)
            let sameSound = phoneticKey(h) == phoneticKey(c) && phoneticKey(h).count >= 2
            if d == 1, shortest >= 4, sameSound || longest >= 6 {
                strong.append((candidate, d))
            } else if sameSound, d <= 3 {
                medium.append((candidate, d))          // only look-alikes that also sound alike: "Ravi" is not "Rani"
            }
        }
        if strong.count == 1, medium.isEmpty { return .strong(strong[0].0) }
        let pool = (strong + medium).sorted { ($0.1, $0.0) < ($1.1, $1.0) }
        if pool.isEmpty { return .none }
        return .medium(pool.map(\.0))
    }

    /// Letters only, lower case: "Mary-Ann" and "maryann" compare equal.
    static func letters(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter }
    }

    /// A rough "how it sounds" key: Rani, Rainy and Rannie all give "rn".
    /// The first letter is kept, later vowels are dropped, doubled letters collapse, and look-alike letters share one.
    static func phoneticKey(_ s: String) -> String {
        var t = letters(s)
        guard !t.isEmpty else { return "" }
        if t.hasPrefix("kn") || t.hasPrefix("wr") { t.removeFirst() }
        for (from, to) in [("ph", "f"), ("ck", "k"), ("sch", "sk"), ("gh", "g"), ("th", "t"), ("sh", "s"), ("ch", "c")] {
            t = t.replacingOccurrences(of: from, with: to)
        }
        let like: [Character: Character] = ["q": "k", "z": "s", "v": "w", "c": "k", "x": "k", "y": "i"]
        t = String(t.map { like[$0] ?? $0 })
        let vowels = Set("aeiouh")
        var key = ""
        for (i, ch) in t.enumerated() {
            if i > 0, vowels.contains(ch) { continue }
            if key.last == ch { continue }
            key.append(ch)
        }
        return key
    }

    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        for i in 1...a.count {
            var cur = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return prev[b.count]
    }
}

// MARK: - When to read something back

/// Decides when Kitty should say "Did you say Rani?" instead of acting. Only for names, numbers and dates, where a
/// mishearing silently saves the wrong thing. One read-back per turn (the caller enforces that).
nonisolated enum ReadBackCheck {
    enum Verdict: Equatable {
        case none
        case ask(heard: String, suggestion: String)
    }

    /// Below this a recognised word is doubtful. Zero means "unknown" (partial results often report 0), never "doubtful".
    static let doubtful: Float = 0.5

    private static let roles: Set<String> = ["me", "family", "househelp", "cook", "driver", "gardener", "nanny", "chef"]

    private static let numberWords: Set<String> = [
        "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve", "fifteen",
        "twenty", "thirty", "forty", "fifty", "hundred", "thousand"
    ]

    static func isRole(_ name: String) -> Bool {
        roles.contains(Assignee.normalize(name).lowercased())
    }

    private static func confidence(of token: String, in words: [SpokenWord]) -> Float? {
        words.first(where: { SpeechLexicon.bare($0.text) == token })?.confidence
    }

    /// A person's name the model took from the utterance.
    ///  - the same as a known name: fine
    ///  - one close known name: the validator uses it silently
    ///  - a sound-alike that could be someone else: read it back
    ///  - no known name close by: keep what was heard, unless the recogniser itself was unsure of the word
    static func assignee(_ value: String, utterance: String, known: [String], words: [SpokenWord] = []) -> Verdict {
        let heard = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !heard.isEmpty, !isRole(heard) else { return .none }
        let said = LocalSemanticPrechecker.tokens(utterance)
        guard said.contains(heard.lowercased()) else { return .none }       // not stated: the validator drops it

        let people = known.filter { !isRole($0) }
        switch VocabularyMatcher.match(heard, in: people) {
        case .exact, .strong: return .none
        case .medium(let names): return .ask(heard: heard, suggestion: names[0])
        case .none:
            if let c = confidence(of: heard.lowercased(), in: words), c > 0, c < doubtful {
                return .ask(heard: heard, suggestion: heard.capitalized)
            }
            return .none
        }
    }

    /// A number or a day the recogniser was unsure of: "Did you say Friday?"
    static func fact(utterance: String, words: [SpokenWord]) -> Verdict {
        let said = Set(LocalSemanticPrechecker.tokens(utterance))
        for w in words where w.confidence > 0 && w.confidence < doubtful {
            let t = SpeechLexicon.bare(w.text)
            guard said.contains(t) else { continue }
            let isNumber = t.contains(where: \.isNumber) || numberWords.contains(t)
            let isDate = SpeechLexicon.weekdays.contains(t) && t.count > 3 || SpeechLexicon.months.contains(t) || ["tomorrow", "tonight"].contains(t)
            if isNumber || isDate { return .ask(heard: t, suggestion: isNumber ? t : t.capitalized) }
        }
        return .none
    }

    /// "Rainy" -> "Rani" in "ask Rainy to sweep", whole words only, any case.
    static func replacing(_ heard: String, with name: String, in text: String) -> String {
        guard !heard.isEmpty, heard != name,
              let regex = try? NSRegularExpression(pattern: "\\b" + NSRegularExpression.escapedPattern(for: heard) + "\\b", options: .caseInsensitive)
        else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                                              withTemplate: NSRegularExpression.escapedTemplate(for: name))
    }

    /// "it's Rani", "I said Priya", "Rani": the name in the answer to "Who did you mean?".
    static func name(in answer: String) -> String {
        var w = answer.split(whereSeparator: { $0.isWhitespace }).map { $0.trimmingCharacters(in: .punctuationCharacters) }.filter { !$0.isEmpty }
        let lead: Set<String> = ["it's", "its", "it", "is", "i", "said", "meant", "mean", "i'm", "was", "the", "for", "to", "ask", "tell", "no", "she", "he", "called", "named"]
        while let f = w.first, lead.contains(f.lowercased()), w.count > 1 { w.removeFirst() }
        return w.prefix(2).joined(separator: " ").capitalized
    }
}
