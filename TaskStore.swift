import Foundation
import Combine
import SwiftUI

// MARK: - Categories, filters

enum TaskCategory: String, Codable, CaseIterable {
    case househelp, work, personal, family, errands, health, finance, other

    var label: String { rawValue.capitalized }

    var emoji: String {
        switch self {
        case .househelp: return "🧹"
        case .work: return "💼"
        case .personal: return "🙂"
        case .family: return "👨‍👩‍👧"
        case .errands: return "🛒"
        case .health: return "💪"
        case .finance: return "💳"
        case .other: return "📌"
        }
    }

    // Rule-based fallback used when Apple Intelligence isn't available.
    private static let keywords: [(TaskCategory, [String])] = [
        (.finance, ["pay ", "bill", "rent", "tax", "invoice", "bank", "insurance", "loan"]),
        (.health, ["doctor", "dentist", "gym", "workout", "medicine", "vitamin", "checkup", "therapy", "yoga"]),
        (.work, ["meeting", "email", "report", "client", "presentation", "deadline", "project", "slides", "standup"]),
        (.househelp, ["dust", "dish", "sweep", "mop", "laundry", "iron", "chop", "veggie", "vegetable",
                      "cook", "clean", "wash", "vacuum", "utensil", "kitchen", "bathroom", "bedsheet", "polish"]),
        (.errands, ["buy", "pick up", "pickup", "shop", "grocer", "post office", "courier", "refill"]),
        (.family, ["kid", "school", "mom", "dad", "mother", "father", "wife", "husband", "birthday", "anniversary", "family"])
    ]

    static func guess(from text: String) -> TaskCategory {
        let t = text.lowercased()
        for (category, words) in keywords where words.contains(where: { t.contains($0) }) {
            return category
        }
        return .other
    }

    private static let synonyms: [(TaskCategory, [String])] = [
        (.househelp, ["househelp", "house help", "housemaid", "maid", "helper", "domestic help", "housekeeper"]),
        (.work, ["work", "office", "job"]),
        (.personal, ["personal"]),
        (.family, ["family", "kids"]),
        (.errands, ["errand", "shopping"]),
        (.health, ["health", "fitness"]),
        (.finance, ["finance", "money", "bills"])
    ]

    static func mentioned(in text: String) -> TaskCategory? {
        let t = text.lowercased()
        for (category, words) in synonyms where words.contains(where: { t.contains($0) }) {
            return category
        }
        return nil
    }
}

enum DayFilter: String {
    case anytime, today, tomorrow
}

enum StatusFilter { case open, done, all }

struct TaskLookupSpec {
    var assignees: [String] = []      // empty = anyone; several = any of them (e.g. Me and Family)
    var category: TaskCategory?
    var day: DayFilter = .anytime
    var status: StatusFilter = .open
    var overdueOnly = false           // "what is overdue"
    var profileID: UUID? = nil        // only this list
    var label: String? = nil          // only tasks carrying this label ("Zomato")
    /// Tasks shown with the label even though they do not carry it: the ones whose own words (or a related word) match.
    var alsoIDs: Set<UUID> = []
    /// Empty when `alsoIDs` were found by their words; otherwise why they are there ("tagged Zomato or Kitty").
    var alsoWhy = ""
}

struct PlannedTask {
    var title: String
    var category: TaskCategory?         // only when the user said it; never guessed from the title
    var due: Date?
    /// nil = one-off task. Otherwise how it repeats.
    var recurrence: RecurrenceSpec? = nil
    var assignee: String? = nil
    var slot: DaySlot? = nil
    var timeMinutes: Int? = nil
    var profile: String? = nil          // "Blinkit order": the list the user said it belongs to
    var categoryName: String? = nil
    var priority: String? = nil
    var notes: String? = nil
    var reason: String? = nil
    var utteranceID: UUID? = nil         // the one Utterance (the raw words of the turn) this task came from
    var instructions: String? = nil      // quantity, dosage, variant, method: what the user said about how, never system text
    var schedule: String? = nil          // a repeat, in the user's words (kept even when Swift could not read it)
    var softDue: String? = nil           // a timeframe that is not a day ("next week"), kept as said
    var evidence: [String: String] = [:] // the user's words that justified each value (see `TaskItem.evidence`)
}

/// How a routine repeats.
///  - every day:            weekdays = []
///  - chosen weekdays:      weekdays = [7, 1]               (1 = Sunday ... 7 = Saturday)
///  - every other week:     weekdays = [7], everyNWeeks = 2
///  - alternate days:       intervalDays = 2                 (counted from the routine's start date)
///  - monthly:              dayOfMonth = 5
struct RecurrenceSpec: Codable, Hashable {
    var weekdays: [Int] = []
    var everyNWeeks: Int = 1
    var intervalDays: Int? = nil
    var dayOfMonth: Int? = nil
}

extension RecurrenceSpec {
    /// "every Saturday", "every other day", ... the same wording a saved routine shows.
    var scheduleText: String {
        var r = Routine(title: "")
        r.weekdays = Array(Set(weekdays.filter { (1...7).contains($0) })).sorted()
        r.everyNWeeks = everyNWeeks > 1 ? everyNWeeks : nil
        r.intervalDays = (intervalDays ?? 1) > 1 ? intervalDays : nil
        r.dayOfMonth = dayOfMonth
        if r.intervalDays != nil || r.dayOfMonth != nil { r.weekdays = []; r.everyNWeeks = nil }
        return r.scheduleText
    }
}

/// A chore that repeats ("sweep every day", "wash restrooms every Saturday and Sunday", "dust on alternate days").
struct Routine: Identifiable, Codable, Hashable {
    var id = UUID()
    var title: String
    var category: TaskCategory? = nil
    var weekdays: [Int] = []          // chosen weekdays; empty = every day (unless interval/monthly is set)
    var assignee: String? = nil
    var everyNWeeks: Int? = nil       // 2 = every other week
    var intervalDays: Int? = nil      // 2 = every other day
    var dayOfMonth: Int? = nil        // monthly
    var startDate: Date? = nil        // when the routine was created: anchors "every N" and stops backfilling earlier days
    var slot: DaySlot? = nil          // when in the day it is usually done
    var timeMinutes: Int? = nil       // exact time, if one was given
    var reason: String? = nil         // why, when the user said it; copied to each day's task
    var said: String? = nil           // old data only: the cleaned words it came from. New routines link an Utterance instead.
    var utteranceID: UUID? = nil      // the raw words of the turn it was made in; copied to each day's task
    var instructions: String? = nil   // what the user said about how (quantity, method); copied to each day's task
    var schedule: String? = nil       // the repeat in the user's own words, kept beside the parsed one
    var createdAt: Date? = nil        // when it was saved; nil for routines saved before this was kept

    /// Who it is for, only when the user said it; empty means nobody was named (no person is shown or assumed).
    var effectiveAssignee: String {
        assignee.map(Assignee.normalize).flatMap { $0.isEmpty ? nil : $0 } ?? ""
    }

    func isDue(on date: Date) -> Bool {
        let cal = Calendar.current
        let day = cal.startOfDay(for: date)

        if let n = intervalDays, n > 1 {
            guard let start = startDate else { return false }
            let diff = cal.dateComponents([.day], from: cal.startOfDay(for: start), to: day).day ?? -1
            return diff >= 0 && diff % n == 0
        }
        if let dom = dayOfMonth {
            let last = cal.range(of: .day, in: .month, for: day)?.count ?? 31
            return cal.component(.day, from: day) == min(dom, last)
        }
        guard weekdays.isEmpty || weekdays.contains(cal.component(.weekday, from: day)) else { return false }
        if let w = everyNWeeks, w > 1 {
            guard let start = startDate,
                  let a = cal.dateInterval(of: .weekOfYear, for: start)?.start,
                  let b = cal.dateInterval(of: .weekOfYear, for: day)?.start else { return false }
            let weeks = (cal.dateComponents([.day], from: a, to: b).day ?? -7) / 7
            return weeks >= 0 && weeks % w == 0
        }
        return true
    }

    private func dayList(_ days: [Int]) -> String {
        let names = Calendar.current.weekdaySymbols
        let list = days.sorted().compactMap { (1...7).contains($0) ? names[$0 - 1] : nil }
        if list.count <= 1 { return list.first ?? "" }
        return list.dropLast().joined(separator: ", ") + " and " + (list.last ?? "")
    }

    private func ordinal(_ n: Int) -> String {
        let suffix = (11...13).contains(n % 100) ? "th" : (n % 10 == 1 ? "st" : (n % 10 == 2 ? "nd" : (n % 10 == 3 ? "rd" : "th")))
        return "\(n)\(suffix)"
    }

    var scheduleText: String {
        if let n = intervalDays, n > 1 { return n == 2 ? "every other day" : "every \(n) days" }
        if let dom = dayOfMonth { return "monthly on the \(ordinal(dom))" }
        let days = weekdays.sorted()
        if let w = everyNWeeks, w > 1 {
            let base = w == 2 ? "every other week" : "every \(w) weeks"
            return days.isEmpty ? base : base + " on " + dayList(days)
        }
        if days.isEmpty { return "every day" }
        if days == [2, 3, 4, 5, 6] { return "every weekday" }
        if days == [1, 7] { return "every weekend" }
        return "every " + dayList(days)
    }
}

/// One task inside a playbook, and who usually does it.
struct PlaybookStep: Codable, Hashable {
    var title: String
    var assignee: String? = nil
    var instructions: String? = nil
}

/// A procedure the user taught Kitty ("how I make biryani"). Kitty never invents the steps.
struct Playbook: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var category: TaskCategory? = nil
    var steps: [PlaybookStep]
    var ordered: Bool? = nil            // true when the steps are a sequence (copied from a list the user marked "Steps in order")
}

// MARK: - The same chore listed more than once

