import Foundation

/// The one place for the word lists that speech handling shares: the prechecker,
/// the turn gate and the SpeechCleaner all read from here, so they can't drift apart.
nonisolated enum SpeechLexicon {
    /// Hesitation sounds. Safe to drop anywhere.
    static let fillers: Set<String> = [
        "um", "umm", "uh", "uhh", "uhm", "er", "err", "erm", "hmm", "hm", "mm", "mmm", "ah", "ahh"
    ]

    /// Words that are only filler when set off by commas, a pause or the start of a sentence.
    /// "I would like to", "it looks like rain" must never lose them.
    static let softFillers: [[String]] = [["you", "know"], ["like"], ["basically"], ["literally"]]

    /// A sentence can't end on these: the speaker has more to say.
    static let dangling: Set<String> = Set([
        "and", "but", "or", "then", "for", "about", "to", "actually", "wait",
        "the", "a", "an", "my", "our", "your", "this", "that", "these", "those", "some", "of", "in", "on", "at", "with",
        "from", "into", "by", "every", "each", "if", "because", "so", "also", "plus", "like", "is", "should", "needs", "need",
        "will", "has", "have", "let's", "lets", "after", "before", "until", "till"
    ]).union(fillers)

    /// Words that open a noun phrase or a preposition: what follows them is an object, not an action.
    static let determiners: Set<String> = [
        "the", "a", "an", "my", "our", "your", "this", "that", "these", "those", "some", "every", "each", "all", "any",
        "of", "in", "on", "at", "to", "for", "with", "from"
    ]

    /// Words after which a new noun phrase begins ("clean the master bathroom": the phrase starts after "the").
    static let phraseAnchors: Set<String> = determiners.union(Set([
        "his", "her", "their", "its", "up", "down", "off", "out", "into", "by", "about"
    ]))

    static let questionStarters: Set<String> = [
        "what", "what's", "which", "show", "list", "tell", "who", "when", "how", "do", "did", "does", "is", "are", "any", "anything"
    ]

    static let acknowledgements: Set<String> = [
        "yes", "yeah", "yep", "yup", "sure", "ok", "okay", "no", "nope", "done", "save it", "save", "go ahead", "confirm",
        "that's all", "thats all", "that is all", "that's it", "thats it", "cancel", "discard", "never mind", "nevermind"
    ]

    /// Phrases that wrap a request without being part of it ("add a task to", "remind me to"...).
    static let frames: [[String]] = [
        ["add", "a", "task", "to"], ["add", "a", "task", "for"], ["add", "a", "task"], ["add", "task", "to"], ["add", "task"],
        ["create", "a", "task", "to"], ["create", "a", "task", "for"], ["create", "a", "task"],
        ["create", "a", "routine", "to"], ["create", "a", "routine"],
        ["create", "a", "playbook", "to"], ["create", "a", "playbook", "for"], ["create", "a", "playbook"],
        ["make", "a", "task", "to"], ["make", "a", "task"], ["remind", "me", "to"],
        ["i", "need", "to"], ["i", "want", "to"], ["i", "have", "to"], ["i", "should"], ["i'd", "like", "to"],
        ["can", "you"], ["could", "you"], ["would", "you"], ["please"], ["let's"], ["lets"]
    ]

    static let weekdays: Set<String> = [
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
        "mon", "tue", "tues", "wed", "thu", "thur", "thurs", "fri", "sat", "sun"
    ]

    /// Words that make up a day or time phrase ("next Friday", "tomorrow morning", "at 5 pm").
    static let dayTimeWords: Set<String> = weekdays.union(Set([
        "today", "tomorrow", "tonight", "yesterday", "morning", "afternoon", "evening", "night", "noon", "midnight",
        "next", "this", "coming", "on", "at", "by", "am", "pm", "o'clock", "oclock", "week", "weekend", "month"
    ]))

    static let months: Set<String> = [
        "january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december"
    ]

    /// Lowercased words with the punctuation stripped from the ends. Apostrophes stay.
    static func bare(_ word: String) -> String {
        word.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .trimmingCharacters(in: CharacterSet.letters.union(.decimalDigits).union(CharacterSet(charactersIn: "'")).inverted)
    }
}
