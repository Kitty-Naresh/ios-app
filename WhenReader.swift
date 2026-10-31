import Foundation

// MARK: - When, read in Swift from the user's words
//
// The model often leaves a day, a time or a timeframe inside the title, the purpose or the repeat field ("pick up Aarav at six thirty
// today evening", `schedule: "four am on Friday"`, `purpose: "before Diwali"`, `dueDate: "kal"`). `WhenReader` finds those phrases with
// small tables and fills the day, the time, the part of the day and the timeframe of a draft, only where the draft has none, and takes
// the phrase out of the field it was misplaced in. It is a pure function of the words, the clock and the calendar: no model, no UI, and
// nothing is saved. A phrase it cannot read stays where it was, as said, and the card flags it as before.
//
// What it reads (every table is below, next to the code that uses it):
//   Days        today, tonight, tomorrow, day after tomorrow, weekdays (next / this), Hinglish aaj, kal, parso. The day itself is worked out
//               by `DateResolver`; this file only finds the words and maps the Hinglish ones to English.
//   Day-parts   morning, afternoon, evening, night; subah, dopahar, shaam, raat. Only with a cue (see `scan`).
//   Clocks      6:30, 6.30pm, 18:30, 6 pm; six thirty, six fifteen, half past six, quarter to five, at ten, four am, eleven thirty pm.
//               A bare number is a time only after at / by / around, with am/pm, with o'clock, with a colon, or when it is the whole
//               time field. "five apples", "two kg", "twelve eggs" are quantities, not times.
//   Timeframes  this / next week, month, weekend; month end; end of the month; agle hafte, is hafte; before a weekday, a festival or a
//               clock time. Kept as said in `softDue`, never turned into a day.
// Never read: a text with a repeat cue (every, daily, weekly, alternate, weekdays, a plural weekday, twice, per...). A repeat is not a when.

struct WhenReading: Equatable {
    var day: Date?              // resolved with `now` and `calendar`
    var timeMinutes: Int?       // 0...1439
    var slot: DaySlot?          // morning, afternoon, evening, night
    var soft: String?           // a timeframe as said ("this week", "before Diwali")
    var periodMissing: String?  // a clock with no am/pm and no part of the day ("at ten"): no time is read, the phrase is kept
    var spans: [String] = []    // the exact phrases matched, to cut out of fields and to count as covered
    /// The words that said each part ("day", "time", "slot", "softDue"): the evidence for it.
    var phrases: [String: String] = [:]
}

enum WhenReader {

    // MARK: Tables

