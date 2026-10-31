import Foundation

// MARK: - Evidence for every attribute
//
// A task keeps an attribute only when the user's own words for THAT task say it. The model reads a garbled sentence into a person
// ("School"), a repeat ("tomorrow"), a purpose ("tuition") that is not in the words, or fills a day or a category because the task
// "looks like" one. `EvidenceGate` is the one place that checks each value, after the mapper and `WhenReader` have filled the draft:
//
//   - the words of the task: the whole answer when it holds one task; otherwise the clause that holds most of the task's title words
//     (clauses end at . , ; ? ! and at "and", "then", "also"). With several tasks and no clear clause, only the phrases the task's own
//     fields carried count, so a phrase that could belong to a neighbour is never attached to this task;
//   - the value must be backed by a phrase there, found with the same tables the readers use (nothing is read here that the readers
//     cannot already read);
//   - a value with no phrase is cleared, a line says why (`SWIFT <attribute> "<value>" dropped: no evidence in the words`), and the
//     phrase that did justify a kept value is recorded in `DraftItem.evidence`, to be shown beside the value.
//
// What it does not do: it does not check that the phrase is the RIGHT one, only that it is there; and a word the recogniser heard
// wrongly is evidence like any other. A value set by a header ("house help tasks for tomorrow") has the header as its evidence and
// is dropped only when the task's own clause names someone else.

enum EvidenceGate {
    /// Words that are not a person even when the model puts them in the assignee field.
    static let notPeople: Set<String> = [
        "user", "parent", "parents", "someone", "somebody", "anyone", "anybody", "person", "people", "team", "staff", "colleague", "friend",
        "guest", "guests", "kid", "kids", "child", "children", "self", "none", "unknown", "other",
        "school", "office", "home", "hospital", "college", "class", "market", "shop", "store", "bank", "airport", "station", "gym", "hostel",
        "kal", "aaj", "parso", "today", "tomorrow", "tonight", "morning", "evening", "night", "afternoon", "weekend"]
    private static let festivals: Set<String> = [
        "diwali", "holi", "rakhi", "eid", "dussehra", "navratri", "christmas", "pongal", "onam", "baisakhi", "ugadi", "janmashtami", "lohri"]
    /// Words before a person's name that make them the one who does it: "ask Rani to", "tell Rani", "let Rani".
    private static let cueBefore: Set<String> = ["ask", "tell", "let", "get", "make", "have", "request", "remind", "inform", "assign", "assigned"]
    /// Words after a person's name that make them the one who does it: "Rani to clean", "Rani should", "Rani ko".
    private static let cueAfter: Set<String> = ["to", "should", "will", "can", "must", "needs", "need", "ko", "ne", "would", "could"]
    private static let firstPerson: Set<String> = ["i", "me", "my", "myself", "mine", "i'll", "i've", "i'm", "im", "mera", "meri", "mujhe", "main"]
    private static let familyWords: Set<String> = ["family", "everyone", "everybody", "we", "us", "ourselves", "hum", "sab"]
    private static let householdAliases: [String] = ["househelp", "house help", "maid", "helper", "housemaid", "housekeeper", "domestic help", "help"]
    private static let splitters: Set<String> = ["and", "then", "also", "aur", "phir"]

    // MARK: Words

    struct Word { var raw: String; var key: String }

    static func words(_ text: String) -> [Word] {
        text.split(whereSeparator: { $0.isWhitespace }).compactMap { piece in
            let raw = String(piece).trimmingCharacters(in: CharacterSet(charactersIn: ",.;:!?\"()[]"))
            guard !raw.isEmpty else { return nil }
            return Word(raw: raw, key: raw.lowercased().replacingOccurrences(of: "’", with: "'"))
        }
    }

    /// The answer cut into clauses: at . , ; ? ! and at the words "and", "then", "also" (the word itself is not kept).
    static func clauses(_ text: String) -> [String] {
        var out: [String] = []
        var current: [String] = []
        func flush() { if !current.isEmpty { out.append(current.joined(separator: " ")); current = [] } }
        for piece in text.split(whereSeparator: { $0.isWhitespace }) {
            let token = String(piece)
            let bare = token.trimmingCharacters(in: .punctuationCharacters).lowercased()
            if splitters.contains(bare) { flush(); continue }
            current.append(token.trimmingCharacters(in: CharacterSet(charactersIn: ",.;?!")))
            if let last = token.last, ",.;?!".contains(last) { flush() }
        }
        flush()
        return out
    }

