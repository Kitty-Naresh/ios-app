import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - What one model call may carry

// The model's window is shared by the instructions, the output schema, the prompt and the answer. Swift sends state
// (the draft, the open question, what just changed, the new words), not the conversation, and measures it against the window
// instead of guessing from characters. When it does not fit, whole kinds of context are dropped in a fixed order. The user's
// new words are never cut and no requested item is silently left out.

/// Which call is being sized: each has its own schema. No call has tools.
enum CallKind: Equatable, Sendable {
    case extract            // new words with no draft waiting: the extraction schema
    case review             // words about a draft that waits: the edit schema
}

/// The fixed cost of a call kind, the window, and what is left for the prompt.
struct ContextBudget: Equatable, Sendable {
    var window: Int
    var instructions: Int
    var schema: Int
    /// True when the numbers were counted by the model's own tokenizer, false when they are estimates.
    var exact: Bool
    /// Room kept for the model's answer.
    var reserve = 1_200
    /// Room kept so a small miscount is not an overflow.
    var margin = 300

    var fixed: Int { instructions + schema }
    /// What the prompt itself may use.
    var inputRoom: Int { max(200, window - fixed - reserve - margin) }

    /// The window to assume when the model cannot say (an older system, or no model).
    static let fallbackWindow = 4_096
    /// Estimates for what cannot be counted, from measurements on the model (see REAL_MODEL_RUNS.md).
    static let estimatedSchema: [CallKind: Int] = [.extract: 1_100, .review: 2_300]

    static func estimate(_ text: String) -> Int { Trace.estimatedTokens(text.count) }

    /// A budget made only of estimates.
    static func estimated(_ kind: CallKind, window: Int = fallbackWindow) -> ContextBudget {
        ContextBudget(window: window, instructions: estimate(kind == .extract ? PersistentInstructions.text : PersistentInstructions.review), schema: estimatedSchema[kind] ?? 900, exact: false)
    }

    /// `input 1,430 of 8,192 tokens | instructions 720, schema 910, prompt 540, answer reserve 1,200 (counted)`
    func line(prompt: Int, promptExact: Bool) -> String {
        let total = fixed + prompt
        let counted = exact && promptExact
        return "\(total.formatted()) of \(window.formatted()) tokens used before the answer | instructions \(instructions.formatted()), schema \(schema.formatted()), prompt \(prompt.formatted()) | answer reserve \(reserve.formatted()), margin \(margin.formatted()) | \(counted ? "counted by the model" : "estimated")"
    }
}

// MARK: - The conversation, kept here and not sent

/// Every turn of the conversation, kept locally: the words, what Kitty did to the draft, and what it said. It is not sent to the model
/// as history. Only the last few changes go into the snapshot, as the referents a short follow-up needs ("remove them", "undo that").
final class ConversationLog {
    struct Entry: Equatable {
        var words: String
        var action: String
        var change: String          // what Swift did to the draft, in the words of the card ("Removed book cardamom.")
        var touched: [String]       // the refs it touched
        var reply: String
        var at = Date()
    }

    private(set) var entries: [Entry] = []

    func record(words: String, action: String, change: String = "", touched: [String] = [], reply: String = "") {
        entries.append(Entry(words: words, action: action, change: change, touched: touched, reply: reply))
    }

    /// A new draft starts a new story: the earlier changes are not about it.
    func reset() { entries = [] }

    /// Every thing said while this draft has lived, numbered, with what it produced: `L1 "buy milk and book a cab" -> created d1, d2`,
    /// `L2 "make it high" -> Changed d2. (d2)`. Only the last `limit` are returned, but the numbers are the real ones, so "line 2"
    /// stays line 2. Older lines are shortened (never the newest); the user's newest words are not here at all, they are `USER:`.
    func lines(limit: Int = 3, shortenOlderTo characters: Int = 120) -> [String] {
        let all = entries.enumerated().map { n, e -> (Int, Entry) in (n + 1, e) }
        return all.suffix(limit).enumerated().map { i, pair in
            let (number, e) = pair
            let newest = i == min(limit, all.count) - 1
            var said = e.words.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\"", with: "'")
            if !newest, said.count > characters { said = String(said.prefix(characters * 2 / 3)) + " … " + String(said.suffix(characters / 3)) }
            let refs = e.touched.isEmpty ? "" : " " + e.touched.joined(separator: ", ")
            let result: String
            switch e.action {
            case "create": result = "created" + refs
            case "add": result = "added" + refs
            case "none", "answer": result = "answered, no change"
            case "failed": result = "no answer"
            default: result = e.change.isEmpty ? e.action + refs : e.change + (e.touched.isEmpty ? "" : " (" + e.touched.joined(separator: ", ") + ")")
            }
            return "L\(number) \"\(said)\" -> \(result)"
        }
    }

    /// The last few changes Swift made, newest last, one line each: `Removed book cardamom. (d2, d3)`.
    func recentChanges(limit: Int = 3) -> [String] {
        entries.filter { !$0.change.isEmpty }.suffix(limit).map { e in
            e.change + (e.touched.isEmpty ? "" : " (" + e.touched.joined(separator: ", ") + ")")
        }
    }
}

// MARK: - The snapshot

