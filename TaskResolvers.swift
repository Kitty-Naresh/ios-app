import Foundation
import NaturalLanguage

// MARK: - What Swift works out from the user's words
//
// The model hands back the words it heard ("tomorrow", "5 pm", "every other week on Monday"). Swift turns them into dates, minutes and
// repeats, with the device's calendar and clock. A value that cannot be read is kept as said and flagged on the card; it is never
// guessed and never dropped. These readers are plain functions of their input, so the tests do not need the model.

// MARK: Dates

enum DateReading: Equatable {
    case day(Date)          // a day Swift could work out
    case soft(String)       // a timeframe that is not a day ("next week"): kept as said
    case invalid            // not readable: kept as said, flagged
}

enum DateResolver {
    private static let weekdayPrefixes: [(String, Int)] = [("sun", 1), ("mon", 2), ("tue", 3), ("wed", 4), ("thu", 5), ("fri", 6), ("sat", 7)]
    private static let months: [(String, Int)] = [("jan", 1), ("feb", 2), ("mar", 3), ("apr", 4), ("may", 5), ("jun", 6), ("jul", 7),
                                                  ("aug", 8), ("sep", 9), ("oct", 10), ("nov", 11), ("dec", 12)]
    private static let numberWords: [String: Int] = ["a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
                                                     "seven": 7, "eight": 8, "nine": 9, "ten": 10]

    static func weekday(_ word: String) -> Int? {
        let w = word.lowercased()
        guard w.count >= 3 else { return nil }
        let full = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
        if let i = full.firstIndex(where: { $0 == w || $0 + "s" == w }) { return i + 1 }
        if ["tues", "thur", "thurs", "weds"].contains(w) { return ["tues": 3, "thur": 5, "thurs": 5, "weds": 4][w] }
        if w.count == 3, let hit = weekdayPrefixes.first(where: { $0.0 == w }) { return hit.1 }
        return nil
    }

    private static func month(_ word: String) -> Int? {
        let w = word.lowercased()
        guard w.count >= 3 else { return nil }
        let full = ["january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december"]
        if let i = full.firstIndex(of: w) { return i + 1 }
        if w == "sept" { return 9 }
        return months.first(where: { $0.0 == w })?.1
    }

    private static func words(_ s: String) -> [String] {
        s.lowercased().replacingOccurrences(of: ",", with: " ").split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    private static func number(_ w: String) -> Int? {
        if let n = Int(w) { return n }
        let digits = w.prefix(while: { $0.isNumber })
        if !digits.isEmpty, ["st", "nd", "rd", "th"].contains(String(w.dropFirst(digits.count))) { return Int(digits) }
        return numberWords[w]
    }

    static func read(_ raw: String, now: Date = Date(), calendar: Calendar = .current) -> DateReading {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .invalid }
        let today = calendar.startOfDay(for: now)
        func add(_ days: Int) -> Date? { calendar.date(byAdding: .day, value: days, to: today) }

        // An ISO day, exactly as the brief's instructions say it may be written.
        if let d = BulkValidator.date(text, calendar: calendar), text.prefix(10).count == 10, text.prefix(10).contains("-") { return .day(d) }

        var w = words(text).filter { !["on", "by", "the", "of", "at", "this", "coming"].contains($0) || $0 == "this" }
        let hadThis = w.contains("this")
        w = w.filter { $0 != "this" }
        let joined = w.joined(separator: " ")

        switch joined {
        case "today", "tonight": return add(0).map { .day($0) } ?? .invalid
        case "tomorrow", "tmrw", "tmr", "tomorow": return add(1).map { .day($0) } ?? .invalid
        case "day after tomorrow", "the day after tomorrow": return add(2).map { .day($0) } ?? .invalid
        case "yesterday": return add(-1).map { .day($0) } ?? .invalid
        default: break
        }

        // "in 3 days", "in 2 weeks", "in a week"
        if w.count == 3, w[0] == "in", let n = number(w[1]) {
            if w[2].hasPrefix("day") { return add(n).map { .day($0) } ?? .invalid }
            if w[2].hasPrefix("week") { return add(n * 7).map { .day($0) } ?? .invalid }
        }

        // "monday", "next monday", "this friday"
        if w.count <= 2, let name = w.last, let wd = weekday(name), w.count == 1 || w[0] == "next" || hadThis {
            let current = calendar.component(.weekday, from: today)
            var ahead = (wd - current + 7) % 7
            if ahead == 0 && !(hadThis && w.count == 1) { ahead = 7 }      // "friday" said on a Friday is next week's; "this friday" is today
            return add(ahead).map { .day($0) } ?? .invalid
        }

        // "5th": the next such day of a month
        if w.count == 1, w[0].first?.isNumber == true, w[0] != String(Int(w[0]) ?? -1), let n = number(w[0]), (1...31).contains(n) {
            var comps = DateComponents()
            comps.day = n
            if let d = calendar.nextDate(after: add(-1) ?? today, matching: comps, matchingPolicy: .nextTime) { return .day(calendar.startOfDay(for: d)) }
        }

        // "november 2", "nov 2nd", "2 november", "2nd of november 2027"
        if w.count >= 2, w.count <= 3 {
            var m: Int?, d: Int?, y: Int?
            for token in w {
                if let mm = month(token), m == nil { m = mm }
                else if let n = number(token) {
                    if n > 1_000 { y = n } else if d == nil, (1...31).contains(n) { d = n }
                }
            }
            if let m, let d {
                var comps = DateComponents()
                comps.month = m
                comps.day = d
                if let y {
                    comps.year = y
                    if let date = calendar.date(from: comps), calendar.component(.day, from: date) == d { return .day(calendar.startOfDay(for: date)) }
                    return .invalid
                }
                if let date = calendar.nextDate(after: add(-1) ?? today, matching: comps, matchingPolicy: .strict) { return .day(calendar.startOfDay(for: date)) }
                return .invalid
            }
        }

        // A timeframe that is not a day: kept as said, never turned into one.
        let soft = ["week", "weekend", "month", "year", "quarter", "later", "soon", "sometime", "someday", "eventually", "end", "fortnight"]
        if w.contains(where: { soft.contains($0) || soft.contains(String($0.dropLast())) }) { return .soft(text) }
        return .invalid
    }
}

// MARK: Times

enum TimeReading: Equatable {
    case minutes(Int)       // an exact time, in minutes after midnight
    case slot(DaySlot)      // a part of the day
    case invalid
}

enum TimeResolver {
    static let slotWords: [String: DaySlot] = ["morning": .morning, "afternoon": .afternoon, "evening": .evening, "night": .night, "tonight": .night]

    static func read(_ raw: String) -> TimeReading {
        var t = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        for lead in ["at ", "by ", "around ", "before ", "after ", "in the ", "this "] where t.hasPrefix(lead) { t = String(t.dropFirst(lead.count)) }
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return .invalid }
        if let slot = slotWords[t] { return .slot(slot) }
        if t == "noon" || t == "midday" { return .minutes(12 * 60) }
        if t == "midnight" { return .minutes(0) }
        if let m = DaySlot.parseHHmm(t) { return .minutes(m) }
        // "5 pm", "5:30pm", "5.30 p.m."
        let compact = t.replacingOccurrences(of: ".", with: ":").replacingOccurrences(of: ":m", with: "m").replacingOccurrences(of: " ", with: "")
        guard let suffix = ["am", "pm"].first(where: { compact.hasSuffix($0) }) else { return .invalid }
        let body = compact.dropLast(2)
        let parts = body.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count <= 2, let h = Int(parts[0]), (1...12).contains(h) else { return .invalid }
        let m = parts.count == 2 ? Int(parts[1]) : 0
        guard let minutes = m, (0...59).contains(minutes) else { return .invalid }
        return .minutes((h % 12 + (suffix == "pm" ? 12 : 0)) * 60 + minutes)
    }
}

// MARK: Repeats

enum ScheduleReading: Equatable {
    case once
    case spec(RecurrenceSpec, slot: DaySlot?, minutes: Int?)
    case unsupported
}

