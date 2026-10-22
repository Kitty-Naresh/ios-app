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
}

struct PlannedTask {
    var title: String
    var category: TaskCategory
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

    var effectiveAssignee: String {
        assignee.map(Assignee.normalize) ?? ((category ?? .guess(from: title)) == .househelp ? Assignee.househelp : Assignee.me)
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
}

/// A procedure the user taught Kitty ("how I make biryani"). Kitty never invents the steps.
struct Playbook: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var category: TaskCategory? = nil
    var steps: [PlaybookStep]
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

// MARK: - Lists ("profiles") you create by talking

/// A named place for items, made the first time you mention it: "add milk to my Blinkit order".
struct TaskProfile: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var createdAt = Date()

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

// MARK: - The Kitty guide: how Kitty organises and how she replies

/// Plain-text rules the user can edit. They are added to the instructions of every on-device model call,
/// so they have to stay short (the model's memory window is small).
nonisolated enum KittyGuideStore {
    static let organiseKey = "kitty.guide.organise"
    static let respondKey = "kitty.guide.respond"
    static let listKey = "kitty.guide.list"
    static let profileNamesKey = "kitty.profileNames"
    static let householdKey = "kitty.guide.household"
    static let smartKey = "kitty.guide.smartReplies"
    static let budget = 2400            // characters sent to the model per call

    static let defaultOrganise = """
    - Order each day by time of day: morning first, then afternoon, evening and night. Tasks with no time go last.
    - Keep playbook steps in the order they were taught. Never reorder them and never invent steps.
    - Show overdue tasks first. Show the same chore only once with a count, like "Clean dishes +2".
    - House chores are for the Househelp. Everything else is for Me unless a person is named. "My tasks" means Me and Family.
    - A task with no date is due today.
    - If a repeating task has no day, or a request is unclear, ask one short question instead of guessing.
    - Never create tasks the user did not say.
    """

    static let defaultRespond = """
    - Answer first, in one to three short sentences that sound natural when spoken.
    - Use only the facts you are given. Never invent or recalculate numbers, dates or names.
    - Mention overdue items and who they are for.
    - For long lists, name the first three and say "and N more". The full list is shown on screen.
    - Offer at most one helpful next step, such as moving overdue work to tomorrow.
    - Be warm and brief. No emoji.
    """

    static let defaultList = """
    - A list is a named place for items, like "Blinkit order", "Goa trip" or "Party shopping". Items on a list have no due date unless the user gives one.
    - "Add X to my Y order" or "put X in the Y list": X is the item and Y is the list. Never put the list name in the item.
    - Reuse an existing list when the name is close ("Blinkit" means "Blinkit order"). Only create a new list when none fits, and say it is new.
    - "I placed the order" or "got everything" means every item on that list is done. "Clear the list" removes the items. Always confirm before deleting a list.
    - If it is not clear which list the user means, ask.
    """

    static var list: String { UserDefaults.standard.string(forKey: listKey) ?? defaultList }
    static var profileNames: [String] { UserDefaults.standard.stringArray(forKey: profileNamesKey) ?? [] }

    static var organise: String { UserDefaults.standard.string(forKey: organiseKey) ?? defaultOrganise }
    static var respond: String { UserDefaults.standard.string(forKey: respondKey) ?? defaultRespond }
    static var household: String { UserDefaults.standard.string(forKey: householdKey) ?? "" }
    static var smartReplies: Bool { (UserDefaults.standard.object(forKey: smartKey) as? Bool) ?? true }

    enum Purpose { case understand, reply }

    /// The part of the guide a model call needs, ready to append to its instructions.
    static func block(_ purpose: Purpose) -> String {
        var parts: [String] = []
        parts.append(purpose == .understand ? organise : respond)
        if purpose == .understand {
            parts.append(list)
            let names = profileNames
            if !names.isEmpty { parts.append("Existing lists: " + names.joined(separator: ", ")) }
        }
        let home = household.trimmingCharacters(in: .whitespacesAndNewlines)
        if !home.isEmpty { parts.append("About this household:\n" + home) }
        let text = parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: "\n\n")
        guard !text.isEmpty else { return "" }
        return "\n\nFollow this guide from the user:\n" + String(text.prefix(budget))
    }
}

/// What the guide editor shows and edits.
@MainActor
final class KittyGuide: ObservableObject {
    static let shared = KittyGuide()

    @Published var organise: String { didSet { UserDefaults.standard.set(organise, forKey: KittyGuideStore.organiseKey) } }
    @Published var respond: String { didSet { UserDefaults.standard.set(respond, forKey: KittyGuideStore.respondKey) } }
    @Published var list: String { didSet { UserDefaults.standard.set(list, forKey: KittyGuideStore.listKey) } }
    @Published var household: String { didSet { UserDefaults.standard.set(household, forKey: KittyGuideStore.householdKey) } }
    @Published var smartReplies: Bool { didSet { UserDefaults.standard.set(smartReplies, forKey: KittyGuideStore.smartKey) } }

