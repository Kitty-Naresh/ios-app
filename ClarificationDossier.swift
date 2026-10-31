import Foundation

/// Everything a clarification loop knows, kept in one place so the model always sees the whole story: the request as it was
/// first said, every question Kitty asked and every answer it got, and the one thing
/// still missing. Held by `ClarificationStateManager` from the first question until the loop ends.
///
/// Why it exists: the prompt used to carry one `You asked / They answered` line inside a 300-character context that was cut
/// from the end, so the answer could be sliced mid-word, earlier rounds were never sent, and the no-model path saw only the
/// last answer. The dossier has its own budget, and it shrinks the filler first, never the original, a question or an answer.
struct ClarificationDossier: Equatable {
    struct Round: Equatable {
        var question: String
        var field: MissingField
        var answer: String?
    }

    /// The first thing the user said, cleaned. Frozen once the first question is registered.
    private(set) var original = ""
    private(set) var rounds: [Round] = []
    private(set) var missing: MissingField?

    /// The most the dossier adds to a prompt. The context line it replaces was limited to 300 characters.
    static let defaultBudget = 800

    var isEmpty: Bool { original.isEmpty && rounds.isEmpty }
    var hasRounds: Bool { !rounds.isEmpty }
    var answers: [String] { rounds.compactMap(\.answer).filter { !$0.isEmpty } }
    var questions: [String] { rounds.map(\.question) }

    // MARK: Writing

    /// The request so far. Only until the first question: after that the original is frozen, so a long running turn
    /// ("…the house help. To cook rotis… Cook rotis tonight.") can never replace it with a longer version.
    mutating func noteOriginal(_ utterance: String) {
        guard rounds.isEmpty else { return }
        original = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    mutating func ask(question: String, field: MissingField) {
        rounds.append(Round(question: question, field: field, answer: nil))
        missing = field
    }

    /// Sets (never appends to) the answer of the open question: a user who keeps talking after Kitty asked gives a longer
    /// answer to the same question, not a second one.
    mutating func answer(_ text: String) {
        guard !rounds.isEmpty else { return }
        rounds[rounds.count - 1].answer = text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Reading

    static func describe(_ field: MissingField) -> String {
        switch field {
        case .action: return "what the task itself is (what has to be done)"
        case .object: return "what exactly to do, or what it is about"
        case .target: return "which existing task is meant"
        case .schedule: return "how often or on which days it repeats"
        case .oneTimeOrRoutine: return "whether it is one-time or repeating"
        case .steps: return "the steps to include"
        case .change: return "what to change"
        case .validation: return "what the user meant"
        }
    }

    /// The text that goes into a model prompt. Fixed order: the request, each question with its answer, and what is still
    /// missing. When it is too long each text is shortened from the end. The original, the questions and the answers are always present.
    func rendered(budget: Int = defaultBudget) -> String {
        guard !isEmpty else { return "" }
        let attempts: [Int] = [10_000, 220, 140, 90]
        var last = ""
        for cap in attempts {
            last = render(cap: cap)
            if last.count <= budget { return last }
        }
        return last
    }

    private func render(cap: Int) -> String {
        func clip(_ s: String, _ limit: Int) -> String {
            let t = s.replacingOccurrences(of: "\"", with: "'")
            guard t.count > limit else { return t }
            return String(t.prefix(limit - 1)) + "…"
        }
        // The original keeps a larger share than the rest: it is the one text nothing else can replace.
        let originalCap = cap >= 10_000 ? cap : max(cap * 2, 180)
        var lines: [String] = []
        if !original.isEmpty { lines.append("Original request: “\(clip(original, originalCap))”") }
        for r in rounds {
            if let a = r.answer, !a.isEmpty {
                lines.append("You asked: “\(clip(r.question, cap))” They answered: “\(clip(a, cap))”.")
            } else {
                lines.append("You asked: “\(clip(r.question, cap))” (no answer yet).")
            }
        }
        if let m = missing { lines.append("Still missing: \(Self.describe(m)).") }
        return lines.joined(separator: "\n")
    }

    // MARK: For paths with no model

    /// The whole request for a fallback that has to decide on its own: the utterance when it already holds the original (one
    /// running turn), otherwise the original followed by every answer (each answer was said as its own turn).
    func fullText(with utterance: String) -> String {
        guard !original.isEmpty else { return utterance }
        let said = VoiceTurnManager.norm(utterance), first = VoiceTurnManager.norm(original)
        if said.hasPrefix(first) { return utterance }
        return ([original] + (answers.isEmpty ? [utterance] : answers)).joined(separator: " ")
    }
}
