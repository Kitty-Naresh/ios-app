import Foundation

// MARK: - Long, rambling speech: what is chatter, what is context, what is an action

/// What a long turn shares between its tasks: "my in-laws are coming this Saturday". It is only ever *shown* or *asked about*;
/// it is never written into a task silently.
struct SharedContext: Equatable {
    var due: Date? = nil
    var dueLabel: String? = nil            // "Saturday", "Tomorrow"
    var assignee: String? = nil            // only a role the user named ("the maid"), never "Me"
    var occasion: String? = nil            // "in-laws", "birthday"
    var notes: String? = nil               // "For in-laws"

    var isEmpty: Bool { due == nil && assignee == nil && occasion == nil }

    /// "Saturday, for in-laws": the line under the preview.
    var usedLine: String? {
        var parts: [String] = []
        if let d = dueLabel { parts.append(d) }
        if let o = occasion { parts.append("for " + o) }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}

struct Clause: Equatable {
    enum Kind: String, Equatable { case chatter, context, action, correction }
    var text: String
    var kind: Kind
}

/// One thing to do, in the user's words (frames like "I need to" and the day are taken off).
struct ActionClause: Equatable {
    var text: String                 // "clean the bathrooms"
    var title: String                // "Clean the bathrooms"
    var due: Date? = nil             // a day said inside this clause ("... on Friday"), not from context
    var dueLabel: String? = nil
    var assignee: String? = nil      // "the maid should ..." -> Househelp
    var clause = 0                   // which clause it came from
    var source = ""                  // that clause as said: where dates and names for this action may be looked for
    var scheduled = false            // "every morning": a routine, not a one-off
}

struct LongTurn: Equatable {
    var clauses: [Clause] = []
    var context = SharedContext()
    var actions: [ActionClause] = []
    var skipped: [String] = []       // chatter, in the user's words: offered back as "Skipped (N)"

    var contextClauses: [String] { clauses.filter { $0.kind == .context }.map(\.text) }
}

enum LongTurnAnalyzer {
    /// A turn over this many words is read as a long turn.
    static let longWords = 12

    static func isLong(_ text: String) -> Bool {
        text.split(whereSeparator: { $0.isWhitespace }).count > longWords
    }

    // MARK: Vocabulary

    private static let leadFillers: Set<String> = [
        "okay", "ok", "so", "now", "well", "anyway", "anyways", "honestly", "basically", "actually", "oh", "and", "but", "then", "yeah",
        "yes", "like", "um", "uh", "alright", "right", "also", "hmm", "listen", "look", "probably", "maybe", "perhaps", "just",
        "really", "definitely", "still", "finally", "plus"
    ]

    /// Said before the real action ("I need to", "can you"). Longest first.
    private static let frameList: [[String]] = [
        ["i", "was", "thinking", "that"], ["i", "was", "thinking"], ["i", "am", "thinking"], ["i", "think", "that"], ["i", "think"],
        ["i", "guess"], ["i", "suppose"], ["i", "would", "like", "to"], ["i'd", "like", "to"], ["i", "want", "to"],
        ["i", "need", "to"], ["i", "have", "to"], ["i", "gotta"], ["i've", "got", "to"], ["i", "should"], ["i", "must"],
        ["i", "will"], ["i'll"], ["we", "need", "to"], ["we", "have", "to"], ["we", "want", "to"], ["we", "should"],
        ["we", "must"], ["can", "you"], ["could", "you"], ["would", "you"], ["will", "you"], ["remind", "me", "to"],
        ["make", "sure", "that"], ["make", "sure", "we"], ["make", "sure", "to"], ["don't", "forget", "to"],
        ["dont", "forget", "to"], ["do", "not", "forget", "to"], ["let's"], ["lets"], ["please"], ["need", "to"], ["to"]
    ].sorted { $0.count > $1.count }

    private static let delegators: Set<String> = ["ask", "tell", "have", "get"]
    private static let modals: Set<String> = ["should", "must", "will", "needs", "need", "has", "can"]
    private static let auxiliaries: Set<String> = ["is", "are", "was", "were", "has", "have", "had", "will", "should", "needs", "need", "can", "could", "would"]
    private static let subjects: Set<String> = ["i", "we", "it", "they", "he", "she", "there"]
    private static let determinerSubjects: Set<String> = ["the", "my", "this", "that", "our", "his", "her"]