    /// The clause that holds the most words of the title, or nil when none does or two do equally.
    static func clause(for title: String, in transcript: String) -> String? {
        let mine = Provenance.words(title)
        guard !mine.isEmpty else { return nil }
        var best: (text: String, score: Int)?
        var tied = false
        for c in clauses(transcript) {
            let heard = Provenance.words(c)
            let score = mine.filter { Provenance.matches($0, among: heard) }.count
            guard score > 0 else { continue }
            if let b = best {
                if score > b.score { best = (c, score); tied = false } else if score == b.score { tied = true }
            } else { best = (c, score) }
        }
        guard let best, !tied else { return nil }
        return best.text
    }

    // MARK: The gate

    static func apply(_ item: inout DraftItem, from t: ExtractionTaskValue, transcript: String?, wordsAreThisTasks: Bool,
                      knownPeople: [String], now: Date, calendar: Calendar) {
        guard let whole = transcript, !whole.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let own = wordsAreThisTasks ? whole : clause(for: item.title, in: whole)    // nil: no clear clause for this task
        let scoped = !wordsAreThisTasks && own == nil

        func drop(_ attribute: String, _ value: String, note: String? = nil) {
            Trace.step("SWIFT", "\(attribute) \"\(value)\" dropped: no evidence in the words")
            if let note, !item.advisories.contains(note) { item.advisories.append(note) }
        }

        // The person.
        if let raw = item.assignee {
            if t.fromScope.contains("assignee") {
                // The header's person. Dropped only when this task's own clause names someone else ("for me" under "house help tasks").
                if let own, own != whole, let other = namedBy(own, knownPeople: knownPeople), other.lowercased() != raw.lowercased() {
                    drop("assignee", raw)
                    item.assignee = nil
                } else {
                    item.evidence["assignee"] = "said once for these tasks"
                }
            } else if let phrase = assigneeEvidence(raw, in: own, knownPeople: knownPeople) {
                item.evidence["assignee"] = phrase
            } else {
                item.assignee = nil
                let low = raw.lowercased()
                let plausible = !notPeople.contains(low) && !festivals.contains(low) && !Assignee.isRole(raw)
                    && raw.split(separator: " ").count <= 2 && raw.allSatisfy { $0.isLetter || $0 == " " }
                drop("assignee", raw, note: plausible ? "I heard “\(raw)” as a person but it isn't someone I know, so I left it empty." : nil)
            }
        }

        // The speaker's own task: "I want to", "I need to", "remind me to". Saying it of themselves is the evidence ("I" is a person), so
        // the task is Me. Nothing is guessed: with no first-person cue in this task's clause, or when the clause names someone else as the
        // one who does it ("I want Rani to…", "I'll ask the maid to…"), the assignee stays empty.
        if item.assignee == nil, let clause = own, let phrase = speakerCue(in: clause, knownPeople: knownPeople) {
            item.assignee = Assignee.me
            item.evidence["assignee"] = phrase
        }

        // The category: only when its name is in the words.
        if let name = item.categoryName {
            let low = name.lowercased()
            let said = own.map { text in
                ScopeReader.spoken(name, in: text) || (TaskCategory.mentioned(in: text) != nil && TaskCategory.mentioned(in: text) == TaskCategory.mentioned(in: low))
            } ?? false
            if said { item.evidence["category"] = name } else { item.categoryName = nil; drop("category", name) }
        }

        // The day, the time, the part of the day and the timeframe.
        let reading = own.map { WhenReader.read($0, now: now, calendar: calendar) }
        func spokenAnywhere(_ phrase: String) -> Bool { ScopeReader.spoken(phrase, in: whole) }
        /// With no clear clause the task's own field counts: what the model wrote in the field, if it is in the words.
        func ownField(_ raw: String?) -> String? {
            guard scoped, let raw = TaskDraftMapper.clean(raw), spokenAnywhere(raw) else { return nil }
            return raw
        }

        if item.due != nil {
            if t.fromScope.contains("day") { item.evidence["day"] = "said once for these tasks" }
            else if let said = item.evidence["day"] {
                if !spokenAnywhere(said) { item.due = nil; item.evidence["day"] = nil; drop("day", said) }
            } else if let d = item.due, let own, let phrase = dayPhrase(d, in: own, reading: reading, now: now, calendar: calendar) {
                item.evidence["day"] = phrase
            } else if let phrase = ownField(t.dueDate) ?? ownField(t.schedule), item.softDue == nil {
                item.evidence["day"] = phrase
            } else {
                let shown = item.due.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? ""
                item.due = nil
                drop("day", shown)
            }
        }
        if let soft = item.softDue {
            if t.fromScope.contains("day") { item.evidence["softDue"] = "said once for these tasks" }
            else if let said = item.evidence["softDue"] {
                if !spokenAnywhere(said) { item.softDue = nil; item.evidence["softDue"] = nil; drop("timeframe", said) }
            } else if let own, ScopeReader.spoken(soft, in: own) || Words.key(reading?.soft ?? "") == Words.key(soft) {
                item.evidence["softDue"] = reading?.phrases["softDue"] ?? soft
            } else {
                item.softDue = nil
                drop("timeframe", soft)
            }
        }
        if let minutes = item.timeMinutes {
            if t.fromScope.contains("time") { item.evidence["time"] = "said once for these tasks" }
            else if let said = item.evidence["time"] {
                if !spokenAnywhere(said) { item.timeMinutes = nil; item.evidence["time"] = nil; drop("time", said) }
            } else if let own, let phrase = timePhrase(minutes, in: own, reading: reading) {
                item.evidence["time"] = phrase
            } else if let phrase = ownField(t.dueTime) ?? ownField(t.schedule) {
                item.evidence["time"] = phrase
            } else {
                item.timeMinutes = nil
                // A clock with no am/pm and no part of the day is not guessed; its words are kept and the card asks for it.
                if let heard = reading?.periodMissing, item.unparsed["time"] == nil { item.unparsed["time"] = heard }
                drop("time", DaySlot.clockLabel(minutes))
            }
        }
        if let slot = item.slot, item.timeMinutes == nil {
            if t.fromScope.contains("time") { item.evidence["slot"] = "said once for these tasks" }
            else if let said = item.evidence["slot"] {
                if !spokenAnywhere(said) { item.slot = nil; item.evidence["slot"] = nil; drop("part of the day", said) }
            } else if let own, let phrase = slotPhrase(slot, in: own, reading: reading) {
                item.evidence["slot"] = phrase
            } else if let phrase = ownField(t.dueTime) ?? ownField(t.dueDate) ?? ownField(t.schedule) {
                item.evidence["slot"] = phrase
            } else if item.kind == .routine, item.recurrence != nil {
                // A routine's part of the day comes with its repeat ("every morning"); the repeat is checked next.
            } else {
                item.slot = nil
                drop("part of the day", slot.rawValue)
            }
        }

        // The repeat: a routine only when the words say how often.
        if item.kind == .routine, let spec = item.recurrence {
            if let own, let phrase = repeatPhrase(spec, schedule: item.schedule, in: own) {
                item.evidence["repeat"] = phrase
            } else if let phrase = ownField(t.schedule) {
                item.evidence["repeat"] = phrase
            } else {
                Trace.step("SWIFT", "repeat \"\(item.schedule ?? spec.scheduleText)\" dropped: no evidence in the words")
                item.kind = .task
                item.recurrence = nil
                item.schedule = nil
                if item.slot != nil, item.evidence["slot"] == nil { item.slot = nil }
                if item.timeMinutes != nil, item.evidence["time"] == nil { item.timeMinutes = nil }
            }
        }

        // What the words said already, and passed their own check: the purpose, the instructions, the list.
        if let r = item.reason { item.evidence["reason"] = r }
        if let n = item.instructions { item.evidence["instructions"] = n }
        if let l = item.listName, !t.fromScope.contains("list") { item.evidence["list"] = l }
    }