/// A few repeats Swift can run, read from the user's words: every day, weekdays, chosen days, every other day, every N days or weeks,
/// monthly on a day, and "every day except Sunday". Anything else ("twice a day", "when I remember", "after meals") is unsupported:
/// kept as said and flagged, never turned into something it is not. A word the reader does not know makes the whole repeat unsupported,
/// so a qualifier ("every day after lunch") is never silently dropped.
enum RecurrenceParser {
    private static let known: Set<String> = [
        "every", "each", "day", "days", "daily", "everyday", "weekday", "weekdays", "weekend", "weekends", "other", "alternate", "alternating",
        "second", "week", "weeks", "weekly", "biweekly", "fortnightly", "fortnight", "month", "months", "monthly", "on", "the", "and", "at",
        "to", "through", "thru", "until", "from", "except", "but", "not", "excluding", "apart", "than", "morning", "mornings", "afternoon",
        "afternoons", "evening", "evenings", "night", "nights", "am", "pm", "of", "noon", "repeat", "repeats", "repeating"
    ]

    private static func tokens(_ s: String) -> [String] {
        var t = s.lowercased()
        for (a, b) in [(",", " "), ("&", " and "), ("–", "-"), ("—", "-"), ("-", " to "), (".", " ")] { t = t.replacingOccurrences(of: a, with: b) }
        // "5:30" has lost its colon-free form above only for the dot, so put clock times back together.
        return t.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    static func read(_ raw: String) -> ScheduleReading {
        let lower = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !lower.isEmpty else { return .unsupported }
        if ["once", "one time", "one-time", "just once", "no repeat", "not repeating", "never", "none"].contains(lower) { return .once }
        for bad in ["times a", "time a", "twice", "thrice", "once a", "once per", "per day", "per week", "a week", "a day", "a month", "when i", "if ", "after ", "before ", "whenever", "as needed"] where lower.contains(bad) {
            return .unsupported
        }

        // An exact time of the day: "every day at 8 pm" / "daily at 20:30".
        var minutes: Int?
        var body = lower
        if let r = body.range(of: "(?:\\bat|@)\\s*\\d{1,2}(?::\\d{2})?\\s*(?:am|pm|a\\.m\\.|p\\.m\\.)?", options: .regularExpression) {
            let said = String(body[r]).replacingOccurrences(of: "at", with: "").replacingOccurrences(of: "@", with: "")
            if case .minutes(let m) = TimeResolver.read(said) { minutes = m; body.removeSubrange(r) } else { return .unsupported }
        }

        // The day-of-the-month ordinal ("the 5th") and the interval number ("every 3 days") are numbers, not unknown words.
        let words = tokens(body)
        var slot: DaySlot?
        var interval: Int?
        var ordinal: Int?
        var days: [Int] = []
        var excluded: [Int] = []
        var afterExcept = false
        var sawEvery = false, sawDay = false, sawWeek = false, sawMonth = false, sawOther = false
        var weekdaysWord = false, weekendWord = false
        var rangeStart: Int?
        var rangeLinked = false
        var plainRepeatWord = false

        for (i, w) in words.enumerated() {
            if let n = Int(w) {
                let next = i + 1 < words.count ? words[i + 1] : ""
                if next.hasPrefix("day") || next.hasPrefix("week") { interval = n } else { return .unsupported }
                continue
            }
            let digits = w.prefix(while: { $0.isNumber })
            if !digits.isEmpty, let n = Int(digits), ["st", "nd", "rd", "th"].contains(String(w.dropFirst(digits.count))) {
                guard (1...31).contains(n) else { return .unsupported }
                ordinal = n
                continue
            }
            if let wd = DateResolver.weekday(w) {
                if rangeLinked, let start = rangeStart {
                    var d = start
                    var span = [start]
                    while d != wd { d = d % 7 + 1; span.append(d) }
                    if afterExcept { excluded += span } else { days += span }
                    rangeLinked = false
                    rangeStart = nil
                    plainRepeatWord = true
                } else if afterExcept { excluded.append(wd) } else { days.append(wd); rangeStart = wd }
                if w.hasSuffix("s") && !afterExcept { plainRepeatWord = true }
                continue
            }
            switch w {
            case "to", "through", "thru", "until": if rangeStart != nil { rangeLinked = true } else { return .unsupported }; continue
            case "except", "excluding", "but", "apart": afterExcept = true; rangeStart = nil; continue
            case "every", "each": sawEvery = true; plainRepeatWord = true
            case "day", "days": sawDay = true
            case "daily", "everyday": sawDay = true; plainRepeatWord = true
            case "weekday", "weekdays": weekdaysWord = true; plainRepeatWord = true
            case "weekend", "weekends": weekendWord = true; plainRepeatWord = true
            case "other", "alternate", "alternating", "second": sawOther = true
            case "week", "weeks": sawWeek = true
            case "weekly": sawWeek = true; plainRepeatWord = true
            case "biweekly", "fortnightly", "fortnight": sawWeek = true; sawOther = true; plainRepeatWord = true
            case "month", "months": sawMonth = true
            case "monthly": sawMonth = true; plainRepeatWord = true
            // A part of the day says WHEN ("Saturday morning"), not how often: only the plural ("mornings"), or one beside "every", repeats.
            case "morning", "mornings": slot = .morning; if w.hasSuffix("s") { plainRepeatWord = true }
            case "afternoon", "afternoons": slot = .afternoon; if w.hasSuffix("s") { plainRepeatWord = true }
            case "evening", "evenings": slot = .evening; if w.hasSuffix("s") { plainRepeatWord = true }
            case "night", "nights": slot = .night; if w.hasSuffix("s") { plainRepeatWord = true }
            default: if !known.contains(w) { return .unsupported }
            }
        }
        guard plainRepeatWord || sawOther else { return .unsupported }
        if afterExcept && excluded.isEmpty { return .unsupported }

        func spec(_ s: RecurrenceSpec) -> ScheduleReading { .spec(s, slot: slot, minutes: minutes) }
        let wholeWeek = [1, 2, 3, 4, 5, 6, 7]
        let chosen = Array(Set(days)).sorted()
        let out = Set(excluded)

        if sawMonth {
            guard let n = ordinal, chosen.isEmpty, interval == nil, !sawWeek, out.isEmpty else { return .unsupported }
            return spec(RecurrenceSpec(dayOfMonth: n))
        }
        if ordinal != nil { return .unsupported }
        if sawWeek {
            var n = 1
            if sawOther { n = 2 } else if let i = interval { n = i }
            guard (1...52).contains(n), !chosen.isEmpty, out.isEmpty, !weekdaysWord, !weekendWord else { return .unsupported }
            return spec(RecurrenceSpec(weekdays: chosen, everyNWeeks: n))
        }
        if sawOther || interval != nil {
            guard sawDay, chosen.isEmpty, out.isEmpty, !weekdaysWord, !weekendWord else { return .unsupported }
            let n = sawOther ? 2 : (interval ?? 1)
            guard (1...365).contains(n) else { return .unsupported }
            return n == 1 ? spec(RecurrenceSpec()) : spec(RecurrenceSpec(intervalDays: n))
        }
        if weekdaysWord || weekendWord {
            guard chosen.isEmpty, !(weekdaysWord && weekendWord) else { return .unsupported }
            let left = (weekdaysWord ? [2, 3, 4, 5, 6] : [1, 7]).filter { !out.contains($0) }
            return left.isEmpty ? .unsupported : spec(RecurrenceSpec(weekdays: left))
        }
        if !chosen.isEmpty {
            let left = chosen.filter { !out.contains($0) }
            guard !left.isEmpty else { return .unsupported }
            return spec(RecurrenceSpec(weekdays: left))
        }
        // Every day, or every day but some.
        guard sawEvery || sawDay || slot != nil else { return .unsupported }
        if !out.isEmpty {
            let left = wholeWeek.filter { !out.contains($0) }
            return left.isEmpty ? .unsupported : spec(RecurrenceSpec(weekdays: left))
        }
        return spec(RecurrenceSpec())
    }
}

// MARK: - From the model's words to drafts

/// One extracted task in the form the review card, the edit sheet and the save already understand. Swift fills what the model must
/// not: the date, the time of day, the repeat. Absent stays nil (never ""). Nothing here writes anything; the review is the boundary.
enum TaskDraftMapper {
    static func clean(_ s: String?) -> String? {
        guard let s else { return nil }
        let t = s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// A draft, or nil for a blank title (that draft is dropped). `wordsAreThisTasks` says the transcript holds one task's words only
    /// (the answer has exactly one task), so `WhenReader` may take a day or time from it that the task's own fields lack.
    static func item(from t: ExtractionTaskValue, listName fallback: String? = nil, now: Date = Date(), calendar: Calendar = .current,
                     transcript: String? = nil, wordsAreThisTasks: Bool = false, knownPeople: [String] = []) -> DraftItem? {
        guard let title = clean(t.title) else { return nil }
        // The one check for "is this a task": nothing is made from words that only talk to the app ("create", "a new task").
        guard TaskMeaning.isMeaningful(title: title, utterance: transcript ?? "") else {
            Trace.step("WARNING", "the title \"\(title)\" says nothing about a task (app-talk, a bare command, or the spoken command itself): refused")
            return nil
        }
        var item = DraftItem(title: title)
        item.assignee = clean(t.assignee).map(Assignee.normalize).flatMap { $0.isEmpty ? nil : $0 }
        item.reason = clean(t.purpose)
        item.instructions = clean(t.instructions)
        // The brief: only context the user provided. A purpose or instructions made of words the user never said, or that only
        // repeat the title, is the model's invention and is not kept (the measured model fills them with "purchase", "shopping").
        if let transcript {
            if let r = item.reason, !Provenance.said(r, in: transcript, notRepeating: title) {
                Trace.step("SWIFT", "purpose \"\(r)\" is not in what the user said, or only repeats the title: not kept")
                item.reason = nil
            }
            if let n = item.instructions, !Provenance.said(n, in: transcript, notRepeating: title) {
                Trace.step("SWIFT", "instructions \"\(n)\" are not in what the user said, or only repeat the title: not kept")
                item.instructions = nil
            }
        }
        item.listName = clean(t.listName) ?? clean(fallback)

        // Time of day: an exact time, or a part of the day.
        var slot: DaySlot?
        if let raw = clean(t.dueTime) {
            switch TimeResolver.read(raw) {
            case .minutes(let m): item.timeMinutes = m
            case .slot(let s): slot = s
            case .invalid: item.unparsed["time"] = raw
            }
        }

        // The day. A part of the day inside it ("tomorrow evening") is taken out and becomes the slot. `report` says whether a day
        // Swift cannot read is kept and flagged (the day field) or just left alone (a repeat field that turned out to be a day).
        @discardableResult
        func takeDay(_ raw: String, report: Bool) -> Bool {
            var rest: [String] = []
            var heardSlot: DaySlot?
            for word in raw.split(whereSeparator: { $0.isWhitespace }).map(String.init) {
                let key = word.lowercased().trimmingCharacters(in: .punctuationCharacters)
                if let s = TimeResolver.slotWords[key], key != "tonight" { if heardSlot == nil { heardSlot = s } } else { rest.append(word) }
            }
            if raw.lowercased().contains("tonight"), heardSlot == nil { heardSlot = .night }
            let day = rest.joined(separator: " ")
            var found: (due: Date?, soft: String?)?
            if !day.isEmpty {
                switch DateResolver.read(day, now: now, calendar: calendar) {
                case .day(let d): found = (d, nil)
                case .soft(let s): found = (nil, s)
                case .invalid:
                    if report { item.unparsed["date"] = raw; if slot == nil { slot = heardSlot } }
                    return false
                }
            } else if heardSlot == nil { return false }
            if let f = found { item.due = f.due; item.softDue = f.soft }
            if slot == nil { slot = heardSlot }
            return true
        }
        if let raw = clean(t.dueDate) { takeDay(raw, report: true) }
        if item.timeMinutes == nil { item.slot = slot }

        // The repeat. A routine only when Swift can run it; otherwise a one-time task that keeps the words and is flagged.
        if let raw = clean(t.schedule) {
            item.schedule = raw
            switch RecurrenceParser.read(raw) {
            case .once: break
            case .spec(let spec, let s, let minutes):
                item.kind = .routine
                item.recurrence = spec
                if item.timeMinutes == nil, item.slot == nil { item.slot = s }
                if item.timeMinutes == nil, let minutes { item.timeMinutes = minutes; item.slot = nil }
            case .unsupported:
                // A schedule that says a day or a part of the day and no repeat ("tomorrow evening") is when it is due, not how
                // often. It is read as the day; nothing is made a routine.
                let low = raw.lowercased()
                let repeatWords = ["every", "each", "daily", "weekly", "monthly", "weekday", "weekend", "other", "alternate", "times", "twice", "once a", "per ", "often", "regular", "when ", "whenever", "after ", "before ", "if "]
                let noRepeat = !repeatWords.contains(where: { low.contains($0) })
                if noRepeat, item.due == nil, item.softDue == nil, takeDay(raw, report: false) {
                    item.schedule = nil
                    if item.timeMinutes == nil { item.slot = slot }
                } else if noRepeat, let said = dayReading(raw, now: now, calendar: calendar), sameDay(said, as: item, calendar: calendar) {
                    // The task already has this day (a scope filled it): the schedule only said it again. It is not a repeat, so nothing
                    // is flagged and nothing is written into the saved notes. A different day stays flagged: the two disagree.
                    item.schedule = nil
                    if item.timeMinutes == nil, item.slot == nil { item.slot = said.slot }
                } else {
                    item.unparsed["repeat"] = raw
                }
            }
        }
        // The model sometimes leaves the repeat out ("clean the baby mat every day" comes back as a one-time task). If this task's own words
        // say how often, in words the parser reads, it is a routine: the repeat is what the user said, cut out of the title if it was left there.
        if item.kind != .routine, clean(t.schedule) == nil, let transcript {
            let own = wordsAreThisTasks ? transcript : EvidenceGate.clause(for: item.title, in: transcript)
            if let own, let said = RepeatReader.phrase(in: own), case .spec(let spec, let s, let minutes) = RecurrenceParser.read(said) {
                Trace.step("SWIFT", "the model left the repeat out; the words say \"\(said)\", so this is a routine")
                item.kind = .routine
                item.recurrence = spec
                item.schedule = said
                if item.timeMinutes == nil, item.slot == nil { item.slot = s }
                if item.timeMinutes == nil, let minutes { item.timeMinutes = minutes; item.slot = nil }
                if let cut = RepeatReader.removing(said, from: item.title) { item.title = cut }
            }
        }
        // A when-phrase the model left in a field it does not belong to, or could not give as a value, is read here: it fills only what
        // is still empty and is cut out of where it was.
        WhenReader.apply(&item, from: t, transcript: transcript, readsTranscript: wordsAreThisTasks, now: now, calendar: calendar)
        // Every attribute the user's words for this task do not back is cleared, and the words that back each kept one are recorded.
        EvidenceGate.apply(&item, from: t, transcript: transcript, wordsAreThisTasks: wordsAreThisTasks, knownPeople: knownPeople, now: now, calendar: calendar)
        return item
    }

    /// A text that says a day and a part of the day and nothing else ("tomorrow evening", "2026-10-30"): the day (or timeframe) and the slot.
    /// Nil when it says anything else. Used to tell a day written in the repeat field from a repeat.
    static func dayReading(_ raw: String, now: Date, calendar: Calendar) -> (due: Date?, soft: String?, slot: DaySlot?)? {
        var rest: [String] = []
        var slot: DaySlot?
        for word in raw.split(whereSeparator: { $0.isWhitespace }).map(String.init) {
            let key = word.lowercased().trimmingCharacters(in: .punctuationCharacters)
            if let s = TimeResolver.slotWords[key] { if slot == nil { slot = s } } else { rest.append(word) }
        }
        let day = rest.joined(separator: " ")
        if day.isEmpty { return slot == nil ? nil : (nil, nil, slot) }
        switch DateResolver.read(day, now: now, calendar: calendar) {
        case .day(let d): return (d, nil, slot)
        case .soft(let s): return (nil, s, slot)
        case .invalid: return nil
        }
    }

    /// The day the text says is the day the item already has (a part of the day alone agrees with any day).
    private static func sameDay(_ said: (due: Date?, soft: String?, slot: DaySlot?), as item: DraftItem, calendar: Calendar) -> Bool {
        if let d = said.due { return item.due.map { calendar.isDate($0, inSameDayAs: d) } ?? false }
        if let s = said.soft { return item.softDue.map { Words.key($0) == Words.key(s) } ?? false }
        return true
    }

    /// What makes two drafts the same request. Every field the user could have said, and the list.
    static func identity(_ i: DraftItem) -> String {
        func key(_ s: String?) -> String { s.map { Words.key($0) } ?? "" }
        var parts: [String] = []
        parts.append(i.kind.rawValue)
        parts.append(Words.key(i.title))
        parts.append(key(i.schedule))
        parts.append(key(i.assignee))
        parts.append(i.due.map { String($0.timeIntervalSince1970) } ?? "")
        parts.append(key(i.softDue))
        parts.append(i.timeMinutes.map { String($0) } ?? "")
        parts.append(i.slot?.rawValue ?? "")
        parts.append(key(i.reason))
        parts.append(key(i.instructions))
        parts.append(key(i.listName))
        let unparsed: [String] = i.unparsed.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        parts.append(unparsed.joined(separator: ","))
        return parts.joined(separator: "|")
    }
}

// MARK: - A list named in the words

/// A saved list the user's words put a task on: "to the Blinkit order", "on my pharmacy list", "into Goa trip". Only after "to", "on", "in",
/// "into" or "onto" (and "the", "my", "our"), and only when the words that follow begin with the list's name (or its short name,
/// "Blinkit" for "Blinkit order"). A list that does not exist is never made from the words here: the model names those.
enum ListMention {
    private static let before: Set<String> = ["to", "on", "in", "into", "onto"]
    private static let determiners: Set<String> = ["the", "my", "our", "a"]