    /// Markers that start a new clause. `keep`: the marker words stay in the clause (they are frames, stripped later).
    private static let markers: [(words: [String], keep: Bool)] = [
        (["one", "more", "thing"], false), (["another", "thing"], false), (["and", "then"], false), (["oh", "and"], false),
        (["and", "please"], false), (["and", "honestly"], false), (["and", "basically"], false), (["and", "actually"], false),
        (["remind", "me", "to"], true), (["don't", "forget", "to"], true), (["dont", "forget", "to"], true), (["make", "sure", "to"], true),
        (["also"], false), (["plus"], false), (["but"], false), (["anyway"], false), (["anyways"], false),
    ].sorted { $0.words.count > $1.words.count }

    private static let occasions: [(keys: [String], label: String)] = [
        (["in-laws", "in laws", "inlaws"], "in-laws"), (["guests"], "guests"), (["visitors"], "visitors"), (["party"], "the party"),
        (["birthday"], "the birthday"), (["wedding"], "the wedding"), (["anniversary"], "the anniversary"), (["parents"], "your parents"),
        (["relatives"], "relatives"), (["friends coming", "friends are coming", "friends over"], "friends"), (["trip"], "the trip"),
        (["holiday"], "the holiday"), (["visit"], "the visit"),
    ]

    private static let dayWords = ["tomorrow", "today", "tonight", "sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]

    private static func bare(_ w: String) -> String { SpeechLexicon.bare(w) }

    private static func hasPrefix(_ t: [String], _ p: [String]) -> Bool {
        t.count > p.count && zip(t, p).allSatisfy { bare($0) == $1 }
    }

    // MARK: Splitting

    /// Token positions after which the speaker paused for at least `gap` seconds.
    private static func pauseBreaks(_ tokens: [String], words: [SpokenWord], gap: TimeInterval) -> Set<Int> {
        guard !words.isEmpty else { return [] }
        var matched: [Int?] = Array(repeating: nil, count: tokens.count)
        var wi = 0
        for (ti, tok) in tokens.enumerated() {
            let b = bare(tok)
            guard wi < words.count else { break }
            for w in wi..<min(wi + 4, words.count) where bare(words[w].text) == b {
                matched[ti] = w
                wi = w + 1
                break
            }
        }
        var out = Set<Int>()
        for ti in 0..<max(tokens.count - 1, 0) {
            guard let a = matched[ti], let b = matched[ti + 1], b == a + 1 else { continue }
            if words[b].timestamp - (words[a].timestamp + words[a].duration) >= gap { out.insert(ti) }
        }
        return out
    }

    private static func markerLength(_ b: [String], at i: Int) -> (len: Int, keep: Bool)? {
        for m in markers where i + m.words.count <= b.count && Array(b[i..<(i + m.words.count)]) == m.words {
            return (m.words.count, m.keep)
        }
        // "... and he said ...", "... and the house is a mess": a new thought with its own subject
        if b[i] == "and", i + 1 < b.count {
            let next = b[i + 1]
            if subjects.contains(next) { return (1, false) }
            if determinerSubjects.contains(next), i + 2 < b.count,
               b[(i + 2)..<min(i + 6, b.count)].contains(where: { auxiliaries.contains($0) }) { return (1, false) }
        }
        return nil
    }

    static func split(_ cleaned: String, words: [SpokenWord] = []) -> [String] {
        let raw = cleaned.replacingOccurrences(of: "’", with: "'").split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let b = raw.map(bare)
        let pauses = pauseBreaks(raw, words: words, gap: 0.7)
        var pieces: [[String]] = []
        var cur: [String] = []
        func flush() { if !cur.isEmpty { pieces.append(cur); cur = [] } }
        var i = 0
        while i < raw.count {
            if let m = markerLength(b, at: i) {
                flush()
                if m.keep { cur.append(contentsOf: raw[i..<(i + m.len)]) }
                i += m.len
                continue
            }
            cur.append(raw[i])
            if let last = raw[i].last, ",.;!?".contains(last) || pauses.contains(i) { flush() }
            i += 1
        }
        flush()
        return pieces.map { $0.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: " ,.;!?")) }.filter { !$0.isEmpty }
    }

    // MARK: Labelling