    // MARK: Hand edits and captions

    static let byYou = "added by you"

    /// What the user changed in a form is theirs: each changed value is marked "added by you", and a value they cleared has no evidence.
    static func markHandEdits(_ out: inout DraftItem, from original: DraftItem) {
        func mark<V: Equatable>(_ key: String, _ now: V?, _ was: V?) {
            guard now != was else { return }
            if now == nil { out.evidence[key] = nil } else { out.evidence[key] = byYou }
        }
        mark("assignee", out.assignee, original.assignee)
        mark("category", out.categoryName, original.categoryName)
        mark("reason", out.reason, original.reason)
        mark("instructions", out.instructions, original.instructions)
        mark("list", out.listName, original.listName)
        mark("softDue", out.softDue, original.softDue)
        mark("slot", out.slot, original.slot)
        mark("day", out.due, original.due)
        mark("time", out.timeMinutes, original.timeMinutes)
        mark("repeat", out.schedule, original.schedule)
        if out.due == nil { out.evidence["day"] = nil }
        if out.timeMinutes == nil { out.evidence["time"] = nil }
    }

    /// One line for a card: each value and the words that backed it ("Rani: “ask Rani to” · Fri 30 Oct: “tomorrow”"). Nil when nothing
    /// was recorded (a task saved before evidence was kept shows nothing). A phrase that only repeats the value is left out.
    static func caption(evidence: [String: String], assignee: String?, due: Date?, timeMinutes: Int?, slot: DaySlot?, softDue: String?,
                        category: String?, repeatText: String?) -> String? {
        var parts: [String] = []
        func add(_ key: String, _ value: String?) {
            guard let value, !value.isEmpty, let said = evidence[key], !said.isEmpty else { return }
            if said == byYou || said == "said once for these tasks" { parts.append("\(value): \(said)"); return }
            if Words.key(said) == Words.key(value) { return }
            parts.append("\(value): “\(said)”")
        }
        add("assignee", assignee)
        add("day", due.map { $0.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) })
        add("time", timeMinutes.map { DaySlot.clockLabel($0) })
        add("slot", timeMinutes == nil ? slot?.label : nil)
        add("softDue", due == nil ? softDue : nil)
        add("category", category)
        add("repeat", repeatText)
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: The speaker

