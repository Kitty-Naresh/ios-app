import Foundation

// MARK: - How much Kitty trusts the transcript

/// Whisper and Apple Speech return punctuated, capitalised sentences, so a long turn arrives with its sentence boundaries. With `raw` on,
/// Kitty stops second-guessing it: the cleaner (fillers, repeats, "no wait" repairs) passes the words through, and a long
/// turn skips `BulkDetector` and the long-turn digest. The whole punctuated transcript goes to the model in one prompt and the
/// model splits it into tasks. Validators, dates, assignees and the "Did you say…?" read-back all still run.
///
/// The cost: the rule-based self-correction ("clean the… no wait, wash the car") no longer happens. Turn it off in the menu to
/// get the previous behaviour back.
nonisolated enum TranscriptPolicy {
    static let key = "kitty.rawTranscript"

    /// Set by tests to force one behaviour.
    nonisolated(unsafe) static var override: Bool?

    /// Unit tests and evals keep the established rule-based reading unless a test turns raw on.
    private static let underTest = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    static var raw: Bool {
        get {
            if let override { return override }
            if underTest { return false }
            return (UserDefaults.standard.object(forKey: key) as? Bool) ?? true
        }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    /// The sentences of a punctuated transcript, in order. Empty if there is only one (or none).
    static func sentences(of text: String) -> [String] {
        var out: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: [.bySentences, .substringNotRequired]) { _, range, _, _ in
            let s = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if s.split(whereSeparator: { $0.isWhitespace }).count >= 2 { out.append(s) }
        }
        return out.count >= 2 ? out : []
    }

    /// What the model is told about a raw, punctuated turn.
    static let promptNote = "This is a punctuated transcript of one spoken turn. Make one task or routine for every separate thing the user asks to be done. "
        + "Leave out chatter, complaints and background. Use only what the user said. A day or person belongs to the sentence it was said in, "
        + "unless the user clearly says it applies to all of them."
}