    /// Day words and the English the day reader knows them as. Hinglish: aaj (today), kal (tomorrow), parso (day after tomorrow).
    private static let dayWords: [String: String] = [
        "today": "today", "tonight": "today", "tomorrow": "tomorrow", "tmrw": "tomorrow", "tmr": "tomorrow", "tomorow": "tomorrow",
        "aaj": "today", "kal": "tomorrow", "parso": "day after tomorrow"]
    /// Hinglish words for a Hindi day word that can also mean the past ("kal" is tomorrow or yesterday).
    private static let ambiguousDays: Set<String> = ["kal", "parso"]
    /// With one of these in the words, "kal" is yesterday, so no day is read.
    private static let pastMarkers: Set<String> = [
        "tha", "thi", "thay", "gaya", "gayi", "gaye", "kiya", "kiyi", "kiye", "hua", "hui", "huye", "aaya", "aayi", "mila", "mili", "diya", "liya"]
    private static let hinglishParts: [String: DaySlot] = ["subah": .morning, "dopahar": .afternoon, "shaam": .evening, "raat": .night]
    /// Festival names that "before ..." can point at. No dates: the phrase stays as said.
    private static let festivals: Set<String> = [
        "diwali", "deepavali", "holi", "rakhi", "eid", "dussehra", "dasara", "navratri", "christmas", "pongal", "onam", "baisakhi", "ugadi",
        "janmashtami", "chhath", "lohri", "sankranti", "ramadan", "easter", "thanksgiving"]
    private static let hourWords: [String: Int] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12]
    private static let onesWords: [String: Int] = ["one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9]
    private static let tensWords: [String: Int] = ["twenty": 20, "thirty": 30, "forty": 40, "fifty": 50]
    private static let smallMinuteWords: [String: Int] = ["ten": 10, "fifteen": 15]
    /// Words before a number that make it a clock time.
    private static let clockCues: Set<String> = ["at", "by", "around"]
    /// A number followed by one of these is a quantity ("at five hundred rupees", "by two weeks"), not a time.
    private static let units: Set<String> = [
        "kg", "kgs", "kilo", "kilos", "g", "gm", "gms", "gram", "grams", "litre", "litres", "liter", "liters", "l", "ml", "rupees", "rupee", "rs",
        "dollars", "apples", "eggs", "minutes", "minute", "mins", "min", "hours", "hour", "hrs", "days", "day", "weeks", "week", "months", "month",
        "years", "people", "persons", "pieces", "piece", "pcs", "items", "percent", "%", "hundred", "thousand", "bottles", "packets", "packs",
        "boxes", "bags", "tablets", "strips", "cups", "glasses", "slices", "plates"]
    /// A word like these anywhere in a text means it says how often, not when. The text is left alone.
    private static let repeatWords: Set<String> = [
        "every", "each", "daily", "everyday", "weekly", "monthly", "yearly", "fortnightly", "biweekly", "alternate", "alternating", "other",
        "weekday", "weekdays", "weekend", "weekends", "twice", "thrice", "times", "per"]
    /// Words that do not stop a field from being only a when-phrase.
    private static let fieldGlue: Set<String> = ["on", "at", "by", "the", "of", "in", "for", "around", "sometime", "a", "an", "this", "coming"]
    private static let prepositions: Set<String> = ["on", "at", "by", "for", "around", "in"]
    /// What can be left after a when-phrase is cut out of a purpose or an instruction that says nothing more: a pronoun and a verb that
    /// only says the deadline ("it is expiring"), or a filler ("things").
    private static let leftoverGlue: Set<String> = [
        "it", "its", "it's", "is", "are", "was", "were", "will", "be", "been", "a", "an", "the", "that", "this", "which", "and", "or", "to", "by",
        "on", "at", "in", "for", "of", "due", "only", "just", "needs", "need", "needed", "expiring", "expires", "expire", "ending", "ends",
        "starts", "deadline", "things", "thing", "stuff", "please", "also", "so", "as", "because", "since", "but", "then", "till", "until"]
    private static let leadingDangling: Set<String> = ["and", "or", "then", "also", "but", "so"]
    private static let trailingDangling: Set<String> = [
        "at", "on", "by", "for", "in", "the", "around", "and", "or", "this", "next", "of", "to", "before", "till", "until", "a", "an"]

    // MARK: Words

    private static func normalize(_ w: String) -> String {
        var s = w.lowercased().replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "a.m.", with: "am").replacingOccurrences(of: "p.m.", with: "pm")
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: ",;:!?\"()[]“”"))
        while s.hasSuffix(".") { s.removeLast() }
        return s
    }

    private static func isFullWeekday(_ w: String) -> Bool {
        w.count >= 6 && !w.hasSuffix("s") && DateResolver.weekday(w) != nil
    }

    private static func isPluralWeekday(_ w: String) -> Bool {
        w.count >= 7 && w.hasSuffix("s") && DateResolver.weekday(w) != nil
    }

    private static func daySlot(_ w: String) -> DaySlot? {
        if w != "tonight", let s = TimeResolver.slotWords[w] { return s }
        return hinglishParts[w]
    }

    private static func hasPastMarker(_ text: String) -> Bool {
        text.split(whereSeparator: { $0.isWhitespace }).contains { pastMarkers.contains(normalize(String($0))) }
    }

    // MARK: Clock times

    private struct ClockParse {
        var end: Int                    // the index after the last word of the time
        var hour: Int
        var minute: Int
        var pm: Bool?                   // said am or pm
        var fixed24: Bool               // noon, midnight, 18:30, 0:15: nothing to guess
        var quarterTo = false           // "quarter to five": the minutes are taken off the hour
    }

    /// "6", "6:30", "6.30", "6pm", "18:30" with what they say about the period. Nil when it is not a clock-shaped number.
    private static func digitTime(_ w: String) -> (hour: Int, minute: Int, pm: Bool?, colon: Bool, dot: Bool)? {
        var s = w
        var pm: Bool?
        if s.hasSuffix("am") { pm = false; s.removeLast(2) } else if s.hasSuffix("pm") { pm = true; s.removeLast(2) }
        guard !s.isEmpty else { return nil }
        let sep: Character? = s.contains(":") ? ":" : (s.contains(".") ? "." : nil)
        let parts = sep.map { c in s.split(separator: c, omittingEmptySubsequences: false).map(String.init) } ?? [s]
        guard parts.count <= 2, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }), parts[0].count <= 2, let h = Int(parts[0]), h <= 23 else { return nil }
        var m = 0
        if parts.count == 2 {
            guard parts[1].count == 2, let mm = Int(parts[1]), mm < 60 else { return nil }
            m = mm
        }
        if pm != nil, !(1...12).contains(h) { return nil }
        return (h, m, pm, sep == ":", sep == ".")
    }

    /// A clock time starting at word `i`, or nil. `cued` says a word like "at" or "before" stands right before it; `whole` says the whole
    /// text is a time field, so a bare number is a time.
    private static func clock(_ t: [String], at i: Int, cued: Bool, whole: Bool) -> ClockParse? {
        let n = t.count
        guard i < n else { return nil }
        func word(_ k: Int) -> String { k >= 0 && k < n ? t[k] : "" }
        let w = t[i]
        if w == "noon" || w == "midday" { return ClockParse(end: i + 1, hour: 12, minute: 0, pm: nil, fixed24: true) }
        if w == "midnight" { return ClockParse(end: i + 1, hour: 0, minute: 0, pm: nil, fixed24: true) }

        var parse: ClockParse
        var selfCued = false, minuteForm = false, colon = false
        if w == "half", word(i + 1) == "past", let h = hourWords[word(i + 2)] {
            parse = ClockParse(end: i + 3, hour: h, minute: 30, pm: nil, fixed24: false)
            selfCued = true
        } else if w == "quarter", ["past", "to"].contains(word(i + 1)), let h = hourWords[word(i + 2)] {
            parse = ClockParse(end: i + 3, hour: h, minute: word(i + 1) == "past" ? 15 : 0, pm: nil, fixed24: false, quarterTo: word(i + 1) == "to")
            selfCued = true
        } else if let d = digitTime(w) {
            if d.pm == nil, !d.colon, !cued, !whole { return nil }      // a bare number or a decimal needs a cue
            colon = d.colon
            parse = ClockParse(end: i + 1, hour: d.hour, minute: d.minute, pm: d.pm, fixed24: d.pm == nil && (d.hour == 0 || d.hour >= 13))
            minuteForm = true
        } else if let h = hourWords[w] {
            var minute = 0, end = i + 1
            if let tens = tensWords[word(i + 1)] {
                minute = tens; end = i + 2
                if let ones = onesWords[word(i + 2)] { minute += ones; end = i + 3 }
                minuteForm = true
            } else if let small = smallMinuteWords[word(i + 1)] {
                minute = small; end = i + 2
                minuteForm = true
            } else if ["oh", "o"].contains(word(i + 1)), let ones = onesWords[word(i + 2)] {
                minute = ones; end = i + 3
                minuteForm = true
            }
            parse = ClockParse(end: end, hour: h, minute: minute, pm: nil, fixed24: false)
        } else {
            return nil
        }

        // am / pm / o'clock after the number.
        var oclock = false
        if parse.pm == nil, parse.end < n {
            if t[parse.end] == "am" || t[parse.end] == "pm" { parse.pm = t[parse.end] == "pm"; parse.end += 1 }
            else if t[parse.end] == "o'clock" || t[parse.end] == "oclock" { oclock = true; parse.end += 1 }
        }
        if parse.pm != nil, !(1...12).contains(parse.hour) { return nil }
        if parse.pm != nil { parse.fixed24 = false }

        // "one by one" is not 1 pm.
        if cued, i >= 2, t[i - 1] == "by", t[i - 2] == w { return nil }

        // A cue is needed for words: at / by / around, a period, o'clock, a colon, a self-cued phrase, the whole field, or a time with
        // minutes in front of a part of the day ("six thirty in the evening").
        var allowed = cued || parse.pm != nil || colon || oclock || selfCued || whole
        if !allowed, minuteForm {
            let e = parse.end
            allowed = daySlot(word(e)) != nil || (word(e) == "in" && word(e + 1) == "the" && daySlot(word(e + 2)) != nil)
        }
        guard allowed else { return nil }
        // A quantity: "at five hundred rupees".
        if parse.pm == nil, !oclock, !colon, !selfCued, units.contains(word(parse.end)) { return nil }
        return parse
    }

    /// The minutes after midnight. Said am/pm wins, then a part of the day, then a 24-hour clock ("18:30", "noon").
    /// Nil when none of those is said ("at ten", "6:30"): the period is not guessed, the time stays empty and the phrase is kept.
    private static func resolve(_ c: ClockParse, slot: DaySlot?) -> Int? {
        var h = c.hour
        if c.fixed24 {
            // nothing to guess
        } else if let pm = c.pm {
            h = h % 12 + (pm ? 12 : 0)
        } else if let s = slot, s != .anytime {
            switch s {
            case .morning: h = h % 12
            case .afternoon, .evening: h = h % 12 + 12
            case .night: h = h == 12 ? 0 : (h >= 6 ? h + 12 : h)
            case .anytime: break
            }
        } else {
            return nil
        }
        var minutes = h * 60 + c.minute - (c.quarterTo ? 15 : 0)
        minutes = (minutes + 1440) % 1440
        return minutes
    }

    private static func format(_ minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        let h12 = h % 12 == 0 ? 12 : h % 12
        return String(format: "%d:%02d %@", h12, m, h < 12 ? "AM" : "PM")
    }

    // MARK: Scanning

    private struct Match {
        enum Kind {
            case day(Date)
            case clock(ClockParse)
            case slot(DaySlot)
            case soft(String)
        }
        var kind: Kind
        var core: Range<Int>        // the words themselves
        var range: Range<Int>       // the words with the preposition before them ("at six thirty", "on Friday")
        var kal = false
        var order: Int {
            switch kind { case .day: return 0; case .clock: return 1; case .soft: return 2; case .slot: return 3 }
        }
    }

    private struct Scan {
        var orig: [String] = []
        var words: [String] = []
        var matches: [Match] = []
        var repeatCue = false
        func phrase(_ r: Range<Int>) -> String {
            orig[r].joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: ",.;:!?"))
        }
    }

    /// Every when-phrase in `text`, left to right. A text with a repeat cue has none. `whole` says the text is a day, time or repeat field
    /// that is only a when-phrase; `past` says the words carry a past marker, so "kal" is not read.
    private static func scan(_ text: String, now: Date, calendar: Calendar, whole: Bool, past: Bool) -> Scan {
        var out = Scan()
        out.orig = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let t = out.orig.map(normalize)
        out.words = t
        let n = t.count
        guard n > 0 else { return out }
        if t.contains(where: { repeatWords.contains($0) || isPluralWeekday($0) }) { out.repeatCue = true; return out }
        let pastText = past || t.contains(where: { pastMarkers.contains($0) })
        var taken = Set<Int>()

        func word(_ k: Int) -> String { k >= 0 && k < n ? t[k] : "" }
        /// The words, with "on", "at", "by", "for", "in the" before them.
        func extended(_ start: Int, soft: Bool = false) -> Int {
            var s = start
            if soft, s >= 1, t[s - 1] == "sometime", !taken.contains(s - 1) { s -= 1 }
            if s >= 1, !taken.contains(s - 1) {
                if t[s - 1] == "the", s >= 2, prepositions.contains(t[s - 2]), !taken.contains(s - 2) { s -= 2 }
                else if prepositions.contains(t[s - 1]) { s -= 1 }
            }
            return s
        }
        func add(_ kind: Match.Kind, core: Range<Int>, soft: Bool = false, kal: Bool = false) {
            let start = extended(core.lowerBound, soft: soft)
            out.matches.append(Match(kind: kind, core: core, range: start..<core.upperBound, kal: kal))
            taken.formUnion(start..<core.upperBound)
        }

        var i = 0
        while i < n {
            if taken.contains(i) { i += 1; continue }
            let w = t[i]

            // "before Friday", "before Diwali", "before eleven": a timeframe, never a day or a time.
            if w == "before" {
                if isFullWeekday(word(i + 1)) || festivals.contains(word(i + 1)) {
                    add(.soft(out.phrase(i..<i + 2)), core: i..<i + 2, soft: true); i += 2; continue
                }
                if let c = clock(t, at: i + 1, cued: true, whole: false) {
                    add(.soft(out.phrase(i..<c.end)), core: i..<c.end, soft: true); i = c.end; continue
                }
                i += 1; continue
            }

            // "this week", "next month", "month end", "end of the month", "agle hafte".
            var softLength: Int?
            if ["this", "next", "coming"].contains(w), ["week", "weekend", "month"].contains(word(i + 1)) { softLength = 2 }
            else if w == "month", word(i + 1) == "end" { softLength = 2 }
            else if w == "end", word(i + 1) == "of" {
                if word(i + 2) == "month" { softLength = 3 } else if ["the", "this"].contains(word(i + 2)), word(i + 3) == "month" { softLength = 4 }
            } else if ["agle", "is"].contains(w), word(i + 1) == "hafte" { softLength = 2 }
            if let len = softLength {
                add(.soft(out.phrase(i..<i + len)), core: i..<i + len, soft: true); i += len; continue
            }

            // Days. "kal" and "parso" can also mean the past: with a past marker nothing is read.
            if let english = dayWords[w] {
                if ambiguousDays.contains(w), pastText { i += 1; continue }
                if case .day(let d) = DateResolver.read(english, now: now, calendar: calendar) {
                    add(.day(d), core: i..<i + 1, kal: w == "kal")
                    if w == "tonight" { out.matches.append(Match(kind: .slot(.night), core: i..<i + 1, range: i..<i + 1)) }
                }
                i += 1; continue
            }
            if w == "day", word(i + 1) == "after", dayWords[word(i + 2)] == "tomorrow",
               case .day(let d) = DateResolver.read("day after tomorrow", now: now, calendar: calendar) {
                add(.day(d), core: i..<i + 3); i += 3; continue
            }
            if isFullWeekday(w) {
                var start = i
                var name = w
                if i >= 1, !taken.contains(i - 1), ["next", "this"].contains(t[i - 1]) { start = i - 1; name = t[i - 1] + " " + w }
                else if i >= 1, !taken.contains(i - 1), t[i - 1] == "coming" { start = i - 1 }
                if case .day(let d) = DateResolver.read(name, now: now, calendar: calendar) { add(.day(d), core: start..<i + 1) }
                i += 1; continue
            }

            // Clock times.
            if let c = clock(t, at: i, cued: clockCues.contains(word(i - 1)), whole: whole && i == 0) {
                add(.clock(c), core: i..<c.end); i = c.end; continue
            }
            i += 1
        }

        // Parts of the day, only with a cue: "this evening", "in the morning", "at night", next to a day or a time ("tomorrow morning",
        // "six thirty evening"), or as the whole field. "morning walk" and "night cream" are not a when.
        for j in 0..<n where !taken.contains(j) {
            guard let s = daySlot(t[j]), word(j - 1) != "good" else { continue }
            let cue = word(j - 1) == "this" || (word(j - 1) == "the" && word(j - 2) == "in") || (word(j - 1) == "at" && t[j] == "night")
            let adjacent = taken.contains(j - 1) || taken.contains(j + 1)
            guard cue || adjacent || whole else { continue }
            let start = word(j - 1) == "this" && !taken.contains(j - 1) ? j - 1 : j
            add(.slot(s), core: start..<j + 1)
        }
        return out
    }

    // MARK: The words of a text

    private static func firstSlot(_ s: Scan) -> DaySlot? {
        for m in s.matches { if case .slot(let x) = m.kind { return x } }
        return nil
    }

    /// What the words say about when, for the first of each kind. `clockCue` says the text is a time field, so a bare number is a time.
    static func read(_ words: String, now: Date, calendar: Calendar, clockCue: Bool = false) -> WhenReading {
        let s = scan(words, now: now, calendar: calendar, whole: clockCue, past: false)
        var r = WhenReading()
        let hint = firstSlot(s)
        for m in s.matches.sorted(by: { $0.order < $1.order }) {
            switch m.kind {
            case .day(let d): if r.day == nil { r.day = d; r.phrases["day"] = s.phrase(m.range) }
            case .clock(let c):
                if r.timeMinutes == nil, r.periodMissing == nil {
                    if let minutes = resolve(c, slot: hint) { r.timeMinutes = minutes; r.phrases["time"] = s.phrase(m.range) }
                    else { r.periodMissing = s.phrase(m.range) }
                }
            case .slot(let x): if r.slot == nil { r.slot = x; r.phrases["slot"] = s.phrase(m.range) }
            case .soft(let x): if r.soft == nil { r.soft = x; r.phrases["softDue"] = s.phrase(m.range) }
            }
        }
        r.spans = s.matches.map { s.phrase($0.range) }
        return r
    }

    /// The words inside the when-phrases of `said`: they are covered, so "six" and "thirty" are not reported as heard but not used.
    static func coveredWords(in said: String, now: Date, calendar: Calendar) -> Set<String> {
        Set(read(said, now: now, calendar: calendar).spans.flatMap { span in
            span.lowercased().split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init)
        })
    }

    // MARK: Filling a draft

    private enum Fit { case fill, agrees, conflict }

    /// Fills a draft's empty day, time, part of the day and timeframe from the words that belong to the task, and cuts what was read out
    /// of the title, the purpose and the instructions. Never overwrites a value the draft has: a phrase that disagrees stays where it is.
    ///  - The task's own fields come first: the day and time the model could not give as a value and the repeat that is really a when
    ///    (each only when the whole text is a when-phrase), then the title, the purpose and the instructions.
    ///  - The user's words (`transcript`) fill what is still empty only when `readsTranscript` is true, which the caller sets when the
    ///    answer has exactly one task. With several tasks a phrase from the words could belong to any of them.
    ///  - A routine, and any text that says how often, is left alone.
    static func apply(_ item: inout DraftItem, from t: ExtractionTaskValue, transcript: String?, readsTranscript: Bool, now: Date, calendar: Calendar) {
        guard item.kind == .task else { return }
        let pastWords = transcript.map(hasPastMarker) ?? false

        func advise(_ note: String) { if !item.advisories.contains(note) { item.advisories.append(note) } }
        var periodMissing: String?
        func slotHint(_ s: Scan) -> DaySlot? { firstSlot(s) ?? item.slot }

        func fit(_ m: Match, _ hint: DaySlot?) -> Fit {
            switch m.kind {
            case .day(let d):
                if let due = item.due { return calendar.isDate(due, inSameDayAs: d) ? .agrees : .conflict }
                return item.softDue == nil ? .fill : .conflict
            case .clock(let c):
                guard let have = item.timeMinutes else { return .fill }
                // Without a period there is nothing to agree with: the model's time stays, and the gate asks the words for its evidence.
                guard let minutes = resolve(c, slot: hint) else { return .conflict }
                return have == minutes ? .agrees : .conflict
            case .slot(let x):
                if item.timeMinutes != nil { return .agrees }
                guard let have = item.slot else { return .fill }
                return have == x ? .agrees : .conflict
            case .soft(let x):
                if let have = item.softDue { return Words.key(have) == Words.key(x) ? .agrees : .conflict }
                return item.due == nil ? .fill : .conflict
            }
        }

        func commit(_ m: Match, _ hint: DaySlot?, _ s: Scan) {
            let said = s.phrase(m.range)
            switch m.kind {
            case .day(let d):
                item.due = d
                item.evidence["day"] = said
                Trace.step("SWIFT", "when: “\(said)” read as the day \(d.formatted(date: .abbreviated, time: .omitted))")
                if m.kal { advise("I read “kal” as tomorrow. Tap it to change.") }
            case .clock(let c):
                if let minutes = resolve(c, slot: hint) {
                    item.timeMinutes = minutes
                    item.slot = nil
                    item.evidence["time"] = said
                    Trace.step("SWIFT", "when: “\(said)” read as \(format(minutes))")
                } else {
                    // "at ten" with no am/pm and no part of the day: the time is not guessed. It stays empty, the phrase is kept as
                    // said and the card asks for it ("Time needs a fix").
                    periodMissing = said
                    if item.unparsed["time"] == nil { item.unparsed["time"] = said }
                    Trace.step("SWIFT", "when: “\(said)” has no am/pm and no part of the day: no time read")
                }
            case .slot(let x):
                if item.timeMinutes == nil { item.slot = x; item.evidence["slot"] = said }
                Trace.step("SWIFT", "when: “\(said)” read as the \(x.rawValue)")
            case .soft(let x):
                item.softDue = x
                item.evidence["softDue"] = said
                Trace.step("SWIFT", "when: “\(said)” kept as the timeframe “\(x)”")
            }
        }

        /// Fills what the matches say and returns the ones that were used or agree with the draft: those are cut out of their field.
        func take(_ s: Scan) -> [Match] {
            let hint = slotHint(s)
            var used: [Match] = []
            for m in s.matches.sorted(by: { $0.order < $1.order }) {
                switch fit(m, hint) {
                case .fill:
                    commit(m, hint, s)
                    // A clock with no period was not read: its words stay where they are.
                    if case .clock(let c) = m.kind, resolve(c, slot: hint) == nil { break }
                    used.append(m)
                case .agrees: used.append(m)
                case .conflict: break
                }
            }
            return used
        }

        /// A day, time or repeat the mapper could not read: when the whole text is a when-phrase that fits, it is read and the flag goes.
        func flagged(_ key: String, _ raw: String?) {
            guard let raw, item.unparsed[key] == raw else { return }
            let s = scan(raw, now: now, calendar: calendar, whole: true, past: pastWords)
            guard !s.repeatCue, !s.matches.isEmpty else { return }
            let inside = Set(s.matches.flatMap { Array($0.range) })
            guard s.words.indices.allSatisfy({ inside.contains($0) || fieldGlue.contains(s.words[$0]) }) else { return }
            let hint = slotHint(s)
            guard s.matches.allSatisfy({ fit($0, hint) != .conflict }) else { return }
            _ = take(s)
            if periodMissing != nil { return }      // the time was not read: the flag stays
            item.unparsed[key] = nil
            if key == "repeat" { item.schedule = nil }
        }

        /// The words left of `s` once the used phrases are cut out. A gap at the end loses a preposition left hanging; at the start, "and".
        func without(_ used: [Match], in s: Scan) -> String {
            let cut = Set(used.flatMap { Array($0.range) })
            var kept = s.orig.indices.filter { !cut.contains($0) }
            if let last = cut.max(), last == s.orig.count - 1 {
                while let k = kept.last, trailingDangling.contains(s.words[k]) { kept.removeLast() }
            }
            if cut.min() == 0 {
                while let k = kept.first, leadingDangling.contains(s.words[k]) { kept.removeFirst() }
            }
            return kept.map { s.orig[$0] }.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: " ,;"))
        }

        func freeText(_ text: String) -> (scan: Scan, used: [Match])? {
            let s = scan(text, now: now, calendar: calendar, whole: false, past: pastWords)
            guard !s.repeatCue, !s.matches.isEmpty else { return nil }
            let used = take(s)
            return used.isEmpty ? nil : (s, used)
        }

        flagged("date", TaskDraftMapper.clean(t.dueDate))
        flagged("time", TaskDraftMapper.clean(t.dueTime))
        flagged("repeat", TaskDraftMapper.clean(t.schedule))

        if let (s, used) = freeText(item.title) {
            let rest = without(used, in: s)
            if !rest.isEmpty, TaskMeaning.hasContent(rest), rest != item.title {
                Trace.step("SWIFT", "when: the title \"\(item.title)\" loses the words that say when: \"\(rest)\"")
                item.title = rest
            }
        }

        for path in [\DraftItem.reason, \DraftItem.instructions] as [WritableKeyPath<DraftItem, String?>] {
            guard let text = item[keyPath: path], let (s, used) = freeText(text) else { continue }
            let rest = without(used, in: s)
            let words = rest.lowercased().split(whereSeparator: { !($0.isLetter || $0.isNumber || $0 == "'") }).map(String.init)
            let titleWords = Set(item.title.lowercased().split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init))
            if words.isEmpty || words.allSatisfy({ leftoverGlue.contains($0) }) || words.allSatisfy({ titleWords.contains($0) }) {
                Trace.step("SWIFT", "when: \"\(text)\" said only when: not kept")
                item[keyPath: path] = nil
            } else {
                item[keyPath: path] = rest
            }
        }

        if readsTranscript, let words = transcript {
            let s = scan(words, now: now, calendar: calendar, whole: false, past: pastWords)
            if !s.repeatCue { _ = take(s) }
        }
    }
}