    private static let speakerSubjects: Set<String> = ["i", "i'll", "ill", "i'm", "im"]
    /// Small words between "I" and the cue that change nothing: "I also need to", "I really want to".
    private static let speakerAdverbs: Set<String> = ["also", "really", "just", "still", "now", "actually", "only", "definitely"]
    private static let speakerWantVerbs: Set<String> = ["want", "need", "have", "has", "had", "plan", "planning", "got"]
    private static let speakerModals: Set<String> = ["should", "must", "will", "shall", "ought", "gotta", "wanna"]

    /// The words in which the speaker says they will do the task themselves, or nil. Needs a clear cue: "I want to", "I need to",
    /// "I have to", "I should", "I will", "I'll", "I'm going to", "I would like to", "remind me", "let me", "mujhe". "I want Rani to" is not
    /// one (the next word must be "to"), and a clause that names someone else as the doer gives none.
    static func speakerCue(in clause: String, knownPeople: [String]) -> String? {
        let ws = words(clause)
        let keys = ws.map(\.key)
        guard !keys.isEmpty else { return nil }
        // Someone else does it: a role in the clause, or a known person with a doer cue.
        if let role = Assignee.detect(in: clause), !role.isEmpty { return nil }
        for name in knownPeople where Assignee.normalize(name).lowercased() != Assignee.me.lowercased()
            && assigneeEvidence(name, in: clause, knownPeople: knownPeople) != nil { return nil }

        func at(_ i: Int) -> String? { i < keys.count ? keys[i] : nil }
        for i in keys.indices {
            let k = keys[i]
            if (k == "remind" || k == "let"), at(i + 1) == "me" { return ws[i...(i + 1)].map(\.raw).joined(separator: " ") }
            if k == "mujhe" { return ws[i].raw }
            guard speakerSubjects.contains(k) else { continue }
            var j = i + 1
            while let w = at(j), speakerAdverbs.contains(w) { j += 1 }
            guard let first = at(j) else { continue }
            func phrase(through end: Int) -> String { ws[i...min(end, ws.count - 1)].map(\.raw).joined(separator: " ") }
            if k == "i'll" || k == "ill" { return ws[i].raw }
            if speakerWantVerbs.contains(first), at(j + 1) == "to" { return phrase(through: j + 1) }
            if speakerModals.contains(first) { return phrase(through: j) }
            if first == "would", at(j + 1) == "like", at(j + 2) == "to" { return phrase(through: j + 2) }
            if k == "i'm" || k == "im" {
                if first == "going", at(j + 1) == "to" { return phrase(through: j + 1) }
            } else if first == "am", at(j + 1) == "going", at(j + 2) == "to" {
                return phrase(through: j + 2)
            }
        }
        return nil
    }

    // MARK: The person

    /// The person another clause names: a role, "me", a family word, or a name with a doer cue.
    private static func namedBy(_ clause: String, knownPeople: [String]) -> String? {
        let ws = words(clause)
        if ws.contains(where: { firstPerson.contains($0.key) }) { return Assignee.me }
        if let role = Assignee.detect(in: clause), !role.isEmpty { return role }
        for name in knownPeople where assigneeEvidence(name, in: clause, knownPeople: knownPeople) != nil { return name }
        return nil
    }

