import Foundation

// MARK: - Result

/// What the cleaner made of a sentence. `raw` is exactly what was said; `text` is what Kitty acts on.
nonisolated struct CleanedSpeech: Equatable {
    enum Kind: String, Equatable { case filler, repeated, repair }

    /// One removal: what kind it was and which words (by position in `raw`, split on whitespace) went.
    struct Edit: Equatable {
        var kind: Kind
        var range: Range<Int>
        var words: [String]
    }

    var raw: String
    var text: String
    var edits: [Edit]
    /// Positions (in raw's whitespace-split words) of every removed word. The chat bubble strikes these through.
    var removed: Set<Int>
    /// The speaker said "no wait" and hasn't said the correction yet: keep listening.
    var pendingRepair = false

    var changed: Bool { !edits.isEmpty }
}

// MARK: - Cleaner

/// Turns how people actually talk ("um, clean the... no wait, wash the car") into what they meant ("wash the car").
///
/// Pure Swift, no model. Rules, in order, until nothing changes (so cleaning twice equals cleaning once):
///  1. Fillers: um, uh, er... always. "you know", "like", "basically" only when set off by commas or a pause.
///  2. Repeats: "the the", and 2-3 word restarts ("clean the clean the").
///  3. Self-repairs, only at a clause boundary (comma, ellipsis, "then", the start):
///     "scratch that" drops the previous clause; "no wait", "I mean", "or rather", "sorry," replace it.
///     Single words like "actually", "wait" and "sorry" are never triggers on their own.
nonisolated enum SpeechCleaner {

    static func clean(_ raw: String) -> CleanedSpeech {
        var toks = words(of: raw).map(Tok.init)
        var edits: [CleanedSpeech.Edit] = []
        var pending = false

        for _ in 0..<5 {
            let before = toks.filter { $0.removed }.count
            removeFillers(&toks, &edits)
            removeRepeats(&toks, &edits)
            if applyRepairs(&toks, &edits) { pending = true }
            if toks.filter({ $0.removed }).count == before { break }
        }

        let text = toks.filter { !$0.removed }.map(\.raw).joined(separator: " ")
        let removed = Set(toks.enumerated().filter { $0.element.removed }.map(\.offset))
        // The caller may ask again about the cleaned text; a repair still waiting for its answer is then unknowable.
        return CleanedSpeech(raw: raw, text: text, edits: edits, removed: removed, pendingRepair: pending && !text.isEmpty)
    }

    /// The words of a sentence, split exactly the way `clean` positions them.
    static func words(of text: String) -> [String] {
        text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    // MARK: Tokens

    private struct Tok {
        var raw: String
        var removed = false
        var word: String { SpeechLexicon.bare(raw) }
        var endsComma: Bool { raw.hasSuffix(",") }
        var endsSentence: Bool {
            guard let c = raw.last else { return false }
            return ".!?;:…".contains(c)
        }
        var endsAny: Bool { endsComma || endsSentence }
        init(_ raw: String) { self.raw = raw }
    }

    private static func live(_ toks: [Tok]) -> [Int] {
        toks.indices.filter { !toks[$0].removed }
    }

    private static func record(_ kind: CleanedSpeech.Kind, _ indices: [Int], _ toks: [Tok], _ edits: inout [CleanedSpeech.Edit]) {
        guard !indices.isEmpty else { return }
        // One edit per run of neighbouring words.
        var run: [Int] = []
        func flush() {
            guard let a = run.first, let b = run.last else { return }
            edits.append(.init(kind: kind, range: a..<(b + 1), words: run.map { toks[$0].raw }))
            run = []
        }
        for i in indices.sorted() {
            if let last = run.last, i != last + 1 { flush() }
            run.append(i)
        }
        flush()
    }

    private static func remove(_ kind: CleanedSpeech.Kind, _ indices: [Int], _ toks: inout [Tok],
                               _ edits: inout [CleanedSpeech.Edit], keepPunctuation: Bool) {
        guard !indices.isEmpty else { return }
        for i in indices.sorted() {
            toks[i].removed = true
            // "buy milk um, buy bread": the comma still separates the two thoughts.
            if keepPunctuation, let c = toks[i].raw.last, ",.;!?…".contains(c),
               let p = toks.indices.last(where: { $0 < i && !toks[$0].removed }), !toks[p].endsAny {
                toks[p].raw += String(c)
            }
        }
        record(kind, indices, toks, &edits)
    }

    // MARK: 1. Fillers

    private static func removeFillers(_ toks: inout [Tok], _ edits: inout [CleanedSpeech.Edit]) {
        // Hard fillers go anywhere.
        for i in live(toks) where SpeechLexicon.fillers.contains(toks[i].word) {
            remove(.filler, [i], &toks, &edits, keepPunctuation: true)
        }

        // Soft fillers only when set off.
        var k = 0
        while true {
            let L = live(toks)
            guard k < L.count else { break }
            var hit: [Int]?
            for phrase in SpeechLexicon.softFillers where k + phrase.count <= L.count {
                let idx = Array(L[k..<(k + phrase.count)])
                guard idx.map({ toks[$0].word }) == phrase else { continue }
                let last = toks[idx[idx.count - 1]]
                let prevTok: Tok? = k > 0 ? toks[L[k - 1]] : nil
                let prevWord = prevTok?.word ?? ""
                let startsSentence = prevTok == nil || prevTok!.endsSentence
                let setOffAfter = last.endsAny
                let setOffBefore = prevTok?.endsAny ?? false
                if phrase == ["like"] {
                    if setOffAfter { hit = idx }
                } else if phrase == ["you", "know"] {
                    if !["do", "did", "if", "as", "than", "what", "how", "and", "but"].contains(prevWord),
                       setOffAfter || setOffBefore || (startsSentence && k + phrase.count < L.count) { hit = idx }
                } else if setOffAfter || setOffBefore || (startsSentence && k + phrase.count < L.count) {
                    hit = idx
                }
                if hit != nil { break }
            }
            if let idx = hit {
                remove(.filler, idx, &toks, &edits, keepPunctuation: true)
            } else {
                k += 1
            }
        }
    }

    // MARK: 2. Repeats

    private static let mayRepeat: Set<String> = ["had", "that", "no", "very", "so", "bye", "ha", "knock"]

    private static func removeRepeats(_ toks: inout [Tok], _ edits: inout [CleanedSpeech.Edit]) {
        for n in [3, 2, 1] {
            var k = 0
            while true {
                let L = live(toks)
                guard k + 2 * n <= L.count else { break }
                let a = L[k..<(k + n)].map { toks[$0].word }
                let b = L[(k + n)..<(k + 2 * n)].map { toks[$0].word }
                let ok = a == b && !a.contains("") && !(n == 1 && (mayRepeat.contains(a[0]) || a[0].first?.isNumber == true))
                if ok {
                    // Keep the second copy: it carries the punctuation the speaker ended on.
                    remove(.repeated, Array(L[k..<(k + n)]), &toks, &edits, keepPunctuation: false)
                } else {
                    k += 1
                }
            }
        }
    }

    // MARK: 3. Self-repairs

    private struct Marker {
        var words: [String]
        var drops: Bool       // "scratch that": drop the previous clause; what follows is its own thing
    }

    private static let markers: [Marker] = [
        Marker(words: ["never", "mind", "that"], drops: true),
        Marker(words: ["scratch", "that"], drops: true),
        Marker(words: ["ignore", "that"], drops: true),
        Marker(words: ["no", "wait"], drops: false),
        Marker(words: ["wait", "no"], drops: false),
        Marker(words: ["no", "no"], drops: false),
        Marker(words: ["i", "mean"], drops: false),
        Marker(words: ["or", "rather"], drops: false),
        Marker(words: ["sorry"], drops: false)
    ]

    private static let sorryBlockers: Set<String> = [
        "say", "said", "saying", "tell", "told", "feel", "feeling", "so", "am", "i'm", "im", "very", "really", "be", "never", "sorry"
    ]

    private static let clauseBreakers: Set<String> = ["then", "also"]
    private static let leadIns: Set<String> = ["please", "to", "also", "just", "and", "so", "um"]
    private static let prepositions: Set<String> = ["to", "for", "at", "in", "on", "with", "from", "into", "by"]

    /// Returns true when a marker was the last thing said (the correction is still coming).
    private static func applyRepairs(_ toks: inout [Tok], _ edits: inout [CleanedSpeech.Edit]) -> Bool {
        var pending = false
        var guardCount = 0
        var from = 0
        outer: while guardCount < 8 {
            guardCount += 1
            let L = live(toks)
            var k = from
            while k < L.count {
                for m in markers where k + m.words.count <= L.count {
                    let idx = Array(L[k..<(k + m.words.count)])
                    guard idx.map({ toks[$0].word }) == m.words else { continue }

                    if m.words == ["i", "mean"], k + 2 < L.count, toks[L[k + 2]].word == "to" { continue }
                    if m.words == ["sorry"] {
                        let prev = k > 0 ? toks[L[k - 1]] : nil
                        guard toks[idx[0]].endsComma || (prev?.endsAny ?? false) else { continue }
                        if let p = prev, sorryBlockers.contains(p.word) { continue }
                    }

                    // The clause being corrected.
                    var s = k
                    while s > 0 {
                        let prev = toks[L[s - 1]]
                        if s - 1 < k - 1, prev.endsAny { break }
                        if clauseBreakers.contains(prev.word) { break }
                        s -= 1
                    }
                    let clause = Array(L[s..<k])
                    guard !clause.isEmpty else { continue }

                    // What follows the marker, up to the end of its clause.
                    var e = k + m.words.count
                    var replacement: [Int] = []
                    while e < L.count {
                        let t = toks[L[e]]
                        if clauseBreakers.contains(t.word) { break }
                        replacement.append(L[e])
                        e += 1
                        if t.endsAny { break }
                    }

                    if m.drops {
                        remove(.repair, clause + idx, &toks, &edits, keepPunctuation: false)
                        from = 0
                        continue outer
                    }

                    if replacement.isEmpty {
                        // "clean the... no wait": the correction hasn't come yet.
                        remove(.repair, idx, &toks, &edits, keepPunctuation: false)
                        pending = true
                        from = 0
                        continue outer
                    }

                    let removeFromClause = what(toRemove: clause, replacement: replacement, toks: toks)
                    remove(.repair, removeFromClause + idx, &toks, &edits, keepPunctuation: false)
                    from = 0
                    continue outer
                }
                k += 1
            }
            break
        }
        return pending
    }

    /// Which of the previous clause's words the correction replaces.
    private static func what(toRemove clause: [Int], replacement: [Int], toks: [Tok]) -> [Int] {
        let cWords = clause.map { toks[$0].word }
        var rWords = replacement.map { toks[$0].word }
        while let f = rWords.first, leadIns.contains(f), rWords.count > 1 { rWords.removeFirst() }
        guard let first = rWords.first else { return [] }

        // A whole new request ("add a task to wash the car") or an action ("wash the car"):
        // the new words replace everything after the frame ("add a task to ...") of the old clause.
        let startsWithFrame = SpeechLexicon.frames.contains { rWords.starts(with: $0) }
        if startsWithFrame { return clause }
        if ActionLexicon.verbs.contains(first) {
            var frameLen = 0
            var rest = cWords[...]
            outer: while true {
                for f in SpeechLexicon.frames where rest.starts(with: f) {
                    rest = rest.dropFirst(f.count)
                    frameLen += f.count
                    continue outer
                }
                break
            }
            return Array(clause.dropFirst(frameLen))
        }

        // A day or time ("tomorrow, no wait, Friday"): swap just the day/time words.
        let isDayTime = rWords.allSatisfy { SpeechLexicon.dayTimeWords.contains($0) || $0.contains(where: \.isNumber) }
            && rWords.contains { SpeechLexicon.weekdays.contains($0) || ["today", "tomorrow", "tonight", "morning", "afternoon", "evening", "noon", "midnight"].contains($0) || $0.contains(where: \.isNumber) }
        if isDayTime {
            let timeOnly = SpeechLexicon.dayTimeWords.subtracting(["on", "at", "by"])
            func isTime(_ w: String) -> Bool { timeOnly.contains(w) || w.contains(where: \.isNumber) }
            guard let end = cWords.lastIndex(where: isTime) else { return [] }
            var start = end
            while start > 0, isTime(cWords[start - 1]) { start -= 1 }
            var out = Array(clause[start...end])
            if start > 0, ["on", "at", "by"].contains(cWords[start - 1]), ["on", "at", "by"].contains(first) {
                out.insert(clause[start - 1], at: 0)
            }
            return out
        }

        // Otherwise a noun phrase ("buy milk, I mean bread"): swap the last phrase.
        let startsWithDeterminer = SpeechLexicon.determiners.contains(first)
        for j in stride(from: cWords.count - 1, through: 0, by: -1) {
            let w = cWords[j]
            let isDeterminerAnchor = SpeechLexicon.phraseAnchors.contains(w)
            let isVerbAnchor = ActionLexicon.verbs.contains(w)
            let isPrep = prepositions.contains(w)
            let usable = startsWithDeterminer ? (isVerbAnchor || isPrep) : (isDeterminerAnchor || isVerbAnchor)
            guard usable else { continue }
            // A verb in the final position is more likely a noun ("buy water").
            if j == cWords.count - 1, isVerbAnchor, !isDeterminerAnchor { continue }
            return Array(clause[(j + 1)...])
        }
        return []
    }
}