    /// "I was thinking the maid should clean the bathrooms" -> "clean the bathrooms". Nil when it does not start with an action.
    static func actionBody(_ raw: [String]) -> [String]? {
        var t = raw
        var progress = true
        while progress, !t.isEmpty {
            progress = false
            if leadFillers.contains(bare(t[0])) { t.removeFirst(); progress = true; continue }
            if let f = frameList.first(where: { hasPrefix(t, $0) }) { t.removeFirst(f.count); progress = true; continue }
            // "ask the maid to clean", "have the cook make": a delegation
            if delegators.contains(bare(t[0])) {
                for k in 2...min(4, max(t.count - 1, 2)) where k < t.count && ActionLexicon.verbs.contains(bare(t[k])) {
                    let between = t[1..<k].map(bare)
                    if !between.contains(where: { ActionLexicon.verbs.contains($0) && $0 != "to" }) {
                        t.removeFirst(k)
                        progress = true
                    }
                    break
                }
                if progress { continue }
            }
            // "the maid should", "she needs to", "everyone must": a subject and a modal
            if !ActionLexicon.verbs.contains(bare(t[0])) {
                for j in 1...min(3, max(t.count - 1, 1)) where j < t.count && modals.contains(bare(t[j])) {
                    var skip = j + 1
                    if skip < t.count, bare(t[skip]) == "to" { skip += 1 }
                    let subject = t[0..<j].map(bare)
                    let afterDeterminer = determinerSubjects.contains(subject[0]) || ["a", "an"].contains(subject[0])   // "the cook", "my driver"
                    if afterDeterminer || subject.allSatisfy({ !ActionLexicon.verbs.contains($0) }) {
                        t.removeFirst(skip)
                        progress = true
                    }
                    break
                }
            }
        }
        guard t.count >= 2, ActionLexicon.verbs.contains(bare(t[0])) else { return nil }
        return t
    }

    private static func isCorrection(_ b: [String]) -> Bool {
        guard let f = b.first else { return false }
        if f == "sorry", b.count > 1 { return true }
        return [["no", "wait"], ["i", "mean"], ["scratch", "that"], ["make", "that"], ["make", "it"], ["change", "that"]].contains { b.starts(with: $0) }
    }

    private static func occasion(in lower: String) -> String? {
        for o in occasions where o.keys.contains(where: { lower.contains($0) }) { return o.label }
        return nil
    }

    private static func dayLabel(in lower: String) -> String? {
        for d in dayWords where lower.contains(d) { return d == "tonight" ? "Tonight" : d.prefix(1).uppercased() + d.dropFirst() }
        return nil
    }

    private static let dayPhrase = try? NSRegularExpression(
        pattern: #"\b(?:(?:on|by|this|next|coming)\s+)*(?:monday|tuesday|wednesday|thursday|friday|saturday|sunday|tomorrow|today|tonight)\b(?:\s+(?:morning|afternoon|evening|night))?"#,
        options: [.caseInsensitive])