    /// The words that name `value` as the one who does the task, or nil. `in` is the clause (nil: no clear clause).
    static func assigneeEvidence(_ value: String, in text: String?, knownPeople: [String]) -> String? {
        guard let text else { return nil }
        let name = Assignee.normalize(value)
        let low = name.lowercased()
        let ws = words(text)
        if low == Assignee.me.lowercased() { return ws.first(where: { firstPerson.contains($0.key) })?.raw }
        if low == Assignee.family.lowercased() { return ws.first(where: { familyWords.contains($0.key) })?.raw }
        if low == Assignee.househelp.lowercased() {
            let said = text.lowercased()
            if let alias = householdAliases.first(where: { a in said.split(whereSeparator: { !($0.isLetter || $0 == "'") }).joined(separator: " ").contains(a) }) { return alias }
            return nil
        }
        if Assignee.isRole(name) { return ws.first(where: { $0.key == low })?.raw }
        let parts = low.split(separator: " ").map(String.init)
        guard !parts.isEmpty, !parts.contains(where: { notPeople.contains($0) || festivals.contains($0) }) else { return nil }
        let known = knownPeople.contains { Assignee.normalize($0).lowercased() == low }
        let keys = ws.map(\.key)
        for i in 0...(max(keys.count - parts.count, 0)) where i + parts.count <= keys.count && Array(keys[i..<(i + parts.count)]) == parts {
            let end = i + parts.count
            let before = i > 0 ? keys[i - 1] : nil
            let after = end < keys.count ? keys[end] : nil
            let cued = (before.map { cueBefore.contains($0) } ?? false)
                || (after.map { cueAfter.contains($0) } ?? false)
                || (known && before == "for")
            if cued {
                let from = (before.map { cueBefore.contains($0) || $0 == "for" } ?? false) ? i - 1 : i
                let to = (after.map { cueAfter.contains($0) } ?? false) ? end + 1 : end
                return ws[from..<to].map(\.raw).joined(separator: " ")
            }
        }
        return nil
    }

    // MARK: The day and the time

    private static func windows(_ ws: [Word], maxLength: Int) -> [String] {
        var out: [String] = []
        for n in 1...maxLength where ws.count >= n {
            for i in 0...(ws.count - n) { out.append(ws[i..<(i + n)].map(\.raw).joined(separator: " ")) }
        }
        return out
    }

    private static func dayPhrase(_ due: Date, in text: String, reading: WhenReading?, now: Date, calendar: Calendar) -> String? {
        if let d = reading?.day, calendar.isDate(d, inSameDayAs: due), let p = reading?.phrases["day"] { return p }
        // A date said another way ("30 October", "on the 5th"): a window of the words that reads as exactly that day. A bare number is
        // not a day, so "5 apples" never makes the 5th.
        for w in windows(words(text), maxLength: 4) where w.contains(where: \.isLetter) {
            if case .day(let d) = DateResolver.read(w, now: now, calendar: calendar), calendar.isDate(d, inSameDayAs: due) { return w }
        }
        return nil
    }

    private static func timePhrase(_ minutes: Int, in text: String, reading: WhenReading?) -> String? {
        if reading?.timeMinutes == minutes, let p = reading?.phrases["time"] { return p }
        for w in windows(words(text), maxLength: 3) where w.contains(where: \.isNumber) {
            if case .minutes(let m) = TimeResolver.read(w), m == minutes { return w }
        }
        return nil
    }

    private static func slotPhrase(_ slot: DaySlot, in text: String, reading: WhenReading?) -> String? {
        if reading?.slot == slot, let p = reading?.phrases["slot"] { return p }
        return words(text).first(where: { TimeResolver.slotWords[$0.key] == slot })?.raw
    }

    private static func repeatPhrase(_ spec: RecurrenceSpec, schedule: String?, in text: String) -> String? {
        for w in windows(words(text), maxLength: 9) {
            if case .spec(let read, _, _) = RecurrenceParser.read(w), read == spec { return w }
        }
        // Said in other words the parser reads to the same repeat: the repeat's own words are all in the clause.
        if let schedule {
            let mine = Provenance.words(schedule)
            let heard = Provenance.words(text)
            if !mine.isEmpty, mine.allSatisfy({ Provenance.matches($0, among: heard) }) { return schedule }
        }
        return nil
    }
}