    static func existing(in words: String, among lists: [String]) -> String? {
        guard !lists.isEmpty else { return nil }
        let tokens = words.lowercased().split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map { TaskLabels.stem(String($0)) }
        var best: (name: String, size: Int)?
        for (n, token) in tokens.enumerated() where before.contains(token) {
            var rest = Array(tokens[(n + 1)...])
            while let first = rest.first, determiners.contains(first) { rest.removeFirst() }
            guard !rest.isEmpty else { continue }
            for list in lists {
                let full = TaskLabels.stemKey(list).split(separator: " ").map(String.init)
                let short = TaskLabels.stemKey(TaskLabels.listShort(list)).split(separator: " ").map(String.init)
                for name in [full, short] where !name.isEmpty && rest.starts(with: name) {
                    if best == nil || name.count > best!.size { best = (list, name.count) }
                }
            }
        }
        return best?.name
    }
}

/// Whether a list name the model gave may become a list. The model reads a garbled sentence into a name ("House Add hostel") that is
/// literally in the words, so being in the words proves nothing, and a model that has seen example list names in its instructions
/// copies them ("to the Blinkit order") into sentences that have no list. A list is a value like any other: it needs the user's words.
/// A name is accepted only when (1) it holds no word that talks to the app ("add", "create", "task"), (2) every word of its own (what is
/// left once the cue words list, order, cart and the fillers "to the my" are taken away) is in the words, and (3) a cue word touches one
/// of them: "Blinkit order", "grocery list", "list for the Goa trip". The verb in "order food from Swiggy" is not a cue because it
/// touches no word of the name, and a list the household already has is not accepted unless the words say it. Anything else is dropped
/// and said on the card.
enum ListNameGate {
    private static let cues: Set<String> = ["list", "lists", "order", "orders", "cart", "carts"]
    private static let fillers: Set<String> = ["to", "the", "my", "our", "a", "an", "on", "in", "into", "onto", "for", "of"]
    private static let commandWords: Set<String> = TaskMeaning.bareVerbs.union(["task", "tasks", "reminder", "reminders", "todo", "todos"])

