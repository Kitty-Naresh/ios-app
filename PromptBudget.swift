import Foundation

// MARK: - The prompt budget

// The model reads the whole utterance and decides what it means. Swift only makes sure what it sends fits the window.

/// How much of the user's own words one model call may carry. The window is about 4,096 tokens, shared by the instructions,
/// the output schema, the prompt and the answer. The numbers are conservative until they are measured on a device
/// (`REAL_MODEL_RUNS.md`, "Measure the prompt ceiling"): the `TO MODEL` trace line prints each prompt's size and the
/// `FROM MODEL` line the seconds it took, so a few long runs show the real limit.
nonisolated enum PromptBudget {
    /// The estimate is the same one the trace shows: about 3.5 characters to a token for English.
    static let charactersPerToken = 3.5
    /// The most of the user's words one call carries, in estimated tokens.
    static let utteranceTokens = 520
    /// The size of a piece when a turn is over budget: whole sentences packed up to this many characters.
    static let chunkCharacters = 1_200

    /// A long request makes a long ANSWER (about ten fields per task), and a long answer is slow and can overflow the answer room even
    /// when the prompt fits. Past this many characters the turn is read in parts of at most `answerChunkCharacters`, one call each,
    /// in order, into one draft. About 600 characters is a handful of tasks.
    static let answerSplitThreshold = 700
    static let answerChunkCharacters = 600

    /// True when the words are long enough that one call's answer is likely to be too long or too slow.
    static func splitsForAnswer(_ text: String) -> Bool { text.count > answerSplitThreshold }

    static var utteranceCharacters: Int { Int(Double(utteranceTokens) * charactersPerToken) }

    static func fits(_ text: String) -> Bool { text.count <= utteranceCharacters }

    /// The turn as one piece when it fits, otherwise whole sentences in order. Nothing is cut and nothing is left out:
    /// the pieces joined are the text.
    static func pieces(of text: String) -> [String] { fits(text) ? [text] : chunks(of: text) }

    /// Whole sentences packed in order, each piece at most `limit` characters. A sentence longer than the limit is split at
    /// the last space (or comma) that fits. The pieces joined always equal `text`.
    static func chunks(of text: String, limit: Int = chunkCharacters) -> [String] {
        guard limit > 0, text.count > limit else { return text.isEmpty ? [] : [text] }
        var parts: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: [.bySentences, .substringNotRequired]) { _, _, enclosing, _ in
            parts.append(String(text[enclosing]))
        }
        if parts.joined() != text { parts = [text] }
        var pieces: [String] = []
        var current = ""
        for part in parts.flatMap({ hardSplit($0, limit: limit) }) {
            if !current.isEmpty, current.count + part.count > limit {
                pieces.append(current)
                current = ""
            }
            current += part
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces
    }

    /// One sentence over the limit, split after a comma or a space, as late as it fits.
    private static func hardSplit(_ s: String, limit: Int) -> [String] {
        var rest = Substring(s)
        var out: [String] = []
        while rest.count > limit {
            let window = rest.prefix(limit)
            let cut = window.lastIndex(where: { $0 == "," || $0 == ";" }).map { window.index(after: $0) }
                ?? window.lastIndex(where: { $0.isWhitespace }).map { window.index(after: $0) }
                ?? window.endIndex
            out.append(String(rest[..<cut]))
            rest = rest[cut...]
        }
        if !rest.isEmpty { out.append(String(rest)) }
        return out
    }
}