    private static func removingDay(_ s: String) -> String {
        guard let re = dayPhrase else { return s }
        let r = re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: " ")
        return r.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: " ,.-"))
    }

    private static func roleAssignee(in text: String) -> String? {
        guard let who = Assignee.detect(in: text), who != Assignee.me else { return nil }
        return who
    }

    // MARK: The analysis

    static func analyze(_ cleaned: String, words: [SpokenWord] = [], now: Date = Date(), calendar: Calendar = .current) -> LongTurn {
        let ctx = ValidationContext(now: now, calendar: calendar)
        var turn = LongTurn()
        var dates: [Date] = []
        var firstDateLabel: String?

        for (index, piece) in split(cleaned, words: words).enumerated() {
            let raw = piece.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            var core = raw
            while let f = core.first, leadFillers.contains(bare(f)), core.count > 1 { core.removeFirst() }
            let lower = core.joined(separator: " ").lowercased()
            let b = core.map(bare)
            guard core.count >= 2 else { continue }                                 // "okay", "so": nothing to keep

            if isCorrection(b), let last = turn.actions.indices.last {              // "no wait, make that Saturday"
                turn.clauses.append(Clause(text: lower, kind: .correction))
                if let d = TaskValidator.relativeDate(in: lower, ctx: ctx) {
                    for i in turn.actions.indices where turn.actions[i].clause == turn.actions[last].clause {
                        turn.actions[i].due = d
                        turn.actions[i].dueLabel = dayLabel(in: lower)
                    }
                }
                if let who = roleAssignee(in: lower) {
                    for i in turn.actions.indices where turn.actions[i].clause == turn.actions[last].clause { turn.actions[i].assignee = who }
                }
                continue
            }

            if ListOutline.role(of: piece) == .outro { continue }

            if let body = actionBody(raw) {
                turn.clauses.append(Clause(text: lower, kind: .action))
                let bodyText = body.joined(separator: " ")
                let segments = BulkDetector.actionSegments(bodyText)
                let datesInSegments = segments.compactMap { TaskValidator.relativeDate(in: $0, ctx: ctx) }
                let clauseDate = TaskValidator.relativeDate(in: bodyText, ctx: ctx)
                let clauseLabel = dayLabel(in: bodyText.lowercased())
                let single = Set(datesInSegments).count <= 1
                let who = roleAssignee(in: piece)
                for seg in segments {
                    let own = TaskValidator.relativeDate(in: seg, ctx: ctx)
                    let day = own ?? (single ? clauseDate : nil)
                    let label = own != nil ? dayLabel(in: seg.lowercased()) : (single ? clauseLabel : nil)
                    let text = removingDay(seg)
                    guard !text.isEmpty else { continue }
                    let routine = BulkDetector.hasSchedule(text)
                    let title = TaskPlanner.tidyTitle(text, removingDay: false)
                    turn.actions.append(ActionClause(text: text, title: title.isEmpty ? text : title, due: day, dueLabel: label,
                                                     assignee: who, clause: index, source: lower, scheduled: routine))
                }
                continue
            }

            let date = TaskValidator.relativeDate(in: lower, ctx: ctx)
            let occ = occasion(in: lower)
            let person = roleAssignee(in: lower)
            if date != nil || occ != nil || person != nil || TaskValidator.mentionsDate(lower) {
                turn.clauses.append(Clause(text: lower, kind: .context))
                if let d = date { dates.append(d); firstDateLabel = firstDateLabel ?? dayLabel(in: lower) }
                if turn.context.occasion == nil { turn.context.occasion = occ }
                if turn.context.assignee == nil { turn.context.assignee = person }
                continue
            }

            turn.clauses.append(Clause(text: lower, kind: .chatter))
            turn.skipped.append(lower)
        }

        if Set(dates).count == 1 {                                                   // two different days: ask later, never pick one
            turn.context.due = dates[0]
            turn.context.dueLabel = firstDateLabel
        }
        if let o = turn.context.occasion { turn.context.notes = "For " + o }
        return turn
    }
}

// MARK: The digest the model reads instead of the whole ramble

extension LongTurnAnalyzer {
    /// "Context: Saturday, for in-laws." then one line per action. Fits `budget` characters by shortening the longest lines'
    /// wording, never by dropping the first action or cutting the front.
    static func digest(context: SharedContext, actions: [ActionClause], budget: Int = 900) -> String {
        func render(_ maxWords: Int) -> String {
            var lines: [String] = []
            if let used = context.usedLine { lines.append("Context: " + String(used.prefix(120)) + ".") }
            for a in actions {
                let words = a.text.split(whereSeparator: { $0.isWhitespace })
                var text = words.prefix(maxWords).joined(separator: " ")
                if words.count > maxWords { text += "…" }
                var extra: [String] = []
                if let d = a.dueLabel { extra.append(d) }
                if let who = a.assignee { extra.append(who) }
                lines.append("- " + text + (extra.isEmpty ? "" : " (" + extra.joined(separator: ", ") + ")"))
            }
            return lines.joined(separator: "\n")
        }
        var maxWords = 14
        var out = render(maxWords)
        while out.count > budget, maxWords > 3 {
            maxWords -= 1
            out = render(maxWords)
        }
        return out
    }

    /// Groups of at most `size` actions for separate model calls, at most `maxCalls` groups. What does not fit is returned
    /// as `rest` and goes to the rule planner.
    static func chunks(_ actions: [ActionClause], size: Int = 4, maxCalls: Int = 3) -> (groups: [[ActionClause]], rest: [ActionClause]) {
        var groups: [[ActionClause]] = []
        var i = 0
        while i < actions.count, groups.count < maxCalls {
            groups.append(Array(actions[i..<min(i + size, actions.count)]))
            i += size
        }
        return (groups, i < actions.count ? Array(actions[i...]) : [])
    }
}