    init() {
        organise = KittyGuideStore.organise
        respond = KittyGuideStore.respond
        list = KittyGuideStore.list
        household = KittyGuideStore.household
        smartReplies = KittyGuideStore.smartReplies
    }

    func reset() {
        organise = KittyGuideStore.defaultOrganise
        respond = KittyGuideStore.defaultRespond
        list = KittyGuideStore.defaultList
        household = ""
        smartReplies = true
    }
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
}

extension PanelFilter {
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
    }
}

// MARK: - Who a task is for

enum Assignee {
    static let me = "Me"
    static let family = "Family"
    static let househelp = "Househelp"

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
                " helper ", " helper's ", " housemaid ", " housekeeper ", " domestic help "]) { return househelp }
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
}

extension TaskItem {
    var effectiveCategory: TaskCategory { category ?? .guess(from: title) }

    /// Who it is for. Tasks with nobody named go to the house help if it is a house chore, otherwise to Me.
    var effectiveAssignee: String {
        assignee.map(Assignee.normalize).flatMap { $0.isEmpty ? nil : $0 }
            ?? (effectiveCategory == .househelp ? Assignee.househelp : Assignee.me)
    }

    /// Every task has a day; older tasks without one count as today.
    var effectiveDue: Date { dueDate ?? Calendar.current.startOfDay(for: .now) }

    /// An item on a named list ("milk" on "Blinkit order") with no date of its own. It lives on its list, not in
    /// Today or Overdue.
    var isListItem: Bool { profileID != nil && dueDate == nil }

