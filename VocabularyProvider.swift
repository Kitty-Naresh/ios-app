import Foundation
#if canImport(UIKit)
import UIKit
#endif

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
        // The brand list comes first (Blinkit, Swiggy, Zomato…): the same words Whisper's prompt starts with.
        let brands = IndianVocabulary.brands
        let rest = build(assignees: people(store: store),
                     profiles: store.profiles.map(\.name),
                     categories: store.knownCategoryNames,
                     playbooks: store.playbooks.map(\.name),
                     routines: store.routines.map(\.title),
                     household: household)
        var seen = Set(brands.map { $0.lowercased() })
        return brands + rest.filter { seen.insert($0.lowercased()).inserted }
    }
}

// MARK: - Words that may have been misheard

/// A word in a task title that is not a word and sounds like one of the household's own words ("Detal" for "Dettol") is offered
/// back as a question on the card. Nothing is rewritten: the user decides, and the title stays as it was heard. The match is what
/// the old `VocabularyMatcher` did (a consonant skeleton that sounds alike, plus a small edit distance), kept small and without a
/// word list of its own: the words come from what this household has said (`VocabularyProvider.spellingVocabulary`).
nonisolated enum SpellingHints {
    /// "detal" and "dettol" both become "dtl": the first letter, then consonants, with doubles and look-alike letters merged.
    static func soundKey(_ word: String) -> String {
        var out = ""
        let letters = word.lowercased().filter { $0.isLetter }
        for (n, c) in letters.enumerated() {
            let mapped: Character
            switch c {
            case "c", "q": mapped = "k"
            case "z": mapped = "s"
            default: mapped = c
            }
            if n > 0, "aeiouyhw".contains(mapped) { continue }
            if out.last == mapped { continue }
            out.append(mapped)
        }
        return out
    }

    static func distance(_ a: String, _ b: String) -> Int {
        let x = Array(a.lowercased()), y = Array(b.lowercased())
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }
        var row = Array(0...y.count)
        for i in 1...x.count {
            var diagonal = row[0]
            row[0] = i
            for j in 1...y.count {
                let above = row[j]
                row[j] = x[i - 1] == y[j - 1] ? diagonal : min(diagonal, row[j], row[j - 1]) + 1
                diagonal = above
            }
        }
        return row[y.count]
    }

    /// The system's spell checker does not know the word. Where there is no checker the answer is "known": nothing is flagged.
    static func isUnknownWord(_ word: String) -> Bool {
        #if canImport(UIKit)
        let w = word.trimmingCharacters(in: .punctuationCharacters)
        guard w.count >= 4 else { return false }
        let range = UITextChecker().rangeOfMisspelledWord(in: w, range: NSRange(location: 0, length: (w as NSString).length),
                                                          startingAt: 0, wrap: false, language: "en_US")
        return range.location != NSNotFound
        #else
        return false
        #endif
    }

    /// The one household word that sounds like `word` and is a letter or two away, or nil. Two equally good words give nil.
    static func suggestion(for word: String, among vocabulary: [String]) -> String? {
        let w = word.lowercased().filter { $0.isLetter }
        guard w.count >= 4 else { return nil }
        var seen = Set<String>()
        var best: (word: String, distance: Int)?
        var tied = false
        for phrase in vocabulary {
            for piece in phrase.split(whereSeparator: { !$0.isLetter }).map(String.init) where piece.count >= 4 {
                let c = piece.lowercased()
                guard c != w, seen.insert(c).inserted, abs(c.count - w.count) <= 2, soundKey(c) == soundKey(w) else { continue }
                let d = distance(c, w)
                guard d <= (max(c.count, w.count) <= 5 ? 1 : 2) else { continue }
                if let b = best {
                    if d < b.distance { best = (piece, d); tied = false } else if d == b.distance { tied = true }
                } else { best = (piece, d) }
            }
        }
        return tied ? nil : best?.word
    }

    /// Notes for one task's card row: a word that may be a household word, or a word the recogniser was not sure of. Nothing is changed.
    /// A word the household already uses, or that the spell checker knows, is left alone.
    static func advisories(forTitle title: String, lowConfidence: Set<String>, vocabulary: [String]) -> [String] {
        let known = Set(vocabulary.flatMap { $0.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init) })
        var notes: [String] = []
        for raw in title.split(whereSeparator: { !$0.isLetter }).map(String.init) where raw.count >= 4 {
            let w = raw.lowercased()
            if known.contains(w) { continue }
            if isUnknownWord(raw), let s = suggestion(for: raw, among: vocabulary) {
                notes.append("I heard “\(raw)”. Did you mean “\(s)”?")
            } else if lowConfidence.contains(w) {
                notes.append("I wasn't sure I heard “\(raw)” right.")
            }
        }
        return notes
    }
}

extension VocabularyProvider {
    /// The words this household has used: its names, lists and categories, and the words of its past task titles.
    @MainActor static func spellingVocabulary(store: TaskStore = .shared) -> [String] {
        var out = current(store: store)
        var seen = Set(out.map { $0.lowercased() })
        for t in store.tasks.prefix(400) {
            for word in t.title.split(whereSeparator: { !$0.isLetter }).map(String.init) where word.count >= 4 {
                if seen.insert(word.lowercased()).inserted { out.append(word) }
            }
        }
        return out
    }
}
