import Foundation
#if canImport(UIKit)
import UIKit
#endif

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

    static func leadingEcho(heard: String, spoken: String, strict: Bool) -> Int {
        EchoGuard.leadingEcho(heard: heard, spoken: spoken, strict: strict)
    }

    /// The words the user said, leaving out words that continue Kitty's own sentence (see `EchoGuard`).
    static func userWords(heard: String, spoken: String, strict: Bool = false) -> [String] {
        EchoGuard.userWords(heard: heard, spoken: spoken, strict: strict, keep: stopWords)
    }

    /// Speech that shares no word with what Kitty is saying needs two words; speech that overlaps her words (which is what
    /// her own voice, misheard, looks like) needs three. A stop word never needs either.
    static func minWordsToInterrupt(_ words: [String], spoken: String) -> Int {
        let said = TurnAccumulator.words(spoken)
        let overlaps = words.contains { w in said.contains { EchoGuard.matches(w, $0) } }
        return overlaps ? 3 : 2
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
        if anySpeechInterrupts, words.count >= minWordsToInterrupt(words, spoken: spoken) { return .interrupt(rest: user.joined(separator: " ")) }
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

/// Tells Kitty's own voice, as the microphone hears it, from the user's.
///
/// What comes back from the recogniser is her sentences, garbled: "tasks" becomes "task's", a word is dropped, a number is
/// written as digits. So a heard word counts as hers when it matches a spoken word loosely, and only when it sits in a run
/// of at least two such words in her order. One word on its own is left alone, because the user may well say "bathroom"
/// right after she did.
nonisolated enum EchoGuard {
    /// Same word for this purpose: equal, one letter apart, or one a plural of the other.
    private static let numbers: [String: String] = [
        "zero": "0", "one": "1", "two": "2", "three": "3", "four": "4", "five": "5", "six": "6", "seven": "7", "eight": "8",
        "nine": "9", "ten": "10", "eleven": "11", "twelve": "12",
    ]

    static func matches(_ x: String, _ y: String) -> Bool {
        let a = numbers[x] ?? x, b = numbers[y] ?? y
        if a == b { return !a.isEmpty }
        guard a.count >= 4, b.count >= 4 else { return false }
        return withinOneEdit(a, b)
    }

    static func withinOneEdit(_ a: String, _ b: String) -> Bool {
        let x = Array(a), y = Array(b)
        if abs(x.count - y.count) > 1 { return false }
        if x == y { return true }
        var i = 0
        while i < x.count, i < y.count, x[i] == y[i] { i += 1 }
        if x.count == y.count { return Array(x[(i + 1)...]) == Array(y[(i + 1)...]) }          // one letter changed
        let (long, short) = x.count > y.count ? (x, y) : (y, x)
        return Array(long[(i + 1)...]) == Array(short[i...])                                       // one letter added
    }

    /// The heard words (in their original form) that are not Kitty's. `keep` words (stop words) are never dropped.
    /// `strict` also drops a single heard word that matches hers: used in the moments right after she stops, when anything
    /// that sounds like her is her.
    static func userWords(heard: String, spoken: String, strict: Bool = false, keep: Set<String> = []) -> [String] {
        let heardWords = heard.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let flags = echoFlags(heard: heardWords, spoken: spoken, strict: strict, keep: keep)
        return heardWords.indices.filter { !flags[$0] }.map { heardWords[$0] }
    }

    /// How many words at the start of `heard` are Kitty's. Her tail comes first in a fresh recognition, the user's words after.
    static func leadingEcho(heard: String, spoken: String, strict: Bool) -> Int {
        let words = heard.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let flags = echoFlags(heard: words, spoken: spoken, strict: strict, keep: [])
        return flags.prefix(while: { $0 }).count
    }

    /// One flag per heard word: true when it is Kitty's. Punctuation-only tokens count as hers (they are nothing).
    static func echoFlags(heard heardWords: [String], spoken: String, strict: Bool, keep: Set<String>) -> [Bool] {
        let said = TurnAccumulator.words(spoken)
        guard !said.isEmpty else { return heardWords.map { _ in false } }
        let normed = heardWords.map(BargeIn.norm)
        var echo = Array(repeating: false, count: heardWords.count)

        // Empty tokens (punctuation only) and words that match one of hers.
        let hit = normed.map { w in !w.isEmpty && said.contains { matches(w, $0) } }
        func position(_ w: String) -> [Int] { said.indices.filter { matches(w, said[$0]) } }

        // A pair of neighbouring heard words that sit within two words of each other in her sentence (one word may be dropped).
        for i in 0..<max(heardWords.count - 1, 0) where hit[i] && hit[i + 1] {
            let a = position(normed[i]), b = position(normed[i + 1])
            if a.contains(where: { j in b.contains { k in k > j && k - j <= 2 } }) {
                echo[i] = true; echo[i + 1] = true
            }
        }
        // The same with one extra small word between them ("pay the rent" for "pay rent").
        for i in 0..<max(heardWords.count - 2, 0) where hit[i] && hit[i + 2] && normed[i + 1].count <= 3 {
            let a = position(normed[i]), b = position(normed[i + 2])
            if a.contains(where: { j in b.contains { k in k > j && k - j <= 2 } }) {
                echo[i] = true; echo[i + 1] = true; echo[i + 2] = true
            }
        }
        // A heard run that is nearly all hers is hers: "you have three task buy milk call".
        let matched = hit.filter { $0 }.count
        if heardWords.count >= 4, Double(matched) / Double(heardWords.count) >= 0.8 {
            for i in heardWords.indices where hit[i] { echo[i] = true }
        }
        if strict { for i in heardWords.indices where hit[i] { echo[i] = true } }

        return heardWords.indices.map { i in
            if normed[i].isEmpty { return true }
            if keep.contains(normed[i]) { return false }
            return echo[i]
        }
    }
}

/// What Kitty has said lately, so the tail of her voice that the microphone picks up just after she stops is not taken as
/// the user's.
nonisolated struct SpokenBuffer {
    /// Seconds after she stops during which the start of what is heard is checked against what she said.
    static let tail: TimeInterval = 2
    /// Seconds right after she stops during which any word that sounds like hers is dropped.
    static let quiet: TimeInterval = 0.6

    private var entries: [(text: String, end: Date?)] = []
    mutating func began(_ text: String) {
        entries.append((text, nil))
        if entries.count > 4 { entries.removeFirst() }
    }
    mutating func ended(at: Date) {
        for i in entries.indices where entries[i].end == nil { entries[i].end = at }
    }
    mutating func clear() { entries = [] }

    func recentText(now: Date) -> String {
        entries.filter { $0.end == nil || now.timeIntervalSince($0.end!) < Self.tail }.map(\.text).joined(separator: " ")
    }
    func inQuietWindow(now: Date) -> Bool {
        entries.contains { $0.end != nil && now.timeIntervalSince($0.end!) < Self.quiet }
    }
}

/// Keeps every sentence of a long turn.
///
/// The recogniser sends cumulative partials: each one should contain everything said so far in the session. After a pause it
/// sometimes starts over instead, and the new partial holds only the new sentence. Replacing the old text with it would
/// lose the first sentence, so a partial that is clearly a fresh transcription is added to what was said before.
nonisolated enum TurnAccumulator {
    static func words(_ s: String) -> [String] {
        s.split(whereSeparator: { $0.isWhitespace }).map { BargeIn.norm(String($0)) }.filter { !$0.isEmpty }
    }

    /// Two words that are the same word as far as a recogniser's revisions go ("task" / "tasks", "im" / "i'm").
    static func sameWord(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        if a.isEmpty || b.isEmpty { return false }
        if (a.hasPrefix(b) || b.hasPrefix(a)) && min(a.count, b.count) >= 2 { return true }
        return EchoGuard.withinOneEdit(a, b)
    }

    /// True when `new` is not a longer or revised version of `previous`: it begins differently and shares no pair of
    /// neighbouring words with it. A revision ("i'm working" -> "i am working") keeps most of the earlier words.
    static func isReset(previous: String, new: String) -> Bool {
        let p = words(previous), n = words(new)
        guard p.count >= 2, !n.isEmpty else { return false }
        // The start agrees: it is the same sentence, longer or revised.
        let k = min(6, p.count, n.count)
        let agree = (0..<k).filter { sameWord(p[$0], n[$0]) }.count
        if Double(agree) / Double(k) >= 0.6 { return false }
        // A revision that shifted the words ("i'm" -> "i am") still shares real pairs of words with what came before.
        var pairs = Set<String>()
        for i in 0..<(p.count - 1) where !(trivial.contains(p[i]) && trivial.contains(p[i + 1])) { pairs.insert(p[i] + " " + p[i + 1]) }
        for i in 0..<max(n.count - 1, 0) where pairs.contains(n[i] + " " + n[i + 1]) { return false }
        return true
    }

    /// Words that begin many sentences: sharing "and the" says nothing about whether it is the same sentence.
    private static let trivial: Set<String> = ["and", "the", "a", "an", "to", "of", "is", "i", "it", "for", "my", "in", "on", "so", "then", "also",
                                               "that", "this", "we", "you", "are", "be", "do", "ok", "okay"]

    /// The turn after a new partial: `carry` holds earlier sessions, `session` the current one. `replacedBySettle`: the accurate model's
    /// text replaced live words, which can differ from them in every word and is still the same speech, never a restart.
    static func absorb(carry: String, session: String, partial: String, replacedBySettle: Bool = false) -> (carry: String, session: String, reset: Bool) {
        guard !session.isEmpty, !replacedBySettle, isReset(previous: session, new: partial) else { return (carry, partial, false) }
        let joined = [carry, session].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: " ")
        return (joined, partial, true)
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

// MARK: - The mic button and the line under the thread

/// What a tap on the mic button does. The mic is a listening switch: once you have finished talking it never does anything
/// else, in any state, and it never cancels work that is under way.
nonisolated enum MicTap: Equatable {
    case stopSpeaking       // Kitty is talking: stop her and listen
    case processNow         // new words and the mic on: "I'm done"
    case stopListening      // the mic on, nothing new to say (thinking, a preview, a question, words already judged)
    case startListening     // the mic off

    static func decide(micOn: Bool, isSpeaking: Bool, stage: VoiceConversation.Stage, hasNewWords: Bool) -> MicTap {
        if isSpeaking { return .stopSpeaking }
        guard micOn else { return .startListening }
        if stage == .listening, hasNewWords { return .processNow }
        return .stopListening
    }
}

/// The one line under the thread. It always says whether the mic is listening and whether a task is still being made.
nonisolated enum ConversationStatus {
    /// `needsTask`: words were heard but none of them is a task yet ("create a task"). A status label, not a question.
    static func text(stage: VoiceConversation.Stage, micOn: Bool, isSpeaking: Bool, hasWords: Bool, needsTask: Bool = false) -> String {
        let speaking = "Kitty is speaking. Tap to stop and talk"
        switch stage {
        case .listening:
            if isSpeaking { return speaking }
            if !micOn { return "Mic is off · tap to talk" }
            if needsTask { return "Listening for the task…" }
            return hasWords ? "Listening… tap the mic when you're done" : "Listening…"
        case .thinking:
            return micOn ? "Working on it · tap the mic to stop listening" : "Working on it · mic is off"
        case .preview:
            return "Your tasks are ready · tap them to review and save"
        case .question:
            return micOn ? "Go ahead, I'm listening" : "Mic is off · type your answer or tap the mic"
        case .idle:
            if isSpeaking { return speaking }
            return micOn ? "" : "Mic is off · tap to talk"
        }
    }
}


/// When the phone may not auto-lock. Talking is not touching, so iOS would lock the screen in the middle of a sentence.
/// The idle timer is switched off only while it is needed (the Talk screen is open, the app is in front, and the mic is on,
/// Kitty is speaking or a model call is running) and is always switched back on, because it costs battery.
nonisolated enum ScreenAwake {
    static func wanted(screenOpen: Bool, appInForeground: Bool, micOn: Bool, isSpeaking: Bool, working: Bool) -> Bool {
        guard screenOpen, appInForeground else { return false }
        return micOn || isSpeaking || working
    }

    @MainActor static func apply(_ on: Bool) {
        #if canImport(UIKit)
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return }     // unit tests never touch the real screen
        UIApplication.shared.isIdleTimerDisabled = on
        #endif
    }
}