    /// What the category tag shows: the specific name if there is one ("Bathroom"), otherwise the built-in category.
    var categoryLabel: String { categoryName ?? effectiveCategory.label }

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
        guard !isDone, !isListItem else { return 0 }
        let cal = Calendar.current
        return max(0, cal.dateComponents([.day], from: cal.startOfDay(for: effectiveDue), to: cal.startOfDay(for: .now)).day ?? 0)
    }
    var isOverdue: Bool { daysOverdue > 0 }

    var dueLabel: String {
        let d = effectiveDue
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "Today" }
        if cal.isDateInTomorrow(d) { return "Tomorrow" }
        if cal.isDateInYesterday(d) { return "Yesterday" }
        return d.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }

    var subtitle: String {
        var parts = ["\(effectiveCategory.emoji) \(effectiveCategory.label)", "👤 \(effectiveAssignee)", "📅 \(dueLabel)"]
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

    private init() { load() }

    // MARK: Create

    @discardableResult
    func add(_ title: String) -> TaskItem {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let item = TaskItem(title: clean, category: .guess(from: clean), dueDate: Calendar.current.startOfDay(for: .now))
        tasks.insert(item, at: 0)
        save()
        return item
    }

    @discardableResult
    func addMany(_ titles: [String]) -> [TaskItem] {
        addMany(titles.map { PlannedTask(title: $0, category: .guess(from: $0), due: nil) })
    }

    @discardableResult
    func addMany(_ planned: [PlannedTask]) -> [TaskItem] {
        let today = Calendar.current.startOfDay(for: .now)
        let items = planned
            .map { PlannedTask(title: $0.title.trimmingCharacters(in: .whitespacesAndNewlines),
                               category: $0.category, due: $0.due, assignee: $0.assignee,
                               slot: $0.slot, timeMinutes: $0.timeMinutes,
                               categoryName: $0.categoryName, priority: $0.priority, notes: $0.notes) }
            .filter { !$0.title.isEmpty }
            .map { TaskItem(title: $0.title, category: $0.category, dueDate: $0.due ?? today, assignee: $0.assignee,
                            slot: $0.slot, timeMinutes: $0.timeMinutes,
                            categoryName: $0.categoryName, priority: $0.priority, notes: $0.notes) }
        tasks.insert(contentsOf: items, at: 0)
        save()
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
        return tasks.filter { $0.title.localizedCaseInsensitiveContains(q) }
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
            if !spec.assignees.isEmpty, !spec.assignees.contains(where: { $0.lowercased() == t.effectiveAssignee.lowercased() }) { return false }
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
            if !spec.assignees.isEmpty, !spec.assignees.contains(where: { $0.lowercased() == t.effectiveAssignee.lowercased() }) { return false }
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

    /// Orders tasks by day (optionally) and then by time of day: morning walk before evening walk.
    /// Tasks with the same time keep the order they already had.
    func timeOrdered(_ items: [TaskItem], byDay: Bool) -> [TaskItem] {
        let cal = Calendar.current
        func key(_ pair: (offset: Int, element: TaskItem)) -> (Double, Int, Int) {
            let day = byDay ? cal.startOfDay(for: pair.element.effectiveDue).timeIntervalSince1970 : 0
            return (day, pair.element.sortMinutes, pair.offset)
        }
        return items.enumerated().sorted { key($0) < key($1) }.map(\.element)
    }

    /// What the Talk to Kitty panel lists: tasks due that day (done ones included, so they can be undone)
    /// and, separately, everything still open from before.
    func panel(_ f: PanelFilter) -> (overdue: [TaskItem], due: [TaskItem]) {
        let cal = Calendar.current
        let today = cal.startOfDay(for: .now)
        let target = f.day == .tomorrow ? (cal.date(byAdding: .day, value: 1, to: today) ?? today) : today
        let names = f.who.names.map { $0.lowercased() }

        let mine = tasks.filter { t in
            if let pid = f.profileID {
                if t.profileID != pid { return false }
            } else if t.isListItem && f.day != .all {
                return false                        // list items are not due today or tomorrow
            }
            if !names.isEmpty, !names.contains(t.effectiveAssignee.lowercased()) { return false }
            if let c = f.category, t.effectiveCategory != c { return false }
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
        let names = choice.names.map { $0.lowercased() }
        return tasks.filter { !$0.isDone && (names.isEmpty || names.contains($0.effectiveAssignee.lowercased())) }.count
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
                    slot: DaySlot? = nil, timeMinutes: Int? = nil) -> Routine? {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        var r = Routine(title: clean, category: category ?? .guess(from: clean),
                        weekdays: Array(Set(recurrence.weekdays.filter { (1...7).contains($0) })).sorted(),
                        assignee: assignee.map(Assignee.normalize).flatMap { $0.isEmpty ? nil : $0 })
        r.everyNWeeks = recurrence.everyNWeeks > 1 ? recurrence.everyNWeeks : nil
        r.intervalDays = (recurrence.intervalDays ?? 1) > 1 ? recurrence.intervalDays : nil
        r.dayOfMonth = recurrence.dayOfMonth.map { min(max($0, 1), 31) }
        if r.intervalDays != nil || r.dayOfMonth != nil { r.weekdays = []; r.everyNWeeks = nil }
        r.startDate = Calendar.current.startOfDay(for: .now)
        r.slot = slot
        r.timeMinutes = timeMinutes
        if routines.contains(where: { $0.title.lowercased() == clean.lowercased() && $0.scheduleText == r.scheduleText }) { return nil }
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
                fresh.append(TaskItem(title: r.title, category: r.category, dueDate: day, routineID: r.id, assignee: r.effectiveAssignee,
                                      slot: r.slot, timeMinutes: r.timeMinutes))
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

    /// Categories already in use (newest first), then the built-in ones, at most 12. The model is told these.
    var knownCategoryNames: [String] {
        var out: [String] = []
        func add(_ n: String) {
            if out.count < 12, !out.contains(where: { $0.lowercased() == n.lowercased() }) { out.append(n) }
        }
        for t in tasks { if let n = t.categoryName { add(n) } }
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

    // MARK: Lists (profiles)

    static let genericListWords: Set<String> = ["order", "list", "cart", "basket", "shopping", "checklist", "wishlist", "profile"]

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
    func ensureProfile(_ raw: String) -> (profile: TaskProfile, created: Bool) {
        if let existing = profile(named: raw) { return (existing, false) }
        let name = Self.cleanProfileName(raw)
        let p = TaskProfile(name: name.isEmpty ? "List" : name)
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
            var item = TaskItem(title: title, category: .guess(from: title), dueDate: due.map { Calendar.current.startOfDay(for: $0) },
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
            TaskItem(title: $0.title, category: pb.category ?? .guess(from: pb.name), dueDate: due, group: pb.name, assignee: $0.assignee)
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

    func rename(_ id: UUID, to title: String) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[i].title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        save()
    }

    func complete(_ id: UUID) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[i].isDone = true
        save()
    }

    func reopen(_ id: UUID) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[i].isDone = false
        save()
    }

    func toggle(_ id: UUID) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[i].isDone.toggle()
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

    @discardableResult
    func clearCompleted() -> Int {
        let count = tasks.filter(\.isDone).count
        tasks.removeAll { $0.isDone }
        save()
        return count
    }

    // MARK: Persistence

    private func save() {
        if let data = try? JSONEncoder().encode(tasks) {
            UserDefaults.standard.set(data, forKey: key)
        }    }

    private func persistExtras() {
        let d = UserDefaults.standard
        if let data = try? JSONEncoder().encode(routines) { d.set(data, forKey: routinesKey) }
        if let data = try? JSONEncoder().encode(playbooks) { d.set(data, forKey: playbooksKey) }
        if let data = try? JSONEncoder().encode(profiles) { d.set(data, forKey: profilesKey) }
        d.set(profiles.map(\.name), forKey: KittyGuideStore.profileNamesKey)      // so the guide can tell the model
        d.set(Array(materialized), forKey: materializedKey)
    }

    private func load() {
        let d = UserDefaults.standard
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