    private static func split(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init)
    }
    private static func same(_ a: String, _ b: String) -> Bool { a == b || TaskLabels.stem(a) == TaskLabels.stem(b) }

    /// Nil when the name is accepted; otherwise the reason it is not. `known` is not evidence and is not used to accept a name.
    static func rejection(_ name: String, words: String, known: [String]) -> String? {
        let tokens = split(name)
        if let word = tokens.first(where: { commandWords.contains($0) }) { return "it holds the word \"\(word)\", which talks to the app" }
        let own = tokens.filter { !cues.contains($0) && !fillers.contains($0) }
        guard !own.isEmpty else { return "the name has no word of its own" }
        let said = split(words)
        for w in own where !said.contains(where: { same($0, w) }) { return "\"\(w)\" is not in the words" }
        for (i, s) in said.enumerated() where own.contains(where: { same(s, $0) }) {
            if i + 1 < said.count, cues.contains(said[i + 1]) { return nil }          // "Blinkit order", "grocery list"
            var j = i - 1
            while j >= 0, fillers.contains(said[j]) { j -= 1 }                         // "list for the Goa trip"
            if j >= 0, cues.contains(said[j]) { return nil }
            if i > 0, cues.contains(said[i - 1]) { return nil }                        // "cart Blinkit"
        }
        return "the words do not say list, order or cart next to \"\(own.joined(separator: " "))\""
    }
}

/// Pieces of a task the model wrote as tasks of their own. A small model sometimes lists the words of one sentence ("order food from
/// Swiggy today" as "order food from Swiggy", "today", "food", "order", "Swiggy"). A title that is only a day, time or timeframe word,
/// or whose words are all inside another, longer title of the same answer, is a piece of that task, not a task. It is dropped before
/// anything else reads the answer, so the one real task is the only task and the words it was said with (the day) belong to it. Two
/// titles that are the same are left to the existing duplicate check. This is a shape rule: it never reads what a task means.
enum FragmentGuard {
    private static let whenWords: Set<String> = [
        "today", "tomorrow", "tonight", "morning", "afternoon", "evening", "night", "weekend", "week", "month", "next", "this", "last",
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday", "at", "on", "by", "before", "after", "in", "the",
        "kal", "aaj", "parso", "subah", "shaam", "raat", "dopahar"]

    private static func split(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init)
    }

    /// The tasks to keep, and the titles dropped. When every task would go, none does.
    static func filter(_ tasks: [ExtractionTaskValue]) -> (kept: [ExtractionTaskValue], dropped: [String]) {
        guard tasks.count > 1 else { return (tasks, []) }
        let words = tasks.map { Set(split($0.title)) }
        var kept: [ExtractionTaskValue] = [], dropped: [String] = []
        for (i, t) in tasks.enumerated() {
            let mine = words[i]
            let onlyWhen = !mine.isEmpty && mine.allSatisfy { whenWords.contains($0) || !$0.contains(where: \.isLetter) }
            let inside = !mine.isEmpty && tasks.indices.contains { j in j != i && words[j].count > mine.count && mine.isSubset(of: words[j]) }
            if onlyWhen || inside { dropped.append(t.title) } else { kept.append(t) }
        }
        return kept.isEmpty ? (tasks, []) : (kept, dropped)
    }
}

/// A restatement inside one dictation: "Add House Add hostel task for tomorrow I said, add Househelp tasks for tomorrow ...". The words before
/// "I said," (or "I meant,", "I mean,") are the attempt the speaker is replacing. This is a SHAPE rule, not a reading of meaning: it cuts at
/// the last such marker that is followed by a comma or colon and has content on both sides. The words before it are not thrown away: they
/// are shown as heard but not used, with a way to add them, and the extraction reads what follows. An "I said," that is part of a real task
/// is cut the same way; the shown words are how the user gets it back.
enum Restatement {
    private static let marker = try? NSRegularExpression(pattern: "\\bi\\s+(?:said|meant|mean)\\s*[,:]", options: [.caseInsensitive])

    private static func contentWords(_ text: String) -> Int {
        text.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
            .filter { !TaskMeaning.appTalk.contains($0) && !TaskMeaning.bareVerbs.contains($0) }.count
    }