/// "Clean dishes" overdue on three days is one stack: shown once, with "+2".
struct TaskStack: Identifiable {
    var items: [TaskItem]                 // oldest first
    var id: UUID { items[0].id }
    var lead: TaskItem { items[0] }
    var extra: Int { items.count - 1 }
}

enum TaskStacking {
    /// Open, loose tasks with the same title and person collapse into one stack. Finished tasks and
    /// playbook steps are never collapsed. The order of first appearance is kept.
    static func stacks(_ tasks: [TaskItem]) -> [TaskStack] {
        var order: [String] = []
        var buckets: [String: [TaskItem]] = [:]
        for t in tasks {
            let key = (t.isDone || t.group != nil) ? t.id.uuidString : t.title.lowercased() + "|" + t.effectiveAssignee.lowercased()
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(t)
        }
        return order.compactMap { key in
            guard let items = buckets[key], !items.isEmpty else { return nil }
            return TaskStack(items: items.sorted { $0.effectiveDue < $1.effectiveDue })
        }
    }
}

// MARK: - Order

/// The one order every list and preview uses, applied here in Swift and never asked of the model: what is overdue comes first,
/// then the day slot from morning to night, then the time. Ties keep the order they had.
/// An exact time wins over a slot; a task with neither goes to the end of the day ("anytime").
enum TaskSorting {
    struct Key: Comparable {
        var overdue: Bool
        var day: Double
        var minutes: Int
        var index: Int

        static func < (a: Key, b: Key) -> Bool {
            if a.overdue != b.overdue { return a.overdue }
            if a.day != b.day { return a.day < b.day }
            if a.minutes != b.minutes { return a.minutes < b.minutes }
            return a.index < b.index
        }
    }

    /// `acrossDays`: group by day first (a list that shows several days). Otherwise the day is ignored apart from overdue.
    static func key(due: Date?, minutes: Int, index: Int, acrossDays: Bool, now: Date = .now) -> Key {
        let cal = Calendar.current
        let day = due.map { cal.startOfDay(for: $0) }
        let overdue = day.map { $0 < cal.startOfDay(for: now) } ?? false
        return Key(overdue: overdue && !acrossDays, day: acrossDays ? (day?.timeIntervalSince1970 ?? 0) : 0, minutes: minutes, index: index)
    }

    static func ordered(_ items: [TaskItem], acrossDays: Bool = false) -> [TaskItem] {
        items.enumerated().sorted {
            key(due: $0.element.effectiveDue, minutes: $0.element.sortMinutes, index: $0.offset, acrossDays: acrossDays)
                < key(due: $1.element.effectiveDue, minutes: $1.element.sortMinutes, index: $1.offset, acrossDays: acrossDays)
        }.map(\.element)
    }

    /// The same order for the tasks in a preview that is waiting for Save. Nothing is ever dropped or changed, only moved.
    static func ordered(_ items: [DraftItem]) -> [DraftItem] {
        items.enumerated().sorted {
            key(due: $0.element.due, minutes: minutes($0.element), index: $0.offset, acrossDays: false)
                < key(due: $1.element.due, minutes: minutes($1.element), index: $1.offset, acrossDays: false)
        }.map(\.element)
    }

    private static func minutes(_ d: DraftItem) -> Int {
        d.timeMinutes ?? (d.slot ?? .anytime).defaultMinutes
    }
}

// MARK: - Lists ("profiles") you create by talking

/// A named place for items, made the first time you mention it: "add milk to my Blinkit order".
struct TaskProfile: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var createdAt = Date()
    var ordered: Bool? = nil           // true only when the user said the items go in a sequence; nil reads as false
    var requestID: UUID? = nil         // the Utterance of the request that created the list

    var isOrdered: Bool { ordered ?? false }
    var symbol: String { Self.symbol(for: name) }

    static func symbol(for name: String) -> String {
        let t = name.lowercased()
        func has(_ words: [String]) -> Bool { words.contains { t.contains($0) } }
        if has(["blinkit", "zepto", "instamart", "bigbasket", "grocer", "shopping", "cart", "order", "basket"]) { return "cart.fill" }
        if has(["trip", "travel", "vacation", "holiday", "flight", "goa", "tour"]) { return "airplane" }
        if has(["party", "birthday", "diwali", "wedding", "event", "gift"]) { return "gift.fill" }
        if has(["school", "kids", "homework"]) { return "graduationcap.fill" }
        if has(["medicine", "pharmacy", "health", "doctor"]) { return "cross.case.fill" }
        if has(["repair", "home", "house", "fix"]) { return "wrench.and.screwdriver.fill" }
        return "tray.full.fill"
    }
}

// MARK: - Household words

/// Names and spellings the user wants Kitty to recognise ("Rani is the house help"). They are reference vocabulary for
/// hearing and spelling, never facts or tasks. How Kitty understands a request is the model's job, not a settings screen.
nonisolated enum KittyGuideStore {
    static let profileNamesKey = "kitty.profileNames"
    static let householdKey = "kitty.guide.household"
    static var household: String { UserDefaults.standard.string(forKey: householdKey) ?? "" }
}

/// What the household editor shows and edits.
@MainActor
final class KittyGuide: ObservableObject {
    static let shared = KittyGuide()
    @Published var household: String { didSet { UserDefaults.standard.set(household, forKey: KittyGuideStore.householdKey) } }
    init() { household = KittyGuideStore.household }
}

// MARK: - Time of day

/// When in the day a task is normally done. Used to order the list: morning walk first, evening walk later.
enum DaySlot: String, Codable, CaseIterable, Identifiable {
    case morning, afternoon, evening, night, anytime
    var id: String { rawValue }
    var label: String { rawValue.capitalized }

    var symbol: String {
        switch self {
        case .morning: return "sunrise.fill"
        case .afternoon: return "sun.max.fill"
        case .evening: return "sunset.fill"
        case .night: return "moon.stars.fill"
        case .anytime: return "clock"
        }
    }

    /// Where a task with no exact time sits within the day, in minutes after midnight.
    var defaultMinutes: Int {
        switch self {
        case .morning: return 8 * 60
        case .afternoon: return 14 * 60
        case .evening: return 18 * 60 + 30
        case .night: return 21 * 60 + 30
        case .anytime: return 24 * 60 + 1
        }
    }

    static func from(minutes: Int) -> DaySlot {
        switch minutes {
        case 4 * 60..<12 * 60: return .morning
        case 12 * 60..<17 * 60: return .afternoon
        case 17 * 60..<21 * 60: return .evening
        default: return .night
        }
    }

    /// Keyword fallback when Apple Intelligence is not available.
    static func guess(from title: String) -> DaySlot {
        let t = " " + title.lowercased() + " "
        func has(_ words: [String]) -> Bool { words.contains { t.contains($0) } }
        if has([" night", "tonight", "bedtime", "bed time", " sleep", "midnight", "before bed"]) { return .night }
        if has([" evening", " dinner", " supper", " sunset", "tea time", " dusk"]) { return .evening }
        if has([" afternoon", " lunch", " noon", " midday", " siesta"]) { return .afternoon }
        if has([" morning", " breakfast", " wake up", " wake-up", " sunrise", " dawn"]) { return .morning }
        return .anytime
    }

    /// "6 am", "7:30 pm" in the text, as minutes after midnight.
    static func parseClock(in text: String) -> Int? {
        let pattern = "\\b(\\d{1,2})(?::(\\d{2}))?\\s*(am|pm)\\b"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let hourRange = Range(m.range(at: 1), in: text),
              var hour = Int(text[hourRange]),
              let ampmRange = Range(m.range(at: 3), in: text) else { return nil }
        var minute = 0
        if let minuteRange = Range(m.range(at: 2), in: text) { minute = Int(text[minuteRange]) ?? 0 }
        guard (1...12).contains(hour), (0...59).contains(minute) else { return nil }
        let pm = text[ampmRange].lowercased() == "pm"
        if hour == 12 { hour = 0 }
        if pm { hour += 12 }
        return hour * 60 + minute
    }

    /// "HH:mm" (24 hour) as minutes after midnight.
    static func parseHHmm(_ text: String) -> Int? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]), (0...23).contains(h), (0...59).contains(m) else { return nil }
        return h * 60 + m
    }

    static func clockLabel(_ minutes: Int) -> String {
        let h24 = (minutes / 60) % 24
        let m = minutes % 60
        let h12 = h24 % 12 == 0 ? 12 : h24 % 12
        return "\(h12):\(m < 10 ? "0" : "")\(m) \(h24 < 12 ? "AM" : "PM")"
    }
}

// MARK: - What the Talk to Kitty panel shows

enum PanelDay: String, CaseIterable, Identifiable {
    case today = "Today", tomorrow = "Tomorrow", all = "All"
    var id: String { rawValue }
}

/// Which person's tasks to show.
enum AssigneeChoice: Hashable {
    case all
    case mine                    // tasks tagged Me or Family
    case person(String)

    var names: [String] {
        switch self {
        case .all: return []
        case .mine: return [Assignee.me, Assignee.family]
        case .person(let n): return [n]
        }
    }

    var title: String {
        switch self {
        case .all: return "All"
        case .mine: return "Mine"
        case .person(let n): return n
        }
    }

    static func from(_ names: [String]) -> AssigneeChoice {
        let set = Set(names.map { $0.lowercased() })
        if set.isEmpty { return .all }
        if set == [Assignee.me.lowercased(), Assignee.family.lowercased()] { return .mine }
        if names.count == 1 { return .person(Assignee.normalize(names[0])) }
        return .all
    }
}

/// Which tasks to show: only open ones, only the overdue backlog, only finished ones, or everything.
enum PanelStatus: String, CaseIterable, Identifiable {
    case open = "Open", overdue = "Overdue", done = "Done", all = "All"
    var id: String { rawValue }
}

