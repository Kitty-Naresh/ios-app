import Foundation

/// Hands-free control while Kitty is speaking.
///
/// The microphone stays open during playback. What it hears is mostly the user, because the audio session cancels echo,
/// but some of Kitty's own voice can leak through. `decide` removes words that look like Kitty's own sentences, then asks:
/// did the user say "stop", or say something real? Either one cuts her off. Whatever follows "stop" is the next prompt.
nonisolated enum BargeIn {
    enum Decision: Equatable {
        case ignore
        /// Stop speaking now. `rest` is what the user said besides the stop word ("stop, only tomorrow" -> "only tomorrow").
        case interrupt(rest: String)
    }

    /// Master switch for hands-free interruption.
    static var enabled = true

    /// true: any real speech (two or more words that are not Kitty's own) interrupts her.
    /// false: only a stop word does. Use this if she still hears herself on a device.
    static var anySpeechInterrupts = true

    private static let stopWords: Set<String> = ["stop", "enough", "pause", "quiet", "shush", "silence", "cancel"]
    /// Words that can open a stop phrase and are not part of the request that follows.
    private static let leadingControl: Set<String> = ["okay", "ok", "kitty", "hey", "please", "stop", "enough", "pause", "quiet", "shush",
                                                      "silence", "wait", "thats", "cancel"]

    static func norm(_ word: String) -> String {
        word.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// The words the user said, leaving out words that continue Kitty's own sentence.
    static func userWords(heard: String, spoken: String) -> [String] {
        let heardWords = heard.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let said = spoken.split(whereSeparator: { $0.isWhitespace }).map { norm(String($0)) }.filter { !$0.isEmpty }
        guard !said.isEmpty else { return heardWords }
        let single = Set(said)
        var pairs = Set<String>()
        for i in 0..<max(said.count - 1, 0) { pairs.insert(said[i] + " " + said[i + 1]) }

        let normed = heardWords.map(norm)
        func echo(_ i: Int) -> Bool {
            let w = normed[i]
            if w.isEmpty { return true }
            if stopWords.contains(w) { return false }
            guard single.contains(w) else { return false }
            if i > 0, pairs.contains(normed[i - 1] + " " + w) { return true }
            if i + 1 < normed.count, pairs.contains(w + " " + normed[i + 1]) { return true }
            return false
        }
        return heardWords.indices.filter { !echo($0) }.map { heardWords[$0] }
    }

    static func decide(heard: String, spoken: String) -> Decision {
        let user = userWords(heard: heard, spoken: spoken)
        guard !user.isEmpty else { return .ignore }
        let words = user.map(norm).filter { !$0.isEmpty }

        // "wait" alone, or "hold on", interrupts; "wait for the plumber" is a request.
        let stops = words.contains { stopWords.contains($0) }
            || zip(words, words.dropFirst()).contains { $0 == "hold" && $1 == "on" }
            || (words.contains("wait") && words.count <= 2)
            || (words.first == "thats" && words.contains("enough"))
            || zip(words, words.dropFirst()).contains { $0 == "never" && $1 == "mind" }
        if stops { return .interrupt(rest: rest(after: user)) }
        if anySpeechInterrupts, words.count >= 2 { return .interrupt(rest: user.joined(separator: " ")) }
        return .ignore
    }

    /// Drops the opening stop phrase ("okay stop", "hold on", "that's enough"), keeps the request after it.
    static func rest(after user: [String]) -> String {
        var i = 0
        while i < user.count {
            let w = norm(user[i])
            let next = i + 1 < user.count ? norm(user[i + 1]) : ""
            if w == "hold", next == "on" { i += 2 }
            else if w == "never", next == "mind" { i += 2 }
            else if leadingControl.contains(w) || w.isEmpty { i += 1 }
            else { break }
        }
        return user[i...].joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: " ,.!?"))
    }
}

/// When the microphone is retried and when it is left alone.
nonisolated enum MicPolicy {
    /// Quiet retries after a start-up failure that is not a permission problem.
    static let retryDelays: [Double] = [0.3, 0.8, 1.5]

    /// Seconds to wait before the next try, or nil to stop and tell the user (permission problems, or the retries ran out).
    static func retryDelay(afterFailure attempt: Int, permanent: Bool) -> Double? {
        guard !permanent, attempt >= 0, attempt < retryDelays.count else { return nil }
        return retryDelays[attempt]
    }

    /// The recogniser ended by itself several times in a few seconds: wait a little before listening again.
    static func restartDelay(restartsInWindow: Int) -> Double {
        restartsInWindow <= 4 ? 0 : min(Double(restartsInWindow - 4) * 1.0, 5.0)
    }

    /// The watchdog: only an explicit mute, a permission problem, typing instead of talking, Kitty speaking, or a
    /// start already under way keeps the mic off.
    static func shouldRestart(active: Bool, micWanted: Bool, userMuted: Bool, blocked: Bool, micOn: Bool,
                              isSpeaking: Bool, starting: Bool, thinking: Bool) -> Bool {
        active && micWanted && !userMuted && !blocked && !micOn && !isSpeaking && !starting && !thinking
    }
}