    static func cut(_ text: String) -> (before: String, after: String)? {
        guard let marker else { return nil }
        let ns = text as NSString
        let hits = marker.matches(in: text, range: NSRange(location: 0, length: ns.length))
        for hit in hits.reversed() {
            let before = ns.substring(to: hit.range.location).trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
            let after = ns.substring(from: hit.range.location + hit.range.length).trimmingCharacters(in: .whitespacesAndNewlines)
            if contentWords(before) >= 1, contentWords(after) >= 2 { return (before, after) }
        }
        return nil
    }
}

/// Words that only set the scope: "I said, Househelp tasks" or "for tomorrow" or "add to the Hostel list". While a draft waits, words that
/// say a known person, a day or time Swift can read, or an existing list, and nothing else, make no new task and need no model call: they
/// set what the draft's items leave empty. This is a SHAPE rule: anything else left over (a word that is not a command, a filler, a person,
/// a day, a time or a list) and the words go to the model as usual.
enum DraftHeader {
    struct Reading: Equatable {
        var assignee: String?
        var day: String?
        var time: String?
        var list: String?
        var isEmpty: Bool { assignee == nil && day == nil && time == nil && list == nil }
        var scope: DraftScope { DraftScope(assignee: assignee, day: day, time: time) }
        /// For the card and the trace: "Househelp, tomorrow, the Hostel list".
        var parts: [String] { [assignee, day, time, list.map { "the \($0) list" }].compactMap { $0 } }
    }

    private static let glue: Set<String> = ["at", "on", "by", "in", "into", "onto", "of", "and", "is", "are", "it", "them", "they", "all", "every", "so",
                                            "this", "will", "be", "do", "does", "these", "those", "my", "our", "assign", "assigned"]

    private static func tokens(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { $0.isWhitespace })
            .map { $0.trimmingCharacters(in: CharacterSet.punctuationCharacters.subtracting(CharacterSet(charactersIn: ":"))) }.filter { !$0.isEmpty }
    }

    /// Removes the first run of `toks` that reads as one of `candidates`, trying the longest run first. Returns the run's words joined.
    private static func take(_ toks: inout [String], longest: Int, where fits: (String) -> Bool) -> String? {
        for size in stride(from: min(longest, toks.count), through: 1, by: -1) {
            for start in 0...(toks.count - size) {
                let run = toks[start..<(start + size)].joined(separator: " ")
                if fits(run) { toks.removeSubrange(start..<(start + size)); return run }
            }
        }
        return nil
    }

    static func read(_ words: String, assignees: [String], lists: [String], now: Date, calendar: Calendar) -> Reading? {
        var toks = tokens(words)
        guard !toks.isEmpty else { return nil }
        var out = Reading()

        if let list = ListMention.existing(in: words, among: lists) {
            for name in [TaskLabels.stemKey(list), TaskLabels.stemKey(TaskLabels.listShort(list))] where !name.isEmpty {
                let size = name.split(separator: " ").count
                if take(&toks, longest: size, where: { run in run.split(separator: " ").count == size && TaskLabels.stemKey(run) == name }) != nil {
                    out.list = list; break
                }
            }
        }
        for name in assignees {
            let key = String(Assignee.normalize(name).lowercased().filter { $0.isLetter || $0.isNumber })
            guard !key.isEmpty, out.assignee == nil else { continue }
            if take(&toks, longest: 2, where: { String($0.filter { $0.isLetter || $0.isNumber }) == key }) != nil { out.assignee = Assignee.normalize(name) }
        }
        out.day = take(&toks, longest: 3) { run in
            // A timeframe that is not a day ("next week") needs more than one word: a lone "later" or "soon" is not a header.
            switch DateResolver.read(run, now: now, calendar: calendar) {
            case .day: return true
            case .soft: return run.contains(" ")
            case .invalid: return false
            }
        }
        out.time = take(&toks, longest: 3) { run in
            switch TimeResolver.read(run) { case .minutes, .slot: return true; case .invalid: return false }
        }
        guard !out.isEmpty else { return nil }
        let left = toks.filter { !(TaskMeaning.appTalk.contains($0) || TaskMeaning.bareVerbs.contains($0) || Coverage.talk.contains($0) || glue.contains($0)) }
        return left.isEmpty ? out : nil
    }
}

// MARK: - The flat answer, validated

extension BulkValidator {
    static let invalidAnswerQuestion = "Sorry, I didn't catch that. What would you like me to do?"

    /// A final turn where the model said `wait` (or `clarify` with no question) but its answer carries tasks. The model's wait means
    /// "the speech is unfinished"; once the user has stopped, tasks that pass every check a create passes (content, the spoken-command
    /// check, the blank-title drop, the list-name gate) are used. Nil when the outcome was something else, or no task is valid.
    static func decodeWaiting(_ e: ExtractionValue, context ctx: ValidationContext) -> (items: BulkValidated, count: Int)? {
        let outcome = e.outcome.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let noQuestion = Words.trim(e.question ?? "").isEmpty
        guard outcome == "wait" || (outcome == "clarify" && noQuestion), !e.tasks.isEmpty else { return nil }
        var asCreate = e
        asCreate.outcome = "create"
        guard case .items(let made) = decodeFlat(asCreate, context: ctx) else { return nil }
        return (.items(made), made.count)
    }

    /// The flat answer, checked before any draft is shown. A blank title drops that draft; a create with no tasks, or a clarify with no
    /// question, is an invalid response and nothing is made; a wait makes nothing and asks nothing; identical drafts are combined with a
    /// note on the card. No title is compared with the transcript and no count with the number of sentences.
    static func decodeFlat(_ e: ExtractionValue, context ctx: ValidationContext) -> BulkValidated {
        let outcome = e.outcome.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if outcome == "wait" { return .wait }
        guard outcome == "create" || outcome == "clarify" else {
            Trace.step("WARNING", "the model's outcome \"\(e.outcome)\" is not create, clarify or wait: an invalid response, nothing is made")
            return .clarify(invalidAnswerQuestion)
        }

        // A list name needs a cue in the words (or to be a list that exists). One that does not is dropped, and the card says so.
        var e = e
        let pieces = FragmentGuard.filter(e.tasks)
        if !pieces.dropped.isEmpty {
            Trace.step("WARNING", "\(pieces.dropped.count) task(s) were only pieces of another task or a bare day or time word (" + pieces.dropped.map { "\"\($0)\"" }.joined(separator: ", ") + "): dropped, not tasks")
            e.tasks = pieces.kept
        }
        var refusedLists: [String] = []
        if let said = ctx.transcript {
            func gated(_ name: String?) -> String? {
                guard let clean = TaskDraftMapper.clean(name) else { return nil }
                guard let why = ListNameGate.rejection(clean, words: said, known: ctx.knownLists) else { return clean }
                if !refusedLists.contains(clean) {
                    refusedLists.append(clean)
                    Trace.step("WARNING", "the list name \"\(clean)\" is not used: \(why). The tasks keep their person and day")
                }
                return nil
            }
            e.listName = gated(e.listName)
            for n in e.tasks.indices { e.tasks[n].listName = gated(e.tasks[n].listName) }
        }
        // The model named no list at all, but the words say the tasks go to one that exists ("to the Blinkit order"): it is used.
        var listFallback = e.listName
        if TaskDraftMapper.clean(listFallback) == nil, e.tasks.allSatisfy({ TaskDraftMapper.clean($0.listName) == nil }),
           let said = ctx.transcript, let found = ListMention.existing(in: said, among: ctx.knownLists) {
            Trace.step("SWIFT", "the model named no list, but the words say \"\(found)\", a list that exists: the tasks join it")
            listFallback = found
        }
        var items: [DraftItem] = []
        var firstIndex: [String: Int] = [:]
        var copies: [String: Int] = [:]
        var dropped = 0
        for t in e.tasks {
            guard let item = TaskDraftMapper.item(from: t, listName: listFallback, now: ctx.now, calendar: ctx.calendar, transcript: ctx.transcript, wordsAreThisTasks: e.tasks.count == 1, knownPeople: ctx.knownAssignees) else { dropped += 1; continue }
            let key = TaskDraftMapper.identity(item)
            if firstIndex[key] != nil { copies[key, default: 1] += 1; continue }
            firstIndex[key] = items.count
            items.append(item)
        }
        if let first = items.indices.first, !refusedLists.isEmpty {
            items[first].advisories.append("I wasn't sure of the list name " + refusedLists.map { "“\($0)”" }.joined(separator: ", ") + ", so no list was made")
        }
        if dropped > 0 { Trace.step("WARNING", "\(dropped) draft(s) had no usable title (blank, or only app-talk) and were dropped") }
        for (key, count) in copies {
            guard let n = firstIndex[key] else { continue }
            items[n].advisories.append("Combined \(count) identical items")
            Trace.step("WARNING", "\(count) generated items were identical (\"\(items[n].title)\"): combined into one; the raw answer in the trace keeps all of them")
        }
        for n in items.indices where ctx.saved.contains(where: { matches(items[n], $0, calendar: ctx.calendar) }) {
            items[n].advisories.append("You already have this saved")
        }

        if outcome == "clarify" {
            let q = ClarificationStateManager.oneQuestion(e.question ?? "")
            guard !Words.trim(q).isEmpty else {
                Trace.step("WARNING", "the model asked to clarify without a question: an invalid response, nothing is made")
                return .clarify(invalidAnswerQuestion)
            }
            return items.isEmpty ? .clarify(q) : .clarifyWithItems(q, items)
        }
        guard !items.isEmpty else {
            // Every task it named said nothing: no card and no Swift wording. The turn manager asks, with the model's own question.
            if dropped > 0 {
                Trace.step("WARNING", "every task the model named said nothing about a task: no card is made, the user is asked what to add")
                return .noContent
            }
            Trace.step("WARNING", "the model said create with no usable task: an invalid response, nothing is made")
            return .clarify(invalidAnswerQuestion)
        }
        if e.mayHaveMore, let last = items.indices.last {
            items[last].advisories.append("That is the most I read at once. If there is more, say it next")
        }
        return .items(items)
    }
}