/// What the draft-edit call is told, before it is sized.
struct DraftSnapshot {
    var now: Date
    var calendar: Calendar = .current
    var items: [DraftItem]
    var version: Int
    var newWords: String
    var originalWords: String
    var skipped: [String] = []
    var openQuestion: String = ""
    var recentChanges: [String] = []
    var vocabulary: String = ""
    /// The numbered lines said so far with what each produced (`ConversationLog.lines`). Empty: no section.
    var lines: [String] = []
}

/// How much of the snapshot is sent.
struct SnapshotLevel: Equatable {
    enum Vocabulary: Int { case full, relevant, none }
    enum Items: Int { case full, compact, titles }
    var vocabulary: Vocabulary
    var items: Items
    var skipped: Bool
    /// Names for the trace.
    var name: String { "vocabulary \(vocabulary), items \(items), skipped \(skipped ? "kept" : "dropped")" }
}

/// What came out of sizing a snapshot.
struct AssembledPrompt: Equatable {
    var prompt: String
    var level: SnapshotLevel
    var tokens: Int
    var exact: Bool
    /// What was left out to fit, in words, for the trace and the live view.
    var dropped: [String]
    /// Even the smallest snapshot did not fit.
    var overBudget: Bool
}

enum ContextAssembler {
    /// The draft-edit prompt, the fullest one that fits the room. It starts from the vocabulary the words and items mention (never
    /// the whole list). Order of dropping: that vocabulary, the skipped chatter, then the detail of each item (all fields, title and
    /// category, title only).
    /// The new words, the open question, the recent changes and the list's refs are always there.
    /// The smallest level is every title with its ref: refs are what the model's edits name, so they are never left out. If even
    /// that is over the room, the caller says so and the call is still made.
    static func draftEdit(_ s: DraftSnapshot, room: Int, count: (String) async -> (tokens: Int, exact: Bool)) async -> AssembledPrompt {
        let levels: [SnapshotLevel] = [
            .init(vocabulary: .relevant, items: .full, skipped: true),
            .init(vocabulary: .none, items: .full, skipped: true),
            .init(vocabulary: .none, items: .full, skipped: false),
            .init(vocabulary: .none, items: .compact, skipped: false),
            .init(vocabulary: .none, items: .titles, skipped: false),
        ]
        var last: AssembledPrompt?
        for level in levels {
            let text = DraftReviewPrompt.build(s, level: level)
            let n = await count(text)
            let made = AssembledPrompt(prompt: text, level: level, tokens: n.tokens, exact: n.exact, dropped: dropped(level),
                                       overBudget: n.tokens > room)
            if n.tokens <= room { return made }
            last = made
        }
        return last!
    }

    private static func dropped(_ level: SnapshotLevel) -> [String] {
        var out: [String] = []
        switch level.vocabulary {
        case .full: break
        case .relevant: out.append("names the words do not mention")
        case .none: out.append("the names list")
        }
        if !level.skipped { out.append("heard-but-skipped chatter") }
        switch level.items {
        case .full: break
        case .compact: out.append("item details beyond title and category")
        case .titles: out.append("item details (titles only, with their refs)")
        }
        return out
    }

    /// The extraction prompt for new words with no draft waiting. It carries only the categories and people the words
    /// mention; if even that does not fit, none. The transcript is never cut here; a turn too long for one call is split by sentence.
    static func extraction(utterance: String, pending: String?, categories: [String], people: [String], now: Date,
                           calendar: Calendar = .current, dossier: String = "", room: Int,
                           count: (String) async -> (tokens: Int, exact: Bool)) async -> AssembledPrompt {
        func make(_ v: SnapshotLevel.Vocabulary) -> String {
            switch v {
            case .full, .relevant:
                return PromptBuilder.build(utterance: utterance, pending: pending, knownCategories: categories,
                                           knownPeople: people, now: now, calendar: calendar, dossier: dossier, onlyMentioned: true)
            case .none:
                return PromptBuilder.build(utterance: utterance, pending: pending, knownCategories: [], knownPeople: [],
                                           now: now, calendar: calendar, dossier: dossier, includeVocabulary: false)
            }
        }
        var last: AssembledPrompt?
        for v in [SnapshotLevel.Vocabulary.relevant, .none] {
            let level = SnapshotLevel(vocabulary: v, items: .full, skipped: true)
            let text = make(v)
            let n = await count(text)
            let made = AssembledPrompt(prompt: text, level: level, tokens: n.tokens, exact: n.exact, dropped: dropped(level),
                                       overBudget: n.tokens > room)
            if n.tokens <= room { return made }
            last = made
        }
        return last!
    }

    /// Only the names and categories a text mentions, from the one-per-kind vocabulary block.
    static func relevantVocabulary(_ vocabulary: String, to text: String) -> String {
        let seen = text.lowercased()
        var lines: [String] = []
        for line in vocabulary.split(separator: "\n").map(String.init) {
            guard let colon = line.firstIndex(of: ":"), ["Categories", "People"].contains(String(line[..<colon])) else { continue }
            let terms = line[line.index(after: colon)...].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && $0 != "none" && seen.contains($0.lowercased()) }
            if !terms.isEmpty { lines.append(String(line[..<colon]) + ": " + terms.joined(separator: ", ")) }
        }
        return lines.isEmpty ? "" : "Reference vocabulary (spellings only, not facts about this request):\n" + lines.joined(separator: "\n")
    }
}