struct PanelFilter: Equatable {
    var who: AssigneeChoice = .all
    var category: TaskCategory? = nil
    var day: PanelDay = .today
    var status: PanelStatus = .open
    var profileID: UUID? = nil          // show one list; the day filter is ignored for a list
    var label: String? = nil            // show the tasks carrying one label
    /// Tasks shown with the label although they only mention it (see `TaskLookupSpec.alsoIDs`).
    var alsoIDs: Set<UUID> = []
    /// The view answers a question that narrowed it (a day, a person, a category, a label): what was asked for comes first.
    var requestedFirst = false
    /// Only tasks created on or after this moment, newest first (the home screen's "New"). Tasks with no creation date are left out.
    var addedSince: Date? = nil
}

/// Where the tasks that are still open from before go in a list.
enum OverdueSpot: Equatable {
    case top             // the home screen and the Overdue chip: the backlog leads
    case noteBelow       // a day was asked for: one red line under that day's tasks
    case sectionBelow    // a person, category or label was asked for: the overdue ones match, so they are listed, after
}

extension TaskLookupSpec {
    /// Did the question narrow the view? Then what it asked for is shown, and said, first.
    var isNarrowing: Bool { label != nil || category != nil || !assignees.isEmpty || day != .anytime }
}

extension PanelFilter {
    /// One rule for the inline list, the full list and the spoken text.
    var overdueSpot: OverdueSpot {
        guard profileID == nil, status == .open || status == .all else { return .top }
        if day == .tomorrow { return .noteBelow }
        guard requestedFirst else { return .top }
        return day == .today ? .noteBelow : .sectionBelow
    }

    /// Looking at tomorrow (or at today, after a question), what is still open from before is one line under the asked-for tasks.
    var overdueIsNoteBelow: Bool { overdueSpot == .noteBelow }

    /// "4 overdue from today" for the one line under tomorrow's tasks.
    static func overdueNote(count: Int) -> String { "\(count) overdue from today" }

    /// The same line for the view being shown: today's tasks say "4 overdue", tomorrow's say "4 overdue from today".
    func noteText(count: Int) -> String { day == .today ? "\(count) overdue" : Self.overdueNote(count: count) }

    /// The view that matches a question Kitty just answered.
    init(spec: TaskLookupSpec) {
        let status: PanelStatus
        if spec.overdueOnly {
            status = .overdue
        } else {
            switch spec.status {
            case .open: status = .open
            case .done: status = .done
            case .all: status = .all
            }
        }
        self.init(who: AssigneeChoice.from(spec.assignees),
                  category: spec.category,
                  day: spec.day == .today ? .today : (spec.day == .tomorrow ? .tomorrow : .all),
                  status: status)
        self.profileID = spec.profileID
        self.label = spec.label
        self.alsoIDs = spec.alsoIDs
        self.requestedFirst = spec.isNarrowing && spec.profileID == nil
    }
}

/// The asked-for tasks first, the overdue ones after. Used by the list under a reply, the full list and the tests, so they
/// cannot disagree with each other or with what Kitty says.
struct PanelOrder {
    var requested: [TaskItem]
    var overdue: [TaskItem]
    var spot: OverdueSpot

    init(_ data: (overdue: [TaskItem], due: [TaskItem]), filter: PanelFilter) {
        requested = data.due
        overdue = data.overdue
        spot = filter.overdueSpot
    }

    /// Every task in the order shown.
    var flat: [TaskItem] { spot == .top ? overdue + requested : requested + overdue }

    /// The list under a reply: at most `limit` cards. The asked-for tasks take the slots first; overdue ones get what is left
    /// (when they match the question) or one line (when a day was asked for).
    struct Inline {
        var cards: [TaskStack]            // in order, the asked-for tasks first
        var overdueCards: [TaskStack]     // under an "Overdue" label, after the cards
        var overdueHidden: Int            // overdue tasks not shown as cards: one red line that opens the full list
        var shown: Int { cards.count + overdueCards.count }
    }

    func inline(limit: Int = 5) -> Inline {
        switch spot {
        case .top:
            return Inline(cards: Array(TaskStacking.stacks(flat).prefix(limit)), overdueCards: [], overdueHidden: 0)
        case .noteBelow:
            return Inline(cards: Array(TaskStacking.stacks(requested).prefix(limit)), overdueCards: [], overdueHidden: overdue.count)
        case .sectionBelow:
            let cards = Array(TaskStacking.stacks(requested).prefix(limit))
            let late = TaskStacking.stacks(overdue)
            let room = max(0, limit - cards.count)
            let shown = Array(late.prefix(room))
            let hidden = late.dropFirst(room).reduce(0) { $0 + $1.items.count }
            return Inline(cards: cards, overdueCards: shown, overdueHidden: hidden)
        }
    }

    /// The same two groups for a list of tasks that is not split yet (the spoken text of a question with no day).
    static func split(_ items: [TaskItem]) -> (requested: [TaskItem], overdue: [TaskItem]) {
        (items.filter { !$0.isOverdue }, items.filter(\.isOverdue))
    }
}

// MARK: - Who a task is for

enum Assignee {
    static let me = "Me"
    static let family = "Family"
    static let househelp = "Househelp"

    private static let roles: Set<String> = ["me", "family", "househelp", "cook", "driver", "gardener", "nanny", "chef"]

    /// A role ("cook", "me") rather than a person's name.
    static func isRole(_ name: String) -> Bool { roles.contains(normalize(name).lowercased()) }

    /// "the maid" / "house help" -> Househelp, "I" -> Me, "everyone" -> Family, other names are capitalised.
    static func normalize(_ raw: String) -> String {
        var t = raw.lowercased().replacingOccurrences(of: "’", with: "'")
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
        for p in ["the ", "my ", "our "] where t.hasPrefix(p) { t = String(t.dropFirst(p.count)) }
        switch t {
        case "": return ""
        case "me", "i", "myself", "mine", "self": return me
        case "family", "everyone", "everybody", "all", "all of us", "whole family", "entire family", "we", "us", "us all":
            return family
        case "househelp", "house help", "maid", "helper", "housemaid", "housekeeper", "domestic help", "house helper", "help":
            return househelp
        default: return t.capitalized
        }
    }

    /// Spots who a sentence is about: "ask the maid to sweep", "I will call the bank", "the whole family should...".
    /// `forQuery` is stricter about "me" so "what are my tasks" stays a whole-list question.
    static func detect(in text: String, forQuery: Bool = false) -> String? {
        let letters = text.lowercased().replacingOccurrences(of: "’", with: "'")
            .map { $0.isLetter || $0.isNumber || $0 == "'" ? $0 : " " }
        let t = " " + String(letters).split(separator: " ").joined(separator: " ") + " "
        func has(_ list: [String]) -> Bool { list.contains { t.contains($0) } }

        if has([" maid ", " maid's ", " househelp ", " househelp's ", " house help ", " house help's ", " house helper ",
                " helper ", " helper's ", " housemaid ", " housekeeper ", " domestic help ",
                " the help ", " my help ", " our help ", " the help's "]) { return househelp }
        for role in ["cook", "driver", "gardener", "nanny", "chef"] {
            if has([" the \(role) ", " my \(role) ", " our \(role) ", " ask \(role) ", " \(role)'s "]) { return role.capitalized }
        }
        var familyPhrases = [" for the family ", " for everyone ", " family's ", " everyone's ", " the whole family ", " the entire family ", " all of us "]
        var mePhrases = [" assigned to me ", " for me ", " only mine ", " mine ", " my own ", " just me ", " only me ", " by me "]
        if !forQuery {
            familyPhrases += [" family should ", " everyone should ", " we should ", " we all ", " everyone needs "]
            mePhrases += [" i will ", " i'll ", " i need to ", " i should ", " i have to ", " i must ", " myself ", " i am going to ", " i'm going to "]
        }
        if has(familyPhrases) { return family }
        if has(mePhrases) { return me }
        return nil
    }
}

// MARK: - Labels