/// Whether the words of a model-written field are the user's. Word by word, ignoring small words, plurals and endings: no meaning is
/// compared, so a paraphrase is not kept. A field that says nothing the title does not is a repeat, and is not kept either.
enum Provenance {
    private static let small: Set<String> = [
        "the", "and", "for", "with", "from", "that", "this", "your", "you", "are", "was", "has", "have", "not", "but", "can", "per",
        "any", "one", "all", "its", "our", "his", "her", "who", "how", "why", "too", "also", "some", "into", "than", "then", "them",
        "they", "their", "there", "will", "would", "could", "should", "need", "needs", "get", "got", "please"
    ]

    static func words(_ s: String) -> [String] {
        s.lowercased().split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init)
            .filter { w in w.contains(where: \.isNumber) || (w.count >= 3 && !small.contains(w)) }
    }

    private static func same(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        guard a.count >= 4, b.count >= 4 else { return false }
        let n = min(5, a.count, b.count)
        return a.prefix(n) == b.prefix(n)
    }

    /// One word is one of the words in `pool`, ignoring endings. The same test `said` uses.
    static func matches(_ word: String, among pool: [String]) -> Bool { pool.contains { same(word, $0) } }

    static func said(_ field: String, in transcript: String, notRepeating title: String) -> Bool {
        let mine = words(field)
        guard !mine.isEmpty else { return false }
        let heard = words(transcript)
        guard mine.allSatisfy({ w in heard.contains { same(w, $0) } }) else { return false }
        let inTitle = words(title)
        return !mine.allSatisfy { w in inTitle.contains { same(w, $0) } }
    }
}

// MARK: - The scope said once for several tasks

/// A person, day or time the user said once for the tasks of a dictation ("house help tasks for tomorrow") is kept as a scope on the
/// draft, and a later sentence that names none of them ("Soak, washclothes") takes it over. Swift owns every step: a value the model
/// returns is checked first, and a value that fails the check is dropped with a warning, never stored and never applied.
enum ScopeReader {
    /// What the answer says once for its tasks, checked. A value that does not pass is left out (and named in `dropped`).
    struct Reading: Equatable {
        var stated = DraftScope()
        var dropped: [String] = []
    }

    private static func letters(_ s: String) -> String { String(s.lowercased().filter { $0.isLetter || $0.isNumber }) }

    /// The phrase is in the user's words: as a run of letters ("house help" in "add house help tasks"), or, for a very short word
    /// ("me"), as a whole word.
    static func spoken(_ phrase: String, in transcript: String) -> Bool {
        let p = letters(phrase)
        guard !p.isEmpty else { return false }
        if p.count < 4 {
            return transcript.lowercased().split(whereSeparator: { !($0.isLetter || $0.isNumber) }).contains { String($0) == p }
        }
        return letters(transcript).contains(p)
    }

    static func read(_ e: ExtractionValue, stored: DraftScope?, context ctx: ValidationContext) -> Reading {
        var out = Reading()
        let transcript = ctx.transcript ?? ""

        if let raw = TaskDraftMapper.clean(e.scopeAssignee) {
            let name = Assignee.normalize(raw)
            let known = ctx.knownAssignees.contains { Assignee.normalize($0).lowercased() == name.lowercased() }
            if !name.isEmpty, name.lowercased() == stored?.assignee?.lowercased() || known || spoken(raw, in: transcript) || spoken(name, in: transcript) {
                out.stated.assignee = name
            } else {
                out.dropped.append("person \"\(raw)\" (not a name the household has, and not in the words)")
            }
        }
        if let raw = TaskDraftMapper.clean(e.scopeDay) {
            if raw.lowercased() == stored?.day?.lowercased() || reads(day: raw, ctx) { out.stated.day = raw }
            else { out.dropped.append("day \"\(raw)\" (Swift cannot read it as a day)") }
        }
        if let raw = TaskDraftMapper.clean(e.scopeTime) {
            if raw.lowercased() == stored?.time?.lowercased() || reads(time: raw, ctx) { out.stated.time = raw }
            else { out.dropped.append("time \"\(raw)\" (Swift cannot read it as a time)") }
        }
        if !out.dropped.isEmpty {
            Trace.step("WARNING", "scope the model gave but Swift did not accept: " + out.dropped.joined(separator: "; ") + ". It is not stored and not applied")
        }
        return out
    }

    /// Whether `DateResolver` and `TimeResolver` read the words, the same way a task's own day or time is read.
    private static func reads(day raw: String, _ ctx: ValidationContext) -> Bool {
        guard let probe = TaskDraftMapper.item(from: ExtractionTaskValue(title: "x", dueDate: raw), now: ctx.now, calendar: ctx.calendar) else { return false }
        return probe.unparsed["date"] == nil && (probe.due != nil || probe.softDue != nil || probe.slot != nil)
    }

    private static func reads(time raw: String, _ ctx: ValidationContext) -> Bool {
        guard let probe = TaskDraftMapper.item(from: ExtractionTaskValue(title: "x", dueTime: raw), now: ctx.now, calendar: ctx.calendar) else { return false }
        return probe.unparsed["time"] == nil && (probe.timeMinutes != nil || probe.slot != nil)
    }

    /// The scope the new tasks take over, and the scope the draft keeps afterwards.
    ///  - The answer states a scope: the new tasks take it, and the draft keeps it (it replaces the fields it states).
    ///  - The answer says it leaves the scope: the tasks take only what they or the answer state; the draft keeps what it had.
    ///  - Otherwise the draft's scope fills what the answer does not state.
    static func resolve(stated: DraftScope, leaves: Bool, stored: DraftScope?) -> (apply: DraftScope?, keep: DraftScope?) {
        let held = stored ?? DraftScope()
        if leaves { return (stated.isEmpty ? nil : stated, stored) }
        let combined = held.merged(with: stated)
        return (combined.isEmpty ? nil : combined, combined.isEmpty ? nil : combined)
    }

