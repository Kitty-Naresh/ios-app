import Foundation

// MARK: - Repairing a brand the recogniser split or misspelled

/// Fixes near-misses of brands and Indian household words in what was heard: "blink it" to "Blinkit", "Maggie" to "Maggi",
/// "parle g" to "Parle-G", "zip tow" to "Zepto". Conservative on purpose: a repair is made only when exactly one term in the
/// list is clearly the closest, and short or everyday words are never touched. Anything doubtful is left alone for the
/// existing "Did you say…?" read-back to deal with.
///
/// Uses the same ideas as `VocabularyMatcher` (edit distance and a sound-alike key), over a window of one to three words.
nonisolated enum BrandFixer {
    struct Change: Equatable {
        var from: String
        var to: String
    }

    struct Result: Equatable {
        var text: String
        var changes: [Change]
    }

    /// Terms that are also plain English words (or whose near-misses are): never repaired towards, even though they are
    /// useful as key terms for the recogniser.
    static let notForRepair: Set<String> = ["driver", "cook", "maid", "curd", "fortune", "masala", "everest", "tiffin",
                                           "puja", "holi", "catch", "more", "real juice", "chai", "roti"]

    /// Terms shorter than this are skipped: too many ordinary words sit one letter away.
    static let minimumLetters = 5

    static var defaultTerms: [String] {
        IndianVocabulary.terms.filter { !notForRepair.contains($0.lowercased()) }
    }

    /// Little words that make a multi-word window ordinary speech, not a split brand: "pay them" is not "Paytm".
    /// (A window that matches a term exactly once spaces are ignored, like "blink it", is still repaired.)
    static let functionWords: Set<String> = ["the", "them", "they", "then", "you", "your", "to", "a", "an", "and", "or", "for", "of", "in",
                                            "on", "at", "is", "it", "be", "we", "he", "she", "me", "my", "so", "do", "go", "up", "if",
                                            "as", "by", "are", "was", "can", "will", "this", "that", "with", "not", "no", "now", "get",
                                            "buy", "pay", "call", "ask", "tell", "take", "put", "set", "add", "make"]

    /// `protectedNames` are words that must never be changed because the household uses them (a person called Maggie).
    static func fix(_ text: String, terms: [String] = BrandFixer.defaultTerms, protectedNames: [String] = []) -> Result {
        let protected = Set(protectedNames.map { VocabularyMatcher.letters($0) }.filter { !$0.isEmpty })
        let candidates: [(term: String, letters: String, key: String)] = terms.compactMap { t in
            let l = VocabularyMatcher.letters(t)
            guard l.count >= minimumLetters else { return nil }
            return (t, l, VocabularyMatcher.phoneticKey(t))
        }
        guard !candidates.isEmpty, let regex = try? NSRegularExpression(pattern: "\\S+") else { return Result(text: text, changes: []) }

        let ns = text as NSString
        let tokens = regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { m -> Token in
            Token(range: m.range, raw: ns.substring(with: m.range))
        }
        var replacements: [(range: NSRange, text: String)] = []
        var changes: [Change] = []
        var i = 0
        while i < tokens.count {
            var fixed = false
            for n in stride(from: min(3, tokens.count - i), through: 1, by: -1) {
                let window = Array(tokens[i..<(i + n)])
                guard let replacement = repair(window, among: candidates, protected: protected) else { continue }
                let range = NSRange(location: window[0].range.location,
                                    length: window[n - 1].range.upperBound - window[0].range.location)
                replacements.append((range, replacement.text))
                changes.append(Change(from: ns.substring(with: range), to: replacement.text))
                i += n
                fixed = true
                break
            }
            if !fixed { i += 1 }
        }
        guard !replacements.isEmpty else { return Result(text: text, changes: []) }
        var out = text as NSString
        for r in replacements.reversed() { out = out.replacingCharacters(in: r.range, with: r.text) as NSString }
        return Result(text: out as String, changes: changes)
    }

    // MARK: Pieces

    private struct Token {
        var range: NSRange
        var raw: String
        var leading: String { String(raw.prefix(while: { !$0.isLetter && !$0.isNumber })) }
        var trailing: String {
            let rest = raw.dropFirst(leading.count)
            return String(rest.reversed().prefix(while: { !$0.isLetter && !$0.isNumber }).reversed())
        }
        var core: String { String(raw.dropFirst(leading.count).dropLast(trailing.count)) }
        var hasInnerBreak: Bool { core.contains(where: { ".?!,;:()\"“”".contains($0) }) }
        var endsSentence: Bool { trailing.contains(where: { ".?!,;:".contains($0) }) }
    }

    private static func repair(_ window: [Token], among candidates: [(term: String, letters: String, key: String)],
                               protected: Set<String>) -> (text: String, term: String)? {
        let n = window.count
        guard window.allSatisfy({ !$0.core.isEmpty && !$0.hasInnerBreak && !$0.core.contains(where: \.isNumber) }) else { return nil }
        // A window may not run across the end of a sentence or clause.
        guard window.dropLast().allSatisfy({ !$0.endsSentence && $0.trailing.isEmpty }) else { return nil }
        let heardText = window.map(\.core).joined(separator: " ")
        let letters = VocabularyMatcher.letters(heardText)
        guard letters.count >= minimumLetters - 1 else { return nil }
        guard !protected.contains(letters), !window.contains(where: { protected.contains(VocabularyMatcher.letters($0.core)) }) else { return nil }
        let ordinary = n > 1 && window.contains { functionWords.contains($0.core.lowercased()) }
        let key = VocabularyMatcher.phoneticKey(heardText)

        var best: (term: String, distance: Int)?
        var tied = false
        for c in candidates {
            guard abs(c.letters.count - letters.count) <= 2, c.letters.first == letters.first else { continue }
            let d = VocabularyMatcher.editDistance(letters, c.letters)
            if d == 0, heardText.lowercased() == c.term.lowercased() { return nil }       // already right, apart from case
            if ordinary && d > 0 { continue }
            guard allowed(distance: d, words: n, termLetters: c.letters.count, sameSound: key == c.key && key.count >= 2) else { continue }
            if let b = best {
                if d < b.distance { best = (c.term, d); tied = false }
                else if d == b.distance, c.term != b.term { tied = true }
            } else {
                best = (c.term, d)
            }
        }
        guard let best, !tied else { return nil }
        let text = window[0].leading + best.term + window[n - 1].trailing
        return (text, best.term)
    }

    private static func allowed(distance d: Int, words: Int, termLetters: Int, sameSound: Bool) -> Bool {
        if d == 0 { return true }                        // spacing, apostrophe or hyphen only: "blink it", "parle g", "haldirams"
        if sameSound { return d <= (words > 1 ? 3 : 2) } // "peril g" sounds like "Parle-G"
        if words > 1 { return d <= 2 }                   // a split brand is the classic failure: "zip tow"
        return d <= (termLetters >= 8 ? 2 : 1)
    }
}