/// Name helpers for tags (category and list names). Free-form labels no longer exist.
nonisolated enum TaskLabels {
    /// Words that name no particular thing: never offered as a name to tap or search by.
    static let generic: Set<String> = [
        "task", "tasks", "other", "misc", "miscellaneous", "general", "stuff", "things", "todo", "to do", "to-do", "chores", "chore",
        "item", "items", "none", "unknown",
        "update", "updates", "get", "new", "reminder", "reminders", "important", "urgent", "high", "low", "medium", "priority",
        "today", "tomorrow", "tonight", "yesterday", "morning", "afternoon", "evening", "night", "daily", "weekly", "monthly",
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday", "me", "myself", "you", "my", "project"]

    /// A word reduced so "designs" and "design" match.
    static func stem(_ word: String) -> String {
        var w = word.lowercased().filter { $0.isLetter || $0.isNumber }
        for suffix in ["ing", "es", "ed", "s"] where w.count > suffix.count + 2 && w.hasSuffix(suffix) {
            w = String(w.dropLast(suffix.count)); break
        }
        return w
    }

    /// A whole label reduced word by word: "Zomato", "zomato" and "Designs"/"Design" are each one label.
    static func stemKey(_ s: String) -> String {
        s.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map { stem(String($0)) }.joined(separator: " ")
    }

    static func same(_ a: String, _ b: String) -> Bool {
        let k = stemKey(a)
        return !k.isEmpty && k == stemKey(b)
    }

    /// Words that make a list a list ("Blinkit order", "Goa trip list"): left out of the short name.
    static let listWords: Set<String> = ["order", "list", "cart", "basket", "shopping", "checklist", "wishlist", "profile"]

    /// The name people say for a list: "Blinkit order" is also "Blinkit". Empty when nothing is left, so the full name is used.
    static func listShort(_ name: String) -> String {
        let kept = name.split(whereSeparator: { $0.isWhitespace }).filter { !listWords.contains($0.lowercased()) }
        return kept.joined(separator: " ")
    }

    /// The main label first, then the extras, once each (case-insensitive), the first spelling kept.
    static func merged(primary: String, extras: [String]) -> [String] {
        var out: [String] = []
        for raw in [primary] + extras {
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, !out.contains(where: { $0.lowercased() == t.lowercased() }) else { continue }
            out.append(t)
        }
        return out
    }
}

// MARK: - Tags

/// One searchable name on a task. The type says where it came from (and gets its icon); search ignores the type.
struct TaskTag: Equatable, Hashable {
    enum Kind: String, CaseIterable {
        case person, category, list, priority, routine, playbook

        var icon: String {
            switch self {
            case .person: return "person.fill"
            case .category: return "folder.fill"
            case .list: return "tray.full.fill"
            case .priority: return "flag.fill"
            case .routine: return "repeat"
            case .playbook: return "list.bullet.rectangle"
            }
        }

        /// How a reply says it: "3 tagged Kitty", "2 for Kitty", "1 on your Kitty list".
        func phrase(_ count: Int, _ name: String) -> String {
            switch self {
            case .person: return "\(count) for \(name)"
            case .list: return "\(count) on your \(name) list"
            default: return "\(count) tagged \(name)"
            }
        }
    }
    var kind: Kind
    var name: String
}

/// A name in use as a tag, with every type it exists as and how many open tasks carry it.
struct TagEntry: Equatable {
    var name: String
    var kinds: Set<TaskTag.Kind>
    var count: Int
}

// MARK: - Utterances

/// What the user actually said in one turn, as heard (the raw words, never cleaned or rewritten). One `Utterance` is written when
/// a Save is confirmed, and every task or routine made from that turn points to it with `utteranceID`, so a turn that made five
/// tasks keeps its words once. A draft that is abandoned stores nothing.
struct Utterance: Identifiable, Codable, Equatable {
    enum Source: String, Codable { case voice, typed }
    var id = UUID()
    var rawText: String
    var createdAt = Date()
    var source: Source = .voice
}

/// The utterances, as JSON in UserDefaults like the tasks. Kept only while something still points to them.
nonisolated final class UtteranceStore: @unchecked Sendable {
    static let shared = UtteranceStore()
    static let key = "kitty.utterances"

    private let defaults: UserDefaults
    private let lock = NSLock()
    private var stored: [Utterance]
    var all: [Utterance] { lock.lock(); defer { lock.unlock() }; return stored }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key), let list = try? JSONDecoder().decode([Utterance].self, from: data) { stored = list } else { stored = [] }
    }

    func utterance(_ id: UUID?) -> Utterance? { id.flatMap { id in all.first { $0.id == id } } }

    /// Stores the words of one turn and returns its id. Nil, and nothing stored, for empty words or when "Save task details" is off.
    @discardableResult
    func record(_ rawText: String, source: Utterance.Source = .voice, createdAt: Date = .now) -> UUID? {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Trace.recording, !text.isEmpty else { return nil }
        let u = Utterance(rawText: text, createdAt: createdAt, source: source)
        lock.lock(); stored.append(u); lock.unlock()
        persist()
        return u.id
    }

    /// Drops the utterances nothing points to any more.
    func prune(keeping ids: Set<UUID>) {
        lock.lock()
        let kept = stored.filter { ids.contains($0.id) }
        let changed = kept.count != stored.count
        stored = kept
        lock.unlock()
        if changed { persist() }
    }

    func clear() { lock.lock(); stored = []; lock.unlock(); persist() }

    private func persist() {
        if let data = try? JSONEncoder().encode(all) { defaults.set(data, forKey: Self.key) }
    }
}

extension TaskItem {
    /// The words a task keeps about itself beyond its title: why (as the model gave it) and the words it was said in.
    var storedWords: String { [reason, UtteranceStore.shared.utterance(utteranceID)?.rawText].compactMap { $0 }.joined(separator: " ") }
}

// MARK: - Model

struct TaskItem: Identifiable, Codable, Hashable {
    var id = UUID()
    var title: String
    var isDone = false
    var category: TaskCategory? = nil   // optional so tasks saved by older versions still load
    var dueDate: Date? = nil
    var group: String? = nil            // set for steps of a bigger job, e.g. "Cook biryani"
    var routineID: UUID? = nil          // set for today's copy of a repeating routine
    var assignee: String? = nil         // who usually does it, e.g. "Cook", "Maid"
    var slot: DaySlot? = nil            // morning / afternoon / evening / night / anytime
    var timeMinutes: Int? = nil         // exact time of day in minutes after midnight, if known
    var profileID: UUID? = nil          // the list ("profile") it belongs to, e.g. "Blinkit order"
    var categoryName: String? = nil     // the specific category the user's words point to: "Bathroom", "Groceries"
    var priority: String? = nil         // "low", "medium" or "high", only if the user said so
    var notes: String? = nil
    var labels: [String]? = nil         // legacy: free-form labels saved by older versions. Still read when loading, never written or shown
    var reason: String? = nil           // why, in a few of the user's own words, when they said it (checked by Swift)
    var said: String? = nil             // old data only: the cleaned words. Never written any more; the raw words live in one Utterance.
    var utteranceID: UUID? = nil        // the Utterance (raw words of the turn) this task came from; nil when none was kept
    var instructions: String? = nil     // what the user said about how: quantity, dosage, variant, method. Never system text (that is `notes`)
    var schedule: String? = nil         // the repeat in the user's words, when the task came from a repeat
    var softDue: String? = nil          // a timeframe that is not a day ("next week"), as said; shown, never turned into a date
    var createdAt: Date? = nil          // set when saved; nil for tasks saved before this was kept (shown as unknown)
    var completedAt: Date? = nil        // set when completed, cleared when reopened
    /// The words of the user that justified each value the task holds ("assignee": "ask Rani to"), or "added by you" for a hand edit.
    /// Nil for tasks saved before this was kept: they show no evidence line.
    var evidence: [String: String]? = nil
}

extension TaskItem {
    /// The category the user named. A task with none is in "Other" for the category filters; the category is never guessed from the title.
    var effectiveCategory: TaskCategory { category ?? .other }

    /// Who it is for, only when the user said it; empty means nobody was named. No person is assumed from the category.
    var effectiveAssignee: String {
        assignee.map(Assignee.normalize).flatMap { $0.isEmpty ? nil : $0 } ?? ""
    }

    /// Whether the task is for one of these people. Nobody named counts as the owner's own ("Me", "Family"): such a task stays in
    /// "Mine" and is never put under another person. An empty list means anyone.
    func isFor(_ names: [String]) -> Bool {
        let wanted = names.map { $0.lowercased() }
        if wanted.isEmpty { return true }
        let who = effectiveAssignee.lowercased()
        if who.isEmpty { return wanted.contains(Assignee.me.lowercased()) || wanted.contains(Assignee.family.lowercased()) }
        return wanted.contains(who)
    }

    /// Whether the user gave a day. A task with none has no day: it is not in Today and not overdue, and it sorts after the dated ones.
    var hasDate: Bool { dueDate != nil }

    /// The day for sorting and filtering. An undated task has none: it is far in the future, so no day filter matches it.
    var effectiveDue: Date { dueDate ?? .distantFuture }

    /// An item on a named list ("milk" on "Blinkit order") with no date of its own. It lives on its list, not in
    /// Today or Overdue.
    var isListItem: Bool { profileID != nil && dueDate == nil }

    /// What the category tag shows: the specific name if there is one ("Bathroom"), otherwise the built-in category.
    /// Empty when the user named no category.
    var categoryLabel: String { categoryName ?? category?.label ?? "" }

    /// The names to draw under a task: its category, then its list. Nothing else.
    var tagNames: [String] { TaskLabels.merged(primary: categoryLabel, extras: listName.map { [$0] } ?? []) }

    /// The list this item is on ("Blinkit order"). Playbook steps also have a `group`, but no list.
    var listName: String? {
        guard profileID != nil, let g = group?.trimmingCharacters(in: .whitespacesAndNewlines), !g.isEmpty else { return nil }
        return g
    }

    /// Every tag the task carries, whatever its type: who it is for, its category, its list, its priority. Days and status are not tags.
    var tags: [TaskTag] {
        var out: [TaskTag] = []
        func add(_ kind: TaskTag.Kind, _ raw: String?) {
            let name = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !out.contains(where: { $0.kind == kind && TaskLabels.same($0.name, name) }) else { return }
            out.append(TaskTag(kind: kind, name: name))
        }
        add(.category, categoryLabel)
        add(.list, listName)
        add(.person, effectiveAssignee)
        add(.priority, priority.map { $0.prefix(1).uppercased() + $0.dropFirst() })
        if routineID != nil { add(.routine, "Routine") }
        if profileID == nil { add(.playbook, group) }
        return out
    }

    /// Does it carry this tag, of any type? Case and plural do not matter. "Blinkit" matches the list "Blinkit order".
    func hasTag(_ name: String) -> Bool {
        if tags.contains(where: { TaskLabels.same($0.name, name) }) { return true }
        if let list = listName {
            let short = TaskLabels.listShort(list)
            return !short.isEmpty && TaskLabels.same(short, name)
        }
        return false
    }

    /// The old name for `hasTag`: a label filter now matches every tag type.
    func hasLabel(_ name: String) -> Bool { hasTag(name) }

    /// Playbook steps keep the order you taught; everything else sorts by when in the day it happens.
    var sortSlot: DaySlot {
        if group != nil { return .anytime }
        if let m = timeMinutes ?? DaySlot.parseClock(in: title) { return DaySlot.from(minutes: m) }
        return slot ?? DaySlot.guess(from: title)
    }

    var sortMinutes: Int { timeMinutes ?? DaySlot.parseClock(in: title) ?? sortSlot.defaultMinutes }

    /// "6:30 AM" if there is an exact time, otherwise "Morning", "Evening"... nil for anytime.
    var timeLabel: String? {
        if group == nil, let m = timeMinutes ?? DaySlot.parseClock(in: title) { return DaySlot.clockLabel(m) }
        let s = sortSlot
        return s == .anytime ? nil : s.label
    }