    /// Each task that says nothing for a field takes the scope's value. A task's own value always wins.
    static func apply(_ scope: DraftScope?, to e: ExtractionValue) -> (value: ExtractionValue, filled: Int) {
        guard let scope, !scope.isEmpty else { return (e, 0) }
        var out = e
        var filled = 0
        for n in out.tasks.indices {
            var changed = false
            if TaskDraftMapper.clean(out.tasks[n].assignee) == nil, let a = scope.assignee { out.tasks[n].assignee = a; out.tasks[n].fromScope.insert("assignee"); changed = true }
            if TaskDraftMapper.clean(out.tasks[n].dueDate) == nil, let d = scope.day { out.tasks[n].dueDate = d; out.tasks[n].fromScope.insert("day"); changed = true }
            if TaskDraftMapper.clean(out.tasks[n].dueTime) == nil, let t = scope.time { out.tasks[n].dueTime = t; out.tasks[n].fromScope.insert("time"); changed = true }
            if changed { filled += 1 }
        }
        return (out, filled)
    }
}

// MARK: - Words that no task covers

/// The check that nothing said was lost: the content words of the new words that no task, person, day, list or scope accounts for.
/// It is pure and has no list of phrases: a word is covered when something the answer returned says it (ignoring endings), when two
/// neighbouring words together say it ("house help" and "Househelp"), or when it is only talk (a small word, a command to the app,
/// a day or a time of day).
enum Coverage {
    static let talk: Set<String> = [
        "okay", "ok", "yeah", "yes", "thanks", "thank", "right", "well", "also", "then", "next", "after", "before", "hello", "hey", "kitty",
        "later", "now", "done", "that", "these", "those", "what", "else", "anything", "everything", "plus", "actually", "maybe", "sure"]

    static func uncovered(said: String, tasks: [ExtractionTaskValue], answer: ExtractionValue? = nil, scope: DraftScope?, known: [String],
                          now: Date = Date(), calendar: Calendar = .current) -> [String] {
        var fields: [String] = known
        for t in tasks {
            fields += [t.title, t.schedule, t.assignee, t.dueDate, t.dueTime, t.purpose, t.instructions, t.listName].compactMap { $0 }
        }
        if let a = answer { fields += [a.listName, a.scopeAssignee, a.scopeDay, a.scopeTime].compactMap { $0 } }
        if let scope { fields += [scope.assignee, scope.day, scope.time].compactMap { $0 } }
        let pool = Provenance.words(fields.joined(separator: " "))
        // "Househelp" is said as two words: its letters, joined, count as one word of the pool too.
        let joinedPool = pool + fields.map { String($0.lowercased().filter { $0.isLetter || $0.isNumber }) }.filter { $0.count >= 4 }

        let tokens = said.lowercased().split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init)
        // The day, time and timeframe phrases are read by `WhenReader`: their words are covered ("six", "thirty", "at ten").
        let whenWords = WhenReader.coveredWords(in: said, now: now, calendar: calendar)
        var out: [String] = []
        for (i, w) in tokens.enumerated() {
            guard !Provenance.words(w).isEmpty, !w.contains(where: \.isNumber) else { continue }
            if talk.contains(w) || TaskMeaning.appTalk.contains(w) || TaskMeaning.bareVerbs.contains(w) { continue }
            if Provenance.matches(w, among: pool) || whenWords.contains(w) { continue }
            if i + 1 < tokens.count, Provenance.matches(w + tokens[i + 1], among: joinedPool) { continue }
            if i > 0, Provenance.matches(tokens[i - 1] + w, among: joinedPool) { continue }
            if DateResolver.read(w, now: now, calendar: calendar) != .invalid || TimeResolver.read(w) != .invalid { continue }
            if !out.contains(w) { out.append(w) }
        }
        return out
    }
}


// MARK: - A repeat the model left out

/// Finds how often a task repeats in the words the user said for it ("every morning", "every Monday and Thursday", "every three months",
/// "daily"), only where the repeat parser reads them. It reads nothing the words do not say.
enum RepeatReader {
    private static let cues: Set<String> = [
        "every", "each", "daily", "everyday", "weekly", "monthly", "yearly", "fortnightly", "alternate", "weekdays", "weekends"]
    /// Words that can continue a repeat once it has started: days, periods, numbers, times.
    private static let continues: Set<String> = [
        "and", "or", "other", "day", "days", "week", "weeks", "month", "months", "year", "years", "morning", "afternoon", "evening", "night",
        "at", "am", "pm", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday", "mondays", "tuesdays", "wednesdays",
        "thursdays", "fridays", "saturdays", "sundays", "weekday", "weekend", "one", "two", "three", "four", "five", "six", "seven", "eight",
        "nine", "ten", "twelve", "first", "second", "third", "last", "of", "the", "on", "weekdays", "weekends", "alternate", "days"]
    private static let glue: Set<String> = ["and", "or", "of", "the", "on", "at"]

    private static func key(_ w: String) -> String { w.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ",.;:!?\"()")) }

    static func phrase(in text: String) -> String? {
        let words = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        for (i, w) in words.enumerated() where cues.contains(key(w)) {
            var end = i + 1
            while end < words.count, end - i < 9, continues.contains(key(words[end])) || key(words[end]).first?.isNumber == true { end += 1 }
            var n = end - i
            while n > 0 {
                let said = words[i..<(i + n)].map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ",.;:!?")) }.joined(separator: " ")
                let alone = n == 1 && ["every", "each", "alternate"].contains(key(words[i]))        // "every" on its own is not a repeat
                if !alone, !glue.contains(key(words[i + n - 1])), case .spec = RecurrenceParser.read(said) { return said }
                n -= 1
            }
        }
        return nil
    }

    /// The title without the repeat phrase, when the model left it there; nil when it is not in the title or nothing would be left.
    static func removing(_ phrase: String, from title: String) -> String? {
        guard let r = title.range(of: phrase, options: .caseInsensitive) else { return nil }
        var cut = title
        cut.removeSubrange(r)
        cut = cut.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: " ,;-"))
        return cut.isEmpty ? nil : cut
    }
}


// MARK: - Notes that hold no task

/// Whether a note says anything to DO. A note is often a memory ("she said bye bye papa today") or something to remember ("the wifi
/// password is on the router"). The model turns those into tasks anyway ("Find the wifi password"), so Swift checks first: a note of
/// more than a few words in which no sentence says something to do, and that is not a list, is only a note. It is kept, and nothing is
/// made from it. Short words are never judged here: "milk and bread" is a command, and Kitty reads it.
///
/// A sentence says something to do when it starts with a verb ("send the quote"), or holds an intent ("I need to", "remind me",
/// "don't forget", "should", "must", "will"). The verb is found by the system's language tagger and a short list of common task verbs.
/// Mistakes here only let a note through to the model (the old behaviour); they never drop a note that has a clear task.
enum NoteIntent {
    private static let cues = [
        "need to", "needs to", "have to", "has to", "want to", "wanna", "would like to", "should", "must", "will ", "i'll", "going to",
        "gonna", "remind me", "don't forget", "dont forget", "do not forget", "let's", "lets ", "plan to", "planning to", "ask ", "tell ",
        "make sure", "todo", "to do", "to-do", "mujhe", "karna hai", "please "]
    private static let verbs: Set<String> = [
        "call", "buy", "pay", "send", "book", "pick", "get", "make", "clean", "wash", "order", "take", "bring", "check", "fix", "renew",
        "submit", "email", "remind", "ask", "tell", "cancel", "schedule", "pack", "cook", "drop", "return", "print", "repair", "change",
        "find", "collect", "arrange", "plan", "prepare", "finish", "complete", "write", "read", "visit", "meet", "set", "fill", "refill",
        "water", "iron", "sweep", "mop", "dust", "install", "replace", "organise", "organize", "sort", "donate", "wrap", "register",
        "apply", "update", "confirm", "follow", "deposit", "withdraw", "recharge", "charge", "feed", "walk", "give", "put", "add", "remove",
        "create", "build", "open", "throw", "reply", "message", "text", "share", "upload", "download", "attend", "join", "start", "stop", "turn", "lock", "unlock"]

