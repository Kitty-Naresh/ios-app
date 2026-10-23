import Foundation

// MARK: - Speech locale preference

/// Which English the recogniser listens for. "auto" follows the phone; "en-IN" tunes it for Indian English
/// (names like Rani, Priya or Suresh, and the accent). Read each time a recogniser is created.
nonisolated enum SpeechLocalePreference {
    static let key = "kitty.speechLocale"
    static let indianEnglish = "en-IN"

    static var isIndianEnglish: Bool {
        get { UserDefaults.standard.string(forKey: key) == indianEnglish }
        set { UserDefaults.standard.set(newValue ? indianEnglish : "auto", forKey: key) }
    }

    static var locale: Locale {
        isIndianEnglish ? Locale(identifier: indianEnglish) : .current
    }
}

// MARK: - Words the recogniser should expect

/// Builds the `contextualStrings` for a recognition request: the names this household actually says.
/// Without them "Rani" is heard as "Rainy" and "Blinkit" as "blank it".
nonisolated enum VocabularyProvider {
    /// Apple documents this as a hint list; keep it short so every entry carries weight.
    static let limit = 100
    static let maxWordsPerPhrase = 4

    /// Most useful first: people, then lists and categories, then playbooks and routines, then names from the household notes.
    static func build(assignees: [String] = [], profiles: [String] = [], categories: [String] = [],
                      playbooks: [String] = [], routines: [String] = [], household: String = "") -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        func add(_ phrase: String) {
            let p = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = p.lowercased()
            guard !p.isEmpty, p.count <= 40, p.split(separator: " ").count <= maxWordsPerPhrase,
                  out.count < limit, seen.insert(key).inserted else { return }
            out.append(p)
        }
        assignees.forEach(add)
        profiles.forEach(add)
        categories.forEach(add)
        playbooks.forEach(add)
        routines.forEach(add)
        capitalisedNames(in: household).forEach(add)
        return out
    }

    /// "Rani cooks, Suresh drives": the capitalised words that are not the first word of a sentence.
    static func capitalisedNames(in text: String) -> [String] {
        var names: [String] = []
        var startsSentence = true
        for raw in text.split(whereSeparator: { $0.isWhitespace }) {
            let word = raw.trimmingCharacters(in: .punctuationCharacters)
            defer { startsSentence = raw.last.map { ".!?\n".contains($0) } ?? false }
            guard word.count > 2, let first = word.first, first.isUppercase, !startsSentence,
                  word.dropFirst().allSatisfy({ $0.isLetter }), !commonWords.contains(word.lowercased()) else { continue }
            names.append(word)
        }
        return names
    }

    private static let commonWords: Set<String> = ["the", "and", "our", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday",
                                                   "sunday", "january", "february", "march", "april", "may", "june", "july", "august",
                                                   "september", "october", "november", "december", "kitty"]

    /// People already named on tasks, routines or playbook steps, most frequent first.
    @MainActor static func people(store: TaskStore = .shared) -> [String] {
        var all: [String] = []
        func person(_ n: String?) { if let n, !n.isEmpty { all.append(n) } }
        for t in store.tasks { person(t.assignee) }
        for r in store.routines { person(r.assignee) }
        for p in store.playbooks { for s in p.steps { person(s.assignee) } }
        // The people who show up most are the ones most likely to be said again.
        let counts = Dictionary(all.map { ($0.lowercased(), 1) }, uniquingKeysWith: +)
        var seen = Set<String>()
        let unique = all.filter { seen.insert($0.lowercased()).inserted }
        return unique.sorted { (counts[$0.lowercased()] ?? 0, $1) > (counts[$1.lowercased()] ?? 0, $0) }
    }

    /// The vocabulary from what is saved right now. Called each time a recognition session starts, so a name added a minute ago counts.
    @MainActor static func current(store: TaskStore = .shared, household: String = KittyGuideStore.household) -> [String] {
        return build(assignees: people(store: store),
                     profiles: store.profiles.map(\.name),
                     categories: store.knownCategoryNames,
                     playbooks: store.playbooks.map(\.name),
                     routines: store.routines.map(\.title),
                     household: household)
    }
}
