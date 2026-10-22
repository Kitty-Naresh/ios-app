import Foundation

/// Words that stand in for a task without being one: "the project", "it", "that thing", "something", "project work".
/// A request that names only these ("add a task for the project") has no action and no specifics, so Kitty asks what the
/// task is instead of creating a task titled "Project". Decided in Swift, never by the model.
enum VaguePlaceholder {
    /// Words that only point at something ("the", "that", "my"). They never make a phrase specific.
    static let pointers: Set<String> = ["the", "a", "an", "my", "our", "your", "this", "that", "these", "those", "some", "any",
                                        "whole", "entire", "another", "other", "new", "same"]

    /// Generic nouns and pronouns that name no action: the word itself says nothing about what to do.
    static let generics: Set<String> = [
        "project", "projects", "task", "tasks", "work", "works", "thing", "things", "stuff", "something", "anything", "everything",
        "it", "them", "one", "ones", "item", "items", "job", "jobs", "chore", "chores", "errand", "errands", "todo", "todos",
        "matter", "issue", "issues", "misc", "miscellaneous"
    ]

    /// A bare place: "add a task for the kitchen" names where, not what. Only used for a request that is clearly "a task for X",
    /// never to judge a model title ("The bathroom" keeps its own, older question).
    static let places: Set<String> = [
        "house", "home", "kitchen", "bathroom", "bedroom", "garden", "garage", "balcony", "office", "yard", "apartment", "flat",
        "room", "hall", "terrace", "living", "dining", "master", "guest"
    ]

    /// Every word is a pointer, a generic noun or (optionally) a bare place, and at least one is not a pointer.
    static func isVague(_ words: [String], allowPlaces: Bool = false) -> Bool {
        guard words.contains(where: { !pointers.contains($0) }) else { return false }
        return words.allSatisfy { pointers.contains($0) || generics.contains($0) || (allowPlaces && places.contains($0)) }
    }

    /// A task title that says nothing: "Project", "The project", "Project task", "It".
    static func isVague(title: String) -> Bool {
        isVague(LocalSemanticPrechecker.tokens(title))
    }

    private static let openers: [[String]] = [["can", "you"], ["could", "you"], ["would", "you"], ["i", "want", "to"], ["i", "need", "to"],
                                              ["i", "would", "like", "to"], ["i'd", "like", "to"], ["let's"], ["lets"], ["please"]]
    private static let connectors: Set<String> = ["for", "about", "on", "regarding", "re", "to", "with", "called", "named", "around", "related"]

    /// What follows "add a task for ..." in a request to add a task, or nil if the sentence is not that. "Add a task for
    /// the project: review budget" gives all of "the project review budget", so anything specific makes it not vague.
    static func subject(ofRequest utterance: String) -> [String]? {
        var t = LocalSemanticPrechecker.tokens(utterance)
        var stripped = true
        while stripped {
            stripped = false
            for o in openers where t.starts(with: o) && t.count > o.count { t.removeFirst(o.count); stripped = true; break }
        }
        guard let verb = t.first, ["add", "create", "make", "new", "put"].contains(verb) else { return nil }
        t.removeFirst()
        while let w = t.first, ["a", "an", "another", "new"].contains(w) { t.removeFirst() }
        guard let noun = t.first, ["task", "todo", "reminder"].contains(noun) else { return nil }
        t.removeFirst()
        if let c = t.first, connectors.contains(c) { t.removeFirst() }
        return t.isEmpty ? nil : t
    }

    /// The question for "add a task for the project" / "add a task for it" / "add a task for the kitchen", or nil when the
    /// request names something specific ("add a task for the project: review budget", "add a task to call the project manager").
    static func question(forRequest utterance: String) -> String? {
        guard let words = subject(ofRequest: utterance), isVague(words, allowPlaces: true) else { return nil }
        let named = words.filter { !pointers.contains($0) }
        if named.contains(where: { $0 == "project" || $0 == "projects" }) { return "What would you like the task to be for the project?" }
        if let place = named.first(where: { places.contains($0) && $0 != "living" && $0 != "dining" && $0 != "master" && $0 != "guest" }) {
            return place == "home" ? "What would you like the task to be at home?" : "What would you like the task to be for the \(place)?"
        }
        return ClarificationStateManager.fallbackQuestion(for: .action)
    }

    /// The question to ask about a model title that is only a placeholder.
    static func question(forTitle title: String) -> String {
        let named = LocalSemanticPrechecker.tokens(title).filter { !pointers.contains($0) }
        if named.contains(where: { $0 == "project" || $0 == "projects" }) { return "What would you like the task to be for the project?" }
        return ClarificationStateManager.fallbackQuestion(for: .action)
    }
}
