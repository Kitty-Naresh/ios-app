import Foundation

/// "I don't know", "no idea", "nothing": a hesitation is not an answer and not a request.
/// Kitty says plainly that it is unclear, that she did nothing, and what she can do. Decided here in Swift, never by the model:
/// the model once turned "I don't know" (after "What would you like the task to be?") into "show everything".
enum UnclearAnswer {
    /// The one reply for anything with no clear action. Short, spoken, and honest that nothing was done.
    static let message = "I'm not sure what you'd like, so I haven't done anything. I'm Kitty, your house help: I can add tasks, organise them in a meaningful way, and read them back to you whenever you ask."

    static var reply: AgentReply { AgentReply(message: message, didAdd: false) }

    /// Words that only lead into or trail off a hesitation ("um, I don't know what", "hmm, no idea, sorry").
    private static let leading: Set<String> = ["um", "uh", "umm", "uhh", "er", "erm", "hmm", "hm", "mm", "ah", "oh", "well", "so", "like", "okay", "ok", "honestly", "actually"]
    private static let trailing: Set<String> = ["what", "yet", "really", "honestly", "sorry", "kitty", "anymore", "right", "now", "at", "the", "moment",
                                                "to", "say", "be", "just", "actually", "exactly", "myself", "either", "sure", "though", "hmm", "um", "uh"]

    private static let phrases: Set<String> = [
        "i dont know", "dont know", "i do not know", "do not know", "i dunno", "dunno", "idk", "i dont know yet", "i dont know what",
        "no idea", "i have no idea", "i got no idea", "i have no clue", "no clue", "not sure", "i am not sure", "im not sure", "i am not certain",
        "im not certain", "not certain", "i am unsure", "im unsure", "unsure", "i cant think", "i cant think of anything",
        "i cant remember", "i cant decide", "i forgot", "i forget", "nothing", "nothing really", "nothing much", "nothing at all",
        "hmm", "hm", "mm", "uh", "um", "who knows", "not a clue", "dont have one",
        "i dont have one", "i dont have anything", "i have nothing", "i have nothing to say", "nothing to say"
    ]

    /// True when the whole utterance is a hesitation or a non-answer. "Never mind" and "cancel" are not (they have their own handling),
    /// and neither is a sentence that goes on to say something real ("I don't know, maybe call the plumber").
    static func matches(_ raw: String) -> Bool {
        var words = VoiceTurnManager.norm(raw.replacingOccurrences(of: "’", with: "'")).split(separator: " ").map(String.init)
        words.removeAll { ["really", "honestly", "actually", "truly", "genuinely", "just"].contains($0) }     // "I really don't know"
        while let f = words.first, leading.contains(f), words.count > 1 { words.removeFirst() }
        if phrases.contains(words.joined(separator: " ")) { return true }
        while let l = words.last, trailing.contains(l), words.count > 1 {
            words.removeLast()
            if phrases.contains(words.joined(separator: " ")) { return true }
        }
        return false
    }

    /// Did the person ask to see or hear something? Used before any list or read-back runs: an utterance with none of
    /// these words is never answered by listing everything.
    static func hasQueryIntent(_ raw: String) -> Bool {
        let text = raw.lowercased().replacingOccurrences(of: "’", with: "'")
        if text.contains("?") { return true }
        let words = Set(VoiceTurnManager.norm(text).split(separator: " ").map(String.init))
        let cues: Set<String> = [
            "show", "list", "what", "whats", "which", "who", "whom", "when", "how", "read", "tell", "any", "anything", "give", "see",
            "view", "display", "check", "remind", "reminders", "task", "tasks", "chore", "chores", "todo", "todos", "routine", "routines",
            "playbook", "playbooks", "agenda", "schedule", "overdue", "pending", "open", "completed", "finished", "done", "left",
            "remaining", "outstanding", "backlog", "today", "tomorrow", "everything", "order", "cart", "basket", "mine", "anyone",
            "someone", "did", "do", "does", "have", "has", "is", "are"
        ]
        if !words.isDisjoint(with: cues) { return true }
        return text.contains("to do") || text.contains("to-do")
    }

    /// The actions the validator knows. Anything else (an empty or invented action) is not guessed at.
    private static let knownActions: Set<String> = [
        "clarify", "unrelated", "view_tasks", "complete_task", "delete_task", "update_task",
        "create_task", "create_routine", "create_playbook", "playbook", "teach_playbook"
    ]

    /// True when the model's answer has no clear action Kitty should carry out: a view from words that ask for nothing, or an
    /// empty/unknown action on speech that names nothing to do. Never a reason to list or read back everything.
    static func shouldDecline(_ validated: Validated, decision d: AgentDecisionValue, utterance: String) -> Bool {
        if case .view = validated, isUnclear(utterance) { return true }
        let action = d.action.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !d.wait, !knownActions.contains(action) else { return false }
        let said = LocalSemanticPrechecker.tokens(utterance)
        return matches(utterance) || !said.contains { ActionLexicon.verbs.contains($0) }
    }

    /// A request that is not a request: no hesitation recogniser hit, but nothing to act on either.
    static func isUnclear(_ raw: String) -> Bool { matches(raw) || !hasQueryIntent(raw) }
}