    private static func sentences(_ text: String) -> [String] {
        text.split(whereSeparator: { ".?!;\n".contains($0) }).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private static func wordCount(_ s: String) -> Int { s.split(whereSeparator: { $0.isWhitespace }).count }

    static func isTaskVerb(_ word: String) -> Bool { verbs.contains(word) }

    static func startsWithVerb(_ sentence: String) -> Bool {
        guard let first = sentence.split(whereSeparator: { !($0.isLetter || $0 == "'") }).first else { return false }
        if verbs.contains(first.lowercased()) { return true }
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = sentence
        var verb = false
        tagger.enumerateTags(in: sentence.startIndex..<sentence.endIndex, unit: .word, scheme: .lexicalClass,
                             options: [.omitWhitespace, .omitPunctuation]) { tag, _ in
            verb = (tag == .verb)
            return false                                                  // only the first word
        }
        return verb
    }

    private static let timeWords: Set<String> = [
        "today", "tomorrow", "tonight", "morning", "mornings", "afternoon", "evening", "night", "week", "weekend", "month", "daily",
        "every", "each", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday", "before", "by", "until", "till",
        "weekly", "monthly", "yearly", "noon", "midnight"]

    /// A day, a time or a repeat word: the words ask for something at a time, so the model reads them.
    static func hasTimeWord(_ text: String, forNote: Bool = false) -> Bool {
        // A memory is full of "today" and "this morning"; only a day ahead or a repeat means a task for a plain note.
        let loose: Set<String> = ["today", "morning", "mornings", "afternoon", "evening", "night", "by", "each", "week", "weekend", "month"]
        let timeWords = forNote ? Self.timeWords.subtracting(loose) : Self.timeWords
        let words = text.lowercased().split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init)
        return words.contains(where: { timeWords.contains($0) }) || words.contains(where: { $0.first?.isNumber == true && $0.count <= 2 && words.contains("at") })
    }

    /// At least one sentence says something to do.
    static func hasAction(_ text: String) -> Bool {
        let low = " " + text.lowercased() + " "
        if cues.contains(where: { low.contains($0) }) { return true }
        return sentences(text).contains { startsWithVerb($0) }
    }

    /// True when the words are only a note: long enough to judge, not a list, and nothing in them to do.
    static func isPlainNote(_ text: String) -> Bool {
        guard wordCount(text) >= 8, sentences(text).count >= 2, !hasTimeWord(text, forNote: true) else { return false }      // one sentence is a command, not a note
        if text.contains(":") || text.lowercased().split(whereSeparator: { !$0.isLetter }).contains("list") { return false }      // "Pharmacy list: …"
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if lines.contains(where: { NoteLists.itemText($0) != nil }) { return false }          // marked lines are items
        if lines.count >= 3, lines.allSatisfy({ wordCount($0) <= 4 }) { return false }          // short lines one under another are a list
        return !hasAction(text)
    }
}

// MARK: - List notes

/// A note that is only a list, read by Swift with no model call: the model collapses "- milk / - bread / - eggs" into one task and puts a
/// heading into every title. Two shapes count, and only these:
///  - an optional heading line, then lines that each start with a dash, a bullet or a number, and nothing else;
///  - one line "Heading: a, b, c" with a short heading and two or more short items.
/// Anything else is not a list note and goes to the model as before. The heading names a list only if the words say so (the list-name
/// check decides), and never becomes a task.
enum NoteLists {
    struct Reading: Equatable {
        var heading: String?
        var items: [String]
    }

    private static let marker = try? NSRegularExpression(pattern: "^\\s*(?:[-\u{2022}*\u{2013}\u{2014}]|\\d{1,2}[.)])\\s+(.+)$")

    /// The text of a list line, without its dash, bullet or number; nil if the line has none of them.
    static func itemText(_ line: String) -> String? {
        guard let marker else { return nil }
        let ns = line as NSString
        guard let m = marker.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)), m.numberOfRanges > 1 else { return nil }
        return ns.substring(with: m.range(at: 1)).trimmingCharacters(in: CharacterSet(charactersIn: " ,;.").union(.whitespacesAndNewlines))
    }

    private static func words(_ s: String) -> Int { s.split(whereSeparator: { $0.isWhitespace }).count }

    private static let listWords: Set<String> = ["list", "checklist", "order", "cart", "basket"]

    private static func hasListWord(_ line: String) -> Bool {
        line.lowercased().split(whereSeparator: { !$0.isLetter }).contains { listWords.contains(String($0)) }
    }

    /// A list heading on its own ("shopping list for my kid"): the user will add the items next, so there is nothing to make yet. A line
    /// that starts with a verb ("create a shopping list") is a request and goes to Kitty as before.
    static func isBareHeading(_ text: String) -> Bool {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard lines.count == 1, let line = lines.first, (2...7).contains(words(line)), hasListWord(line),
              !line.contains(where: { ".?!:".contains($0) }), !NoteIntent.hasTimeWord(line) else { return false }
        let all = line.lowercased().split(whereSeparator: { !($0.isLetter || $0 == "'") }).map(String.init)
        guard let at = all.firstIndex(where: { listWords.contains($0) }), all.count - at - 1 <= 3,         // "shopping list for my kid", not "a long list of things to do"
              !all.contains("do"), let first = all.first else { return false }
        return !NoteIntent.isTaskVerb(first)
    }

    static func read(_ text: String) -> Reading? {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }
        // A list with days or repeats in its items goes to the model. A heading may say "for the week".
        let body = lines.enumerated().filter { $0.offset > 0 || lines.count == 1 || itemText($0.element) != nil }.map(\.element)
        guard !NoteIntent.hasTimeWord(body.joined(separator: " ")) else { return nil }

        // Marked lines under an optional heading.
        let marked = lines.map { itemText($0) }
        if marked.compactMap({ $0 }).count >= 2 {
            var heading: String?
            var items: [String] = []
            for (i, line) in lines.enumerated() {
                if let item = marked[i] { items.append(item) }
                else if i == 0, words(line) <= 10 { heading = line.trimmingCharacters(in: CharacterSet(charactersIn: ": ")) }
                else { return nil }                                            // something that is not an item: not a pure list
            }
            guard items.allSatisfy({ !$0.isEmpty && words($0) <= 8 }) else { return nil }
            return Reading(heading: heading, items: items)
        }

        // A heading and then one short item on each line, as typed one message at a time: "groceries for the week / milk / bread / eggs".
        // A first line that starts with a verb is a task like the rest, not a heading.
        // A first line with a list word in it ("shopping list for my kid") is a heading even with one item under it.
        if lines.count >= 2, lines.allSatisfy({ words($0) <= 5 || $0 == lines[0] && words($0) <= 7 }),
           lines.allSatisfy({ !$0.contains(where: { ".?!".contains($0) }) }) {
            let cue = hasListWord(lines[0])
            let first = lines[0].split(whereSeparator: { !($0.isLetter || $0 == "'") }).first.map { $0.lowercased() } ?? ""
            let verbFirst = NoteIntent.startsWithVerb(lines[0]) && !first.hasSuffix("ing")      // "shopping list" is a noun phrase, "buy milk" is a task
            let hasHeading = !lines[0].contains(":") && (cue || !verbFirst) && (cue || lines.count >= 3)
            let items = (hasHeading ? Array(lines.dropFirst()) : lines).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " ,;")) }
            if (items.count >= 2 && (hasHeading || lines.count >= 3)) || (hasHeading && cue && items.count >= 1) { return Reading(heading: hasHeading ? lines[0] : nil, items: items) }
        }

        // "Blinkit order: milk, curd, paneer, coriander"
        guard lines.count == 1, let colon = lines[0].firstIndex(of: ":") else { return nil }
        let head = String(lines[0][..<colon]).trimmingCharacters(in: .whitespaces)
        let tail = String(lines[0][lines[0].index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        guard (1...4).contains(words(head)), !head.lowercased().split(separator: " ").contains("list"), !NoteIntent.hasAction(tail), !tail.isEmpty, !tail.contains(where: { ".?!".contains($0) }) else { return nil }
        var parts = tail.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        if let last = parts.last, let r = last.range(of: " and ") {                 // "bread and eggs": the last two are separate
            parts[parts.count - 1] = String(last[..<r.lowerBound])
            parts.append(String(last[r.upperBound...]))
        }
        parts = parts.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " ,;.")) }.filter { !$0.isEmpty }
        guard (2...12).contains(parts.count), parts.allSatisfy({ words($0) <= 5 }) else { return nil }
        return Reading(heading: head, items: parts)
    }
}