    /// Whole days past its due date while still open (the backlog).
    var daysOverdue: Int {
        guard !isDone, !isListItem, hasDate else { return 0 }
        let cal = Calendar.current
        return max(0, cal.dateComponents([.day], from: cal.startOfDay(for: effectiveDue), to: cal.startOfDay(for: .now)).day ?? 0)
    }
    var isOverdue: Bool { daysOverdue > 0 }

    var dueLabel: String {
        guard let d = dueDate else { return "No date" }
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "Today" }
        if cal.isDateInTomorrow(d) { return "Tomorrow" }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        return d.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }

    var subtitle: String {
        var parts: [String] = []
        if let c = category { parts.append("\(c.emoji) \(c.label)") }
        if !effectiveAssignee.isEmpty { parts.append("👤 \(effectiveAssignee)") }
        parts.append("📅 \(dueLabel)")
        if isOverdue { parts.append("⚠️ \(daysOverdue)d overdue") }
        if routineID != nil { parts.append("🔁 Routine") }
        if let g = group { parts.append(g) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Store

@MainActor
final class TaskStore: ObservableObject {
    static let shared = TaskStore()

    @Published private(set) var tasks: [TaskItem] = []
    @Published private(set) var routines: [Routine] = []
    @Published private(set) var playbooks: [Playbook] = []
    @Published private(set) var profiles: [TaskProfile] = []
    private var materialized: Set<String> = []     // "routineID|yyyy-MM-dd" copies already created
    private let key = "quicktasks.items"
    private let routinesKey = "kitty.routines"
    private let playbooksKey = "kitty.playbooks"
    private let profilesKey = "kitty.profiles"
    private let materializedKey = "kitty.materialized"

    private let defaults: UserDefaults

    /// `defaults` is the user's own unless a test gives it a scratch one.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        load()
    }

    // MARK: Create

    @discardableResult
    func add(_ title: String) -> TaskItem {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        // Typed in by hand on the Today screen: the day is the user's own act, and the evidence says so.
        var item = TaskItem(title: clean, dueDate: Calendar.current.startOfDay(for: .now))
        item.evidence = ["day": "added by you"]
        tasks.insert(item, at: 0)
        save()
        return item
    }

    @discardableResult
    func addMany(_ titles: [String]) -> [TaskItem] {
        addMany(titles.map { PlannedTask(title: $0, category: nil, due: nil) })
    }

    @discardableResult
    func addMany(_ planned: [PlannedTask]) -> [TaskItem] {
        let now = Date()
        // A task that names a list is put on it: the list is found by its name, or made once for the whole request. A task on a
        // list with no day of its own lives on the list, not in Today.
        var lists: [String: TaskProfile] = [:]
        var madeLists: [TaskProfile] = []
        func list(_ raw: String?, request: UUID?) -> TaskProfile? {
            guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let key = TaskLabels.stemKey(raw)
            if let known = lists[key] { return known }
            let found = ensureProfile(raw, requestID: request)
            lists[key] = found.profile
            if found.created { madeLists.append(found.profile) }
            return found.profile
        }
        let items = planned
            .filter { !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { p -> TaskItem in
                let profile = list(p.profile, request: p.utteranceID)
                // No day is made up: a task the user gave no day stays undated (a task on a list lives on its list).
                var made = TaskItem(title: p.title.trimmingCharacters(in: .whitespacesAndNewlines), category: p.category,
                                dueDate: p.due, group: profile?.name, assignee: p.assignee,
                                slot: p.slot, timeMinutes: p.timeMinutes, profileID: profile?.id,
                                categoryName: p.categoryName, priority: p.priority, notes: p.notes,
                                reason: p.reason, utteranceID: p.utteranceID,
                                instructions: p.instructions, schedule: p.schedule, softDue: p.softDue, createdAt: now)
                made.evidence = p.evidence.isEmpty ? nil : p.evidence
                return made
            }
        tasks.insert(contentsOf: items, at: 0)
        // Reported only when the tasks were really stored: if encoding failed, they are taken back out and nothing is returned, so
        // the caller can never say "saved" for tasks that are not.
        guard save() else {
            let ids = Set(items.map(\.id))
            tasks.removeAll { ids.contains($0.id) }
            let made = Set(madeLists.map(\.id))
            if !made.isEmpty { profiles.removeAll { made.contains($0.id) }; persistExtras() }       // a list made for tasks that were not stored
            return []
        }
        return items
    }

    /// Splits "buy milk, call mom and then book flights" into 3 tasks.
    nonisolated static func splitCompound(_ text: String) -> [String] {
        var s = text
        for sep in [" and then ", " and also ", " then ", " also ", ";", "\n", ",", " and "] {
            s = s.replacingOccurrences(of: sep, with: "|", options: .caseInsensitive)
        }
        return s.split(separator: "|")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .map { piece -> String in
                var p = piece
                for prefix in ["and ", "to "] where p.lowercased().hasPrefix(prefix) {
                    p = String(p.dropFirst(prefix.count))
                }
                return p.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }
    }

    // MARK: Read

    func search(_ query: String) -> [TaskItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return tasks }
        // What was typed, as part of a word or tag (partial typing finds it). Meaning is the model's job, not this search's.
        let typed = tasks.filter { t in
            t.title.localizedCaseInsensitiveContains(q) || t.hasTag(q)
                || (t.categoryName?.localizedCaseInsensitiveContains(q) ?? false)
                || t.storedWords.localizedCaseInsensitiveContains(q)
        }
        return typed
    }

    /// Category + day + status lookup.
    /// "today" includes tasks due today, overdue open tasks, and open tasks with no date.
    func query(_ spec: TaskLookupSpec) -> [TaskItem] {
        refreshRoutines()
        let cal = Calendar.current
        return tasks.filter { t in
            if let pid = spec.profileID {
                if t.profileID != pid { return false }
            } else if t.isListItem && spec.day != .anytime {
                return false                        // items on a list are not "due today"
            }
            if let c = spec.category, t.effectiveCategory != c { return false }
            if let l = spec.label, !t.hasTag(l), !spec.alsoIDs.contains(t.id) { return false }
            if !t.isFor(spec.assignees) { return false }
            switch spec.status {
            case .open: if t.isDone { return false }
            case .done: if !t.isDone { return false }
            case .all: break
            }
            switch spec.day {
            case .anytime:
                return true
            case .today:
                let d = t.effectiveDue
                return cal.isDateInToday(d) || (d < cal.startOfDay(for: .now) && !t.isDone)
            case .tomorrow:
                return cal.isDateInTomorrow(t.effectiveDue)
            }
        }
    }

    // MARK: Day briefing: what is due that day, plus what is still open from before

    func briefing(_ spec: TaskLookupSpec) -> (onDay: [TaskItem], earlier: [TaskItem]) {
        refreshRoutines(includeTomorrow: spec.day == .tomorrow)
        let cal = Calendar.current
        let today = cal.startOfDay(for: .now)
        let target = spec.day == .tomorrow ? (cal.date(byAdding: .day, value: 1, to: today) ?? today) : today

        let mine = tasks.filter { t in
            if t.isListItem { return false }
            if let c = spec.category, t.effectiveCategory != c { return false }
            if let l = spec.label, !t.hasTag(l), !spec.alsoIDs.contains(t.id) { return false }
            if !t.isFor(spec.assignees) { return false }
            switch spec.status {
            case .open: return !t.isDone
            case .done: return t.isDone
            case .all: return true
            }
        }
        let onDay = timeOrdered(mine.filter { cal.isDate($0.effectiveDue, inSameDayAs: target) }, byDay: false)
        let earlier = spec.status != .done ? timeOrdered(mine.filter { !$0.isDone && cal.startOfDay(for: $0.effectiveDue) < target }, byDay: true) : []
        return (onDay, earlier)
    }

    /// Orders tasks by day (optionally) and then by time of day: morning walk before evening walk. See `TaskSorting`.
    func timeOrdered(_ items: [TaskItem], byDay: Bool) -> [TaskItem] {
        TaskSorting.ordered(items, acrossDays: byDay)
    }

    /// What the Talk to Kitty panel lists: tasks due that day (done ones included, so they can be undone)
    /// and, separately, everything still open from before.
    func panel(_ f: PanelFilter) -> (overdue: [TaskItem], due: [TaskItem]) {
        let cal = Calendar.current
        let today = cal.startOfDay(for: .now)
        let target = f.day == .tomorrow ? (cal.date(byAdding: .day, value: 1, to: today) ?? today) : today

        let mine = tasks.filter { t in
            if let pid = f.profileID {
                if t.profileID != pid { return false }
            } else if t.isListItem && f.day != .all {
                return false                        // list items are not due today or tomorrow
            }
            if !t.isFor(f.who.names) { return false }
            if let c = f.category, t.effectiveCategory != c { return false }
            if let l = f.label, !t.hasTag(l), !f.alsoIDs.contains(t.id) { return false }
            if let since = f.addedSince, (t.createdAt ?? .distantPast) < since { return false }
            return true
        }
        func dayOf(_ t: TaskItem) -> Date { cal.startOfDay(for: t.effectiveDue) }
        let cutoff = (f.day == .all || f.profileID != nil) ? today : target
        func isLate(_ t: TaskItem) -> Bool { !t.isDone && dayOf(t) < cutoff }
        func onDay(_ t: TaskItem) -> Bool { f.day == .all || f.profileID != nil || cal.isDate(t.effectiveDue, inSameDayAs: target) }
        let oldestFirst: (TaskItem, TaskItem) -> Bool = { $0.effectiveDue < $1.effectiveDue }

        let overdue: [TaskItem]
        var due: [TaskItem]
        switch f.status {
        case .open:
            overdue = mine.filter(isLate).sorted(by: oldestFirst)
            due = mine.filter { !$0.isDone && !isLate($0) && onDay($0) }
        case .overdue:
            overdue = mine.filter(isLate).sorted(by: oldestFirst)
            due = []
        case .done:
            overdue = []
            due = mine.filter { $0.isDone && onDay($0) }.sorted { $0.effectiveDue > $1.effectiveDue }
        case .all:
            overdue = mine.filter(isLate).sorted(by: oldestFirst)
            due = mine.filter { !isLate($0) && onDay($0) }
        }
        let ordered = f.status == .done ? due : timeOrdered(due, byDay: f.day == .all)
        if f.addedSince != nil {
            let newestFirst: (TaskItem, TaskItem) -> Bool = { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
            return (overdue.sorted(by: newestFirst), ordered.sorted(by: newestFirst))
        }
        return (timeOrdered(overdue, byDay: true), ordered)
    }

    /// Everyone tasks can be assigned to, the usual three first.
    var allAssigneeNames: [String] {
        var out = [Assignee.me, Assignee.family, Assignee.househelp]
        let more = tasks.map(\.effectiveAssignee) + routines.map(\.effectiveAssignee)
            + playbooks.flatMap { $0.steps.compactMap(\.assignee) }.map(Assignee.normalize)
        for n in more where !n.isEmpty && !out.contains(where: { $0.lowercased() == n.lowercased() }) { out.append(n) }
        return out
    }

    /// How many tasks each status chip would show right now (for the chip labels).
    func panelCounts(_ f: PanelFilter) -> [PanelStatus: Int] {
        var out: [PanelStatus: Int] = [:]
        for s in PanelStatus.allCases {
            var g = f
            g.status = s
            let d = panel(g)
            out[s] = d.overdue.count + d.due.count
        }
        return out
    }

    func openCount(for choice: AssigneeChoice) -> Int {
        return tasks.filter { !$0.isDone && $0.isFor(choice.names) }.count
    }

    /// Saves times Apple Intelligence decided for tasks (and their routines, so future days follow).
    func applyTimes(_ updates: [UUID: (slot: DaySlot, minutes: Int?)]) {
        guard !updates.isEmpty else { return }
        for i in tasks.indices {
            guard let u = updates[tasks[i].id] else { continue }
            tasks[i].slot = u.slot
            if tasks[i].timeMinutes == nil { tasks[i].timeMinutes = u.minutes }
            if let rid = tasks[i].routineID, let r = routines.firstIndex(where: { $0.id == rid }), routines[r].slot == nil {
                routines[r].slot = u.slot
                routines[r].timeMinutes = routines[r].timeMinutes ?? u.minutes
            }
        }
        persistExtras()
        save()
    }

    func setAssignee(_ id: UUID, to name: String) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[i].assignee = Assignee.normalize(name)
        save()
    }

    func setDue(_ id: UUID, to date: Date) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[i].dueDate = Calendar.current.startOfDay(for: date)
        save()
    }

    func setRoutineAssignee(_ id: UUID, to name: String) {
        guard let i = routines.firstIndex(where: { $0.id == id }) else { return }
        routines[i].assignee = Assignee.normalize(name)
        persistExtras()
    }

    // MARK: Routines (repeating chores)

    private func dayKey(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    /// Saves a routine. Returns nil if an identical one already exists.
    @discardableResult
    func addRoutine(title: String, category: TaskCategory?, recurrence: RecurrenceSpec, assignee: String? = nil,
                    slot: DaySlot? = nil, timeMinutes: Int? = nil, reason: String? = nil, utteranceID: UUID? = nil,
                    instructions: String? = nil, schedule: String? = nil, allowDuplicate: Bool = false) -> Routine? {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        var r = Routine(title: clean, category: category,
                        weekdays: Array(Set(recurrence.weekdays.filter { (1...7).contains($0) })).sorted(),
                        assignee: assignee.map(Assignee.normalize).flatMap { $0.isEmpty ? nil : $0 })
        r.everyNWeeks = recurrence.everyNWeeks > 1 ? recurrence.everyNWeeks : nil
        r.intervalDays = (recurrence.intervalDays ?? 1) > 1 ? recurrence.intervalDays : nil
        r.dayOfMonth = recurrence.dayOfMonth.map { min(max($0, 1), 31) }
        if r.intervalDays != nil || r.dayOfMonth != nil { r.weekdays = []; r.everyNWeeks = nil }
        r.startDate = Calendar.current.startOfDay(for: .now)
        r.slot = slot
        r.timeMinutes = timeMinutes
        r.reason = reason
        r.utteranceID = utteranceID
        r.instructions = instructions
        r.schedule = schedule
        r.createdAt = Date()
        // A routine the user did not approve one by one (a quick path) is still not repeated; an approved draft item passes
        // `allowDuplicate` and is saved, because the card already told the user about the saved match before they approved.
        if !allowDuplicate, routines.contains(where: { $0.title.lowercased() == clean.lowercased() && $0.scheduleText == r.scheduleText }) { return nil }
        routines.append(r)
        persistExtras()
        return r
    }

    func removeRoutine(_ id: UUID) {
        routines.removeAll { $0.id == id }
        tasks.removeAll { $0.routineID == id && !$0.isDone }
        persistExtras()
        save()
    }

    func removeRoutines(at offsets: IndexSet) {
        let ids = offsets.map { routines[$0].id }
        ids.forEach(removeRoutine)
    }

    /// Creates the task for every routine occurrence that is due (today, and tomorrow on request).
    /// Days missed while the app was closed (up to two weeks back, never before the routine existed) are
    /// created too. Tasks nobody finished are NOT dropped: they stay open with their old due date as backlog.
    func refreshRoutines(includeTomorrow: Bool = false) {
        let cal = Calendar.current
        let today = cal.startOfDay(for: .now)
        var days: [Date] = (1...14).reversed().compactMap { cal.date(byAdding: .day, value: -$0, to: today) }
        days.append(today)
        if includeTomorrow, let t = cal.date(byAdding: .day, value: 1, to: today) { days.append(t) }

        var changed = false
        var fresh: [TaskItem] = []
        for day in days {
            for r in routines where r.isDue(on: day) {
                if day < cal.startOfDay(for: r.startDate ?? today) { continue }
                let k = "\(r.id.uuidString)|\(dayKey(day))"
                guard !materialized.contains(k) else { continue }
                materialized.insert(k)
                fresh.append(TaskItem(title: r.title, category: r.category, dueDate: day, routineID: r.id, assignee: r.assignee,
                                      slot: r.slot, timeMinutes: r.timeMinutes, reason: r.reason, said: r.said, utteranceID: r.utteranceID,
                                      instructions: r.instructions, schedule: r.schedule, createdAt: Date()))
            }
        }
        // Newest first, like other tasks; backlog from earlier days sits just below.
        if !fresh.isEmpty { tasks.insert(contentsOf: fresh.reversed(), at: 0); changed = true }

        if let old = cal.date(byAdding: .day, value: -30, to: today) {
            let cutoff = dayKey(old)
            let kept = materialized.filter { (($0.split(separator: "|").last).map(String.init) ?? "") >= cutoff }
            if kept.count != materialized.count { materialized = kept; changed = true }
        }
        if changed { persistExtras(); save() }
    }

    // MARK: Categories and changes from the voice decision

    /// Names already on tasks as a category name, then the list names (newest first): the spellings the model can reuse.
    var usedCategoryNames: [String] {
        var out: [String] = []
        for t in tasks { let l = t.categoryName ?? ""; if !l.isEmpty, !out.contains(where: { $0.lowercased() == l.lowercased() }) { out.append(l) } }
        for l in listTopicNames where !out.contains(where: { $0.lowercased() == l.lowercased() }) { out.append(l) }
        return Array(out.prefix(40))
    }

    /// The lists, as people say them: "Blinkit" for "Blinkit order", "Kitty" for "Kitty".
    var listTopicNames: [String] {
        profiles.map { p in
            let short = TaskLabels.listShort(p.name)
            return short.isEmpty ? p.name : short
        }
    }

    /// The tag in use that is spelled most like `name` (one or two letters off), for "Did you mean…?". Nil when none is close.
    func nearestTag(to name: String) -> String? {
        let target = Array(TaskLabels.stemKey(name))
        guard target.count >= 3 else { return nil }
        func distance(_ a: [Character], _ b: [Character]) -> Int {
            var row = Array(0...b.count)
            for i in 1...max(1, a.count) where i <= a.count {
                var prev = row[0]
                row[0] = i
                for j in 1...max(1, b.count) where j <= b.count {
                    let keep = row[j]
                    row[j] = Swift.min(row[j] + 1, row[j - 1] + 1, prev + (a[i - 1] == b[j - 1] ? 0 : 1))
                    prev = keep
                }
            }
            return row[b.count]
        }
        let allowed = target.count >= 7 ? 2 : 1
        return tagIndex
            .compactMap { entry -> (String, Int)? in
                let d = distance(target, Array(TaskLabels.stemKey(entry.name)))
                return d >= 1 && d <= allowed ? (entry.name, d) : nil
            }
            .min { $0.1 < $1.1 }?.0
    }

    /// Every tag name in use, most used first, one spelling each, with the types it exists as: the choices of the tag filter.
    /// People, categories and lists all count; a name that is several types is one entry.
    var tagIndex: [TagEntry] {
        var order: [String] = []
        var byKey: [String: TagEntry] = [:]
        func note(_ name: String, _ kind: TaskTag.Kind) {
            let k = TaskLabels.stemKey(name)
            guard !k.isEmpty else { return }
            if byKey[k] == nil { byKey[k] = TagEntry(name: name, kinds: [], count: 0); order.append(k) }
            byKey[k]?.kinds.insert(kind)
        }
        for t in tasks {
            for tag in t.tags where tag.kind != .routine && tag.kind != .priority { note(tag.name, tag.kind) }
        }
        for p in profiles { note(p.name, .list) }
        // Once per task: a name that is both the category and the list of one task counts once.
        for t in tasks where !t.isDone {
            for k in Set(t.tags.map { TaskLabels.stemKey($0.name) }) where byKey[k] != nil { byKey[k]?.count += 1 }
        }
        return order.compactMap { byKey[$0] }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.name.lowercased() < $1.name.lowercased() }
    }

    /// The same names as `tagIndex`, as the filter menu shows them.
    var labelCounts: [(name: String, count: Int)] { tagIndex.map { (name: $0.name, count: $0.count) } }

    /// A tag the words name, with the types it exists as.
    struct TagMention: Equatable {
        var name: String
        var kinds: Set<TaskTag.Kind>
    }

    /// Every tag these words name ("show tasks about Kitty"), the longest first, as the household spells it. A built-in category,
    /// a role ("the cook"), Me and Family are left out: they keep their own meaning.
    func tagsMentioned(in text: String) -> [TagMention] {
        let cleaned = text.lowercased().replacingOccurrences(of: "\\b(hey|hi|hello|ok|okay)[, ]+kitty\\b", with: " ", options: .regularExpression)
        let said = Set(cleaned.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map { TaskLabels.stem(String($0)) })
        var found: [(mention: TagMention, words: Int)] = []
        func consider(_ name: String, _ kinds: Set<TaskTag.Kind>) {
            let parts = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map { TaskLabels.stem(String($0)) }
            guard !parts.isEmpty, parts.allSatisfy({ $0.count >= 3 && said.contains($0) }),
                  !TaskLabels.generic.contains(name.lowercased()) else { return }
            if kinds == [.person], Assignee.isRole(name) || name.lowercased() == Assignee.me.lowercased()
                || name.lowercased() == Assignee.family.lowercased() { return }
            let key = TaskLabels.stemKey(name)
            if let i = found.firstIndex(where: { TaskLabels.stemKey($0.mention.name) == key }) { found[i].mention.kinds.formUnion(kinds) }
            else { found.append((TagMention(name: name, kinds: kinds), parts.count)) }
        }
        for e in tagIndex { consider(e.name, e.kinds) }
        for p in profiles {                                   // "Blinkit" for the list "Blinkit order"
            let short = TaskLabels.listShort(p.name)
            if !short.isEmpty { consider(short, [.list]) }
        }
        return found.sorted { $0.words > $1.words }.map(\.mention)
    }

    /// The first name `tagsMentioned` finds.
    func labelMentioned(in text: String) -> String? { tagsMentioned(in: text).first?.name }

    var knownCategoryNames: [String] {
        var out: [String] = []
        func add(_ n: String) {
            if out.count < 12, !out.contains(where: { $0.lowercased() == n.lowercased() }) { out.append(n) }
        }
        for t in tasks { if let n = t.categoryName { add(n) } }
        for l in listTopicNames { add(l) }
        for c in TaskCategory.allCases where c != .other { add(c.label) }
        return out
    }

    /// Applies what the user changed ("make it high priority") to one task.
    func applyChanges(_ id: UUID, with c: ValidatedTask) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        if let p = c.priority { tasks[i].priority = p }
        if let a = c.assignee { tasks[i].assignee = a }
        if let d = c.due { tasks[i].dueDate = Calendar.current.startOfDay(for: d) }
        if let m = c.timeMinutes { tasks[i].timeMinutes = m }
        if let n = c.notes { tasks[i].notes = n }
        if let name = c.categoryName {
            tasks[i].categoryName = name
            tasks[i].category = TaskCategory.mentioned(in: name.lowercased()) ?? tasks[i].category
        }
        save()
    }

    /// What the flat edit can also change on a saved task: purpose, instructions, part of the day, timeframe, list, and fields to
    /// empty. Applied after `applyChanges`. The list is the one that exists, or one made now (the user approved the change).
    func applyEditExtras(_ id: UUID, with c: ValidatedTask) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        for field in c.cleared {
            switch field.lowercased().filter({ $0.isLetter }) {
            case "day", "date", "due", "duedate": tasks[i].dueDate = nil
            case "time", "clock", "duetime": tasks[i].timeMinutes = nil
            case "timeofday", "slot", "daypart": tasks[i].slot = nil
            case "priority": tasks[i].priority = nil
            case "person", "assignee", "for", "who": tasks[i].assignee = nil
            case "purpose", "reason": tasks[i].reason = nil
            case "instructions": tasks[i].instructions = nil
            case "timeframe", "softdue": tasks[i].softDue = nil
            case "list", "listname": tasks[i].profileID = nil; tasks[i].group = nil
            default: break
            }
        }
        if let r = c.reason { tasks[i].reason = r }
        if let h = c.instructions { tasks[i].instructions = h }
        if c.timeMinutes == nil, let s = c.slot, s != .anytime { tasks[i].slot = s; tasks[i].timeMinutes = nil }
        if c.timeMinutes != nil { tasks[i].slot = nil }
        if let soft = c.softDue { tasks[i].softDue = soft; if c.due == nil { tasks[i].dueDate = nil } }
        if let name = c.listName {
            let p = ensureProfile(name).profile
            tasks[i].profileID = p.id
            tasks[i].group = p.name
        }
        save()
    }

    /// Does the stored task now hold what the change asked for? The reply says "done" only when this is true.
    func holds(_ id: UUID, _ c: ValidatedTask) -> Bool {
        guard let t = tasks.first(where: { $0.id == id }) else { return false }
        let cal = Calendar.current
        if let d = c.due, !(t.dueDate.map { cal.isDate($0, inSameDayAs: d) } ?? false) { return false }
        if let m = c.timeMinutes, t.timeMinutes != m { return false }
        if let p = c.priority, t.priority != p { return false }
        if let a = c.assignee, t.assignee != a { return false }
        if let r = c.reason, t.reason != r { return false }
        if let h = c.instructions, t.instructions != h { return false }
        if let soft = c.softDue, t.softDue != soft { return false }
        if let l = c.listName, !(t.isOnList(l) || (t.listName.map { TaskLabels.same($0, Self.cleanProfileName(l)) } ?? false)) { return false }
        for field in c.cleared {
            switch field.lowercased().filter({ $0.isLetter }) {
            case "day", "date", "due", "duedate": if t.dueDate != nil { return false }
            case "time", "clock", "duetime": if t.timeMinutes != nil { return false }
            case "priority": if t.priority != nil { return false }
            case "purpose", "reason": if t.reason != nil { return false }
            case "instructions": if t.instructions != nil { return false }
            case "timeframe", "softdue": if t.softDue != nil { return false }
            case "list", "listname": if t.profileID != nil { return false }
            default: break
            }
        }
        return true
    }

    // MARK: Lists (profiles)

    static let genericListWords: Set<String> = TaskLabels.listWords

    /// "my blinkit order" -> "Blinkit order"
    static func cleanProfileName(_ raw: String) -> String {
        var t = raw.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
        for p in ["my ", "the ", "our ", "a ", "an "] where t.lowercased().hasPrefix(p) { t = String(t.dropFirst(p.count)) }
        t = t.trimmingCharacters(in: .whitespaces)
        guard let first = t.first else { return "" }
        return first.uppercased() + t.dropFirst()
    }

    private func keyTokens(_ s: String) -> [String] {
        let t = TaskMatcher.tokens(s, dropping: Self.genericListWords)
        return t.isEmpty ? TaskMatcher.tokens(s) : t
    }

    /// The words that name a list (so they are not mistaken for an item).
    func listWords(_ p: TaskProfile) -> Set<String> { Set(keyTokens(p.name)).union(Self.genericListWords) }

    /// An existing list for a name as the user said it ("blinkit" finds "Blinkit order").
    func profile(named raw: String) -> TaskProfile? {
        let q = keyTokens(raw)
        guard !q.isEmpty else { return nil }
        return profiles.first { p in
            let k = keyTokens(p.name)
            guard !k.isEmpty else { return false }
            return k.allSatisfy { w in q.contains { TaskMatcher.same(w, $0) } }
                || q.allSatisfy { w in k.contains { TaskMatcher.same(w, $0) } }
        }
    }

    /// An existing list named somewhere in a sentence.
    func profileMentioned(in text: String) -> TaskProfile? {
        let words = TaskMatcher.tokens(text)
        return profiles
            .filter { p in
                let k = keyTokens(p.name)
                return !k.isEmpty && k.allSatisfy { w in words.contains { TaskMatcher.same(w, $0) } }
            }
            .max { keyTokens($0.name).count < keyTokens($1.name).count }
    }

    /// Finds the list, or makes it. `created` is true when it is new.
    @discardableResult
    func ensureProfile(_ raw: String, requestID: UUID? = nil) -> (profile: TaskProfile, created: Bool) {
        if let existing = profile(named: raw) { return (existing, false) }
        let name = Self.cleanProfileName(raw)
        var p = TaskProfile(name: name.isEmpty ? "List" : name)
        p.requestID = requestID
        profiles.append(p)
        persistExtras()
        return (p, true)
    }

    func items(in profile: TaskProfile) -> [TaskItem] { tasks.filter { $0.profileID == profile.id } }

    /// Adds items to a list. They have no due date unless one is given.
    @discardableResult
    func addItems(_ titles: [String], to profile: TaskProfile, due: Date? = nil, assignee: String? = nil, notes: [String?] = []) -> [TaskItem] {
        var items: [TaskItem] = []
        for (i, raw) in titles.enumerated() {
            let title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }
            var item = TaskItem(title: title, category: nil, dueDate: due.map { Calendar.current.startOfDay(for: $0) },
                                group: profile.name, assignee: assignee, profileID: profile.id)
            if i < notes.count, let n = notes[i]?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty { item.notes = n }
            items.append(item)
        }
        tasks.insert(contentsOf: items, at: 0)
        save()
        return items
    }

    func renameProfile(_ id: UUID, to name: String) {
        guard let i = profiles.firstIndex(where: { $0.id == id }) else { return }
        let clean = Self.cleanProfileName(name)
        guard !clean.isEmpty else { return }
        profiles[i].name = clean
        for t in tasks.indices where tasks[t].profileID == id { tasks[t].group = clean }
        persistExtras()
        save()
    }

    func removeProfile(_ id: UUID, deleteItems: Bool) {
        if deleteItems {
            tasks.removeAll { $0.profileID == id }
        } else {
            let today = Calendar.current.startOfDay(for: .now)
            for t in tasks.indices where tasks[t].profileID == id {
                tasks[t].profileID = nil
                tasks[t].group = nil
                if tasks[t].dueDate == nil { tasks[t].dueDate = today }
            }
        }
        profiles.removeAll { $0.id == id }
        persistExtras()
        save()
    }

    /// Puts a task on a list (nil takes it off its list and makes it due today again).
    func moveTask(_ id: UUID, to profile: TaskProfile?) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        if let p = profile {
            tasks[i].profileID = p.id
            tasks[i].group = p.name
            tasks[i].dueDate = nil
        } else {
            tasks[i].profileID = nil
            tasks[i].group = nil
            if tasks[i].dueDate == nil { tasks[i].dueDate = Calendar.current.startOfDay(for: .now) }
        }
        save()
    }

    /// "Steps in order": a list is a sequence only when the user says so. Never inferred.
    func setOrdered(_ ordered: Bool, for profileID: UUID) {
        guard let i = profiles.firstIndex(where: { $0.id == profileID }) else { return }
        profiles[i].ordered = ordered ? true : nil
        persistExtras()
    }

    /// A list the user approved, kept as a playbook they can run again. It copies what makes the procedure (the titles, the
    /// instructions, the order and who usually does each step) and nothing about one run of it: not whether a step is done, not a
    /// one-off date or time, not a repeat. Returns false when the list has no items. The list itself is not changed.
    @discardableResult
    func savePlaybook(fromList profile: TaskProfile) -> Bool {
        // The items of one request keep the order they were said in (the store puts a request's items first, in order).
        let steps = items(in: profile).map { PlaybookStep(title: $0.title, assignee: $0.assignee, instructions: $0.instructions) }
        guard !steps.isEmpty else { return false }
        let clean = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return false }
        if let existing = playbook(matching: clean, minWords: 1) { playbooks.removeAll { $0.id == existing.id } }
        var pb = Playbook(name: clean, category: nil, steps: steps)
        pb.ordered = profile.isOrdered ? true : nil
        playbooks.append(pb)
        persistExtras()
        return true
    }

    @discardableResult
    func completeAll(in profile: TaskProfile) -> Int {
        let open = items(in: profile).filter { !$0.isDone }
        open.forEach { complete($0.id) }
        return open.count
    }

    @discardableResult
    func clearItems(in profile: TaskProfile) -> Int {
        let n = items(in: profile).count
        tasks.removeAll { $0.profileID == profile.id }
        save()
        return n
    }

    // MARK: Playbooks (procedures the user taught Kitty)

    /// Finds the playbook a piece of text refers to ("cook biryani" -> "Biryani").
    func playbook(matching text: String, ignoring extra: Set<String> = [], minWords: Int = 2) -> Playbook? {
        let words = TaskMatcher.tokens(text, dropping: extra)
        guard !words.isEmpty else { return nil }
        func has(_ list: [String], _ w: String) -> Bool { list.contains { TaskMatcher.same(w, $0) } }
        let hits = playbooks.filter { pb in
            let name = TaskMatcher.tokens(pb.name)
            guard !name.isEmpty else { return false }
            if name.allSatisfy({ has(words, $0) }) { return true }
            return words.count >= minWords && words.allSatisfy { has(name, $0) }
        }
        return hits.max { TaskMatcher.tokens($0.name).count < TaskMatcher.tokens($1.name).count }
    }

    /// Saves a playbook, replacing one with the same name. Returns true if it replaced an existing one.
    @discardableResult
    func savePlaybook(name: String, category: TaskCategory?, steps: [PlaybookStep]) -> Bool {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !steps.isEmpty else { return false }
        let existing = playbook(matching: clean, minWords: 1)
        if let existing { playbooks.removeAll { $0.id == existing.id } }
        playbooks.append(Playbook(name: clean, category: category, steps: steps))
        persistExtras()
        return existing != nil
    }

    func removePlaybook(_ id: UUID) {
        playbooks.removeAll { $0.id == id }
        persistExtras()
    }

    /// Creates the playbook's tasks, in order, grouped under its name, each with its assignee.
    @discardableResult
    func addPlaybookTasks(_ pb: Playbook, due: Date?) -> [TaskItem] {
        let items = pb.steps.map {
            TaskItem(title: $0.title, category: pb.category, dueDate: due, group: pb.name, assignee: $0.assignee)
        }
        tasks.insert(contentsOf: items, at: 0)
        save()
        return items
    }

    /// Everyone named as an assignee so far (excluding "Me").
    var assignees: [String] {
        var out: [String] = []
        let names = tasks.compactMap(\.assignee) + playbooks.flatMap { $0.steps.compactMap(\.assignee) }
        for n in names where n.lowercased() != "me" && !out.contains(where: { $0.lowercased() == n.lowercased() }) { out.append(n) }
        return out
    }

    // MARK: Update

    /// Replaces a task with an edited copy (the edit form). A change of list is handled as `moveTask` does: the list's name becomes the
    /// group, and a task taken off its list gets a day again. `completedAt` follows the done state. Returns false when the task is gone or could not be stored (the old copy is kept).
    @discardableResult
    func update(_ edited: TaskItem) -> Bool {
        guard let i = tasks.firstIndex(where: { $0.id == edited.id }) else { return false }
        let before = tasks[i]
        var item = edited
        item.title = edited.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if item.profileID != before.profileID {
            if let pid = item.profileID, let p = profiles.first(where: { $0.id == pid }) {
                item.group = p.name
            } else {
                item.profileID = nil
                item.group = nil
                if item.dueDate == nil { item.dueDate = Calendar.current.startOfDay(for: .now) }
            }
        }
        if item.isDone != before.isDone { item.completedAt = item.isDone ? Date() : nil }
        tasks[i] = item
        // Stored or not: if the tasks could not be encoded, the old copy is put back, so what is shown is what is saved.
        guard save() else { tasks[i] = before; return false }
        return true
    }

    func rename(_ id: UUID, to title: String) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[i].title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        save()
    }

    func complete(_ id: UUID) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[i].isDone = true
        tasks[i].completedAt = Date()
        save()
    }

    func reopen(_ id: UUID) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[i].isDone = false
        tasks[i].completedAt = nil
        save()
    }

    func toggle(_ id: UUID) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[i].isDone.toggle()
        tasks[i].completedAt = tasks[i].isDone ? Date() : nil
        save()
    }

    // MARK: Delete

    func delete(at offsets: IndexSet) {
        tasks.remove(atOffsets: offsets)
        save()
    }

    func remove(_ id: UUID) {
        tasks.removeAll { $0.id == id }
        save()
    }

    /// Points tasks at the utterance they were made from.
    func link(_ ids: [UUID], to utteranceID: UUID) {
        let set = Set(ids)
        var changed = false
        for i in tasks.indices where set.contains(tasks[i].id) { tasks[i].utteranceID = utteranceID; changed = true }
        if changed { save() }
    }

    @discardableResult
    func clearCompleted() -> Int {
        let count = tasks.filter(\.isDone).count
        tasks.removeAll { $0.isDone }
        save()
        return count
    }

    // MARK: Persistence

    /// False when the tasks could not be encoded and so were not stored.
    @discardableResult
    private func save() -> Bool {
        let stored: Bool
        if let data = try? JSONEncoder().encode(tasks) {
            defaults.set(data, forKey: key)
            stored = true
        } else {
            stored = false
        }
        guard stored else { return false }
        guard defaults === UserDefaults.standard else { return true }       // a scratch store never prunes the user's own turns
        TaskDetailsStore.shared.prune(keeping: Set(tasks.map(\.id)))      // how a task was made goes when the task does
        UtteranceStore.shared.prune(keeping: Set(tasks.compactMap(\.utteranceID) + routines.compactMap(\.utteranceID)))
        return true
    }

    private func persistExtras() {
        let d = defaults
        if let data = try? JSONEncoder().encode(routines) { d.set(data, forKey: routinesKey) }
        if let data = try? JSONEncoder().encode(playbooks) { d.set(data, forKey: playbooksKey) }
        if let data = try? JSONEncoder().encode(profiles) { d.set(data, forKey: profilesKey) }
        d.set(profiles.map(\.name), forKey: KittyGuideStore.profileNamesKey)      // so the guide can tell the model
        d.set(Array(materialized), forKey: materializedKey)
    }

    private func load() {
        let d = defaults
        if let data = d.data(forKey: key), let items = try? JSONDecoder().decode([TaskItem].self, from: data) {
            tasks = items
        }
        if let data = d.data(forKey: routinesKey), let r = try? JSONDecoder().decode([Routine].self, from: data) {
            routines = r
        }
        if let data = d.data(forKey: playbooksKey), let p = try? JSONDecoder().decode([Playbook].self, from: data) {
            playbooks = p
        }
        if let data = d.data(forKey: profilesKey), let p = try? JSONDecoder().decode([TaskProfile].self, from: data) {
            profiles = p
        }
        materialized = Set(d.stringArray(forKey: materializedKey) ?? [])

        // Every task has a day: older open tasks without one become due today.
        let today = Calendar.current.startOfDay(for: .now)
        for i in tasks.indices where tasks[i].dueDate == nil && !tasks[i].isDone && tasks[i].profileID == nil { tasks[i].dueDate = today }
    }
}
