import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - v30: bulk creation, slot-filling clarification, one-shot confirmation
//
// Extends the hybrid design in Agent.swift (the app gates, the model decides, Swift validates). Nothing here replaces it:
//  - BulkDetector        (Swift) spots lists, "add these tasks", routine lists and playbooks before the model is called
//  - BulkAgentDecision   (model) returns an array of drafts for those utterances
//  - BulkValidator       (Swift) checks every draft, resolves dates from the calendar, drops anything invented
//  - BulkDraftManager    holds pending tasks, routines and playbook steps so they can be edited item by item
//  - ClarificationStateManager  asks one required slot at a time, never repeats, stops after three rounds
//  - ConfirmationManager makes "yes" execute the pending action exactly once
//  - SaveSink            where saved objects go (the real TaskStore in the app, memory in evals)

// MARK: Small text helpers

enum Words {
    static func trim(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The one small normaliser: lower case, letters and digits only. Two titles with the same key are the same title.
    static func key(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }

    /// The words of a sentence, lower case, without punctuation.
    static func tokens(_ text: String) -> [String] {
        text.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "…", with: " ")
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" })
            .map(String.init)
    }

    static func stem(_ w: String) -> String {
        var s = w
        if s.hasSuffix("ies"), s.count > 4 { s = String(s.dropLast(3)) + "y" }
        else if s.hasSuffix("s"), !s.hasSuffix("ss"), s.count > 3 { s.removeLast() }
        return s
    }

    /// "a, b, and c"
    static func list(_ parts: [String]) -> String {
        switch parts.count {
        case 0: return ""
        case 1: return parts[0]
        case 2: return parts[0] + " and " + parts[1]
        default: return parts.dropLast().joined(separator: ", ") + ", and " + (parts.last ?? "")
        }
    }

    static func number(_ n: Int) -> String {
        let names = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten"]
        return n >= 0 && n < names.count ? names[n] : String(n)
    }

    static func plural(_ n: Int, _ one: String, _ many: String? = nil) -> String {
        "\(n) " + (n == 1 ? one : (many ?? one + "s"))
    }
}

enum Rx {
    /// Capture groups of the first match (index 0 is the whole match). nil when there is no match.
    static func groups(_ pattern: String, in text: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = text as NSString
        guard let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (0..<m.numberOfRanges).map { i in
            m.range(at: i).location == NSNotFound ? "" : ns.substring(with: m.range(at: i))
        }
    }
}

// MARK: - Draft values (plain Swift, so the validator and the evals do not depend on iOS 26)

struct TaskDraftValue: Equatable {
    var title = ""
    var reason = ""
    var category = ""
    var dueDate = ""
    var dueTime = ""                  // HH:mm
    var timeOfDay = ""                // morning, afternoon, evening, night or anytime
    var priority = ""
    var assignee = ""
    var notes = ""
    var heardAs = ""                  // the transcript words the model says this task comes from
    /// Filled only when the speaker asked for this same item more than once (the words, as said). Swift checks that it is not empty
    /// and nothing more: such an item is kept next to an identical one instead of being combined with it (also when it joins a draft that waits).
    var distinctBecause = ""
}

struct RoutineDraftValue: Equatable {
    var title = ""
    var reason = ""
    var category = ""
    var frequency = ""                // once, daily, weekly, monthly or custom
    var schedule = ""                 // the repeat in the speaker's words: kept as heard, shown, and kept in the notes if it cannot be read
    var weekdays: [Int] = []          // 1 = Sunday ... 7 = Saturday (the calendar's numbering)
    var everyNWeeks = 0               // 2 = every other week; 0 = not given
    var intervalDays = 0              // 2 = every other day; 0 = not given
    var dayOfMonth = 0                // monthly; 0 = not given
    var dueTime = ""                  // HH:mm
    var timeOfDay = ""                // morning, afternoon, evening, night or anytime
    var assignee = ""
    var notes = ""
    var heardAs = ""
    var distinctBecause = ""
}

extension RoutineDraftValue {
    /// A routine on named weekdays, for tests and scripted engines: `weekly(["Water Plants"], days: [1, 2])`.
    static func weekly(_ title: String, days: [Int], schedule: String = "", category: String = "", everyNWeeks: Int = 0) -> RoutineDraftValue {
        RoutineDraftValue(title: title, category: category, frequency: "weekly", schedule: schedule, weekdays: days, everyNWeeks: everyNWeeks)
    }
    static func daily(_ title: String, schedule: String = "every day", category: String = "", timeOfDay: String = "") -> RoutineDraftValue {
        RoutineDraftValue(title: title, category: category, frequency: "daily", schedule: schedule, timeOfDay: timeOfDay)
    }
}

struct PlaybookDraftValue: Equatable {
    var name = ""
    var dueDate = ""
    var assignee = ""
    var steps: [TaskDraftValue] = []
}

/// A repeat as the model gives it for an edit: structured numbers, plus the words as said. Swift reads the numbers (ranges only);
/// it never parses the words.
struct RepeatValue: Equatable {
    var frequency = ""                // once, daily, weekly, monthly or custom
    var weekdays: [Int] = []
    var everyNWeeks = 0
    var intervalDays = 0
    var dayOfMonth = 0
    var words = ""
}

/// A proposed change to a task that already exists. The task is named by the id a search tool returned, never by words.
struct OperationValue: Equatable {
    var op = ""                       // complete, reopen, delete, update, assign, reschedule or rename
    var taskID = ""                   // the short id from a tool result
    var changes: TaskDraftValue? = nil
}

/// The one thing the model returns for every turn: the tasks, routines or playbook it found, proposed changes to existing tasks,
/// an answer built from tool results, a question, or "unfinished".
struct BulkDecisionValue: Equatable {
    var wait = false
    var action = ""
    var tasks: [TaskDraftValue] = []
    var routines: [RoutineDraftValue] = []
    var playbook: PlaybookDraftValue? = nil
    var operations: [OperationValue] = []
    var answer = ""                               // unrelated: a short reply
    var query: TaskQueryValue? = nil              // lookup: what to find; Swift runs the search
    var clarifyingQuestion = ""
    /// The list the user named, for the items of this response (the full path). Blank when none.
    var listName = ""
    /// The flat path's answer. When it is set the validator reads this and nothing else.
    var extraction: ExtractionValue? = nil
}

/// What a read-only question about saved tasks needs Swift to look for. The model only fills these in; it never sees the tasks.
struct TaskQueryValue: Equatable {
    var text = ""          // words that appear in the title, notes or category
    var status = ""        // open, done or all (open when empty)
    var day = ""           // today, tomorrow, overdue, any, or an ISO date
    var assignee = ""
    var list = ""         // the name of a list

    var isEmpty: Bool { [text, status, day, assignee, list].allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty } }
    /// "day today | assignee Me", for the trace and the reply.
    var described: String {
        [("words", text), ("status", status), ("day", day), ("assignee", assignee), ("list", list)]
            .compactMap { name, value -> String? in
                let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return v.isEmpty ? nil : "\(name) \(v)"
            }.joined(separator: ", ")
    }
}

#if canImport(FoundationModels)
/// One item the user asked for, as the model writes it. ONE shape for a task and a routine (a routine is an item with `repeating`),
/// so one request has one representation. Every field that is not part of what was said is optional: the model leaves it out, and
/// "omitted" means "not said". No guide carries an example: examples in a schema come back as tasks.
@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
@Generable
struct ItemDraft {
    @Guide(description: "The shortest unbroken run of the user's own words this item comes from, in their order. Never join separate parts of the speech.")
    var heardAs: String
    @Guide(description: "Verb first, Title Case: the action and one specific target. When the user names a list and provides items, create one item per independently completable or purchasable thing. Set listName to the list name. Do not create a task for the list name itself. Do not combine list items into one task unless the user explicitly asks for one combined task.")
    var title: String
    @Guide(description: "Only if the user said why, in their own words. Otherwise omit.")
    var reason: String?
    @Guide(description: "One broad category in Title Case, preferably one of the reference categories. Omit if unsure.")
    var category: String?
    @Guide(description: "ISO date YYYY-MM-DD, only if the user said a day or date (work it out from today's date). Today's date is not a default: otherwise omit.")
    var dueDate: String?
    @Guide(description: "Clock time HH:mm in 24 hours, only if the user said a clock time. Otherwise omit.")
    var time: String?
    @Guide(description: "morning, afternoon, evening, night or anytime, only if the user said when in the day. Otherwise omit.")
    var timeOfDay: String?
    @Guide(description: "low, medium or high, only if the user said it. Otherwise omit.")
    var priority: String?
    @Guide(description: "A person's name, only if the user explicitly says the work is for them. Never infer an assignee from an ingredient, product, brand, place, list name, or descriptive phrase. Otherwise omit.")
    var assignee: String?
    @Guide(description: "Only user-provided execution details or context for this item. Never use notes to hold a requested item that belongs in the items array. Otherwise omit.")
    var notes: String?
    @Guide(description: "Only if the user said this item repeats. Otherwise omit.")
    var repeating: RepeatDraft?
    @Guide(description: "Only if the user asked for this same item more than once: their words. Otherwise omit.")
    var distinctBecause: String?

    var taskValue: TaskDraftValue {
        TaskDraftValue(title: title, reason: reason ?? "", category: category ?? "", dueDate: dueDate ?? "", dueTime: time ?? "",
                       timeOfDay: timeOfDay ?? "", priority: priority ?? "", assignee: assignee ?? "", notes: notes ?? "",
                       heardAs: heardAs, distinctBecause: distinctBecause ?? "")
    }

    /// A routine only when the item repeats: a frequency other than "once". Anything else is a task.
    var routineValue: RoutineDraftValue? {
        guard let rd = repeating else { return nil }
        let r = rd.value
        let f = r.frequency.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !["", "once", "one-time", "none"].contains(f) else { return nil }
        return RoutineDraftValue(title: title, reason: reason ?? "", category: category ?? "", frequency: r.frequency, schedule: r.words,
                                 weekdays: r.weekdays, everyNWeeks: r.everyNWeeks, intervalDays: r.intervalDays, dayOfMonth: r.dayOfMonth,
                                 dueTime: time ?? "", timeOfDay: timeOfDay ?? "", assignee: assignee ?? "", notes: notes ?? "",
                                 heardAs: heardAs, distinctBecause: distinctBecause ?? "")
    }

    func read(into tasks: inout [TaskDraftValue], routines: inout [RoutineDraftValue]) {
        if let r = routineValue { routines.append(r) } else { tasks.append(taskValue) }
    }
}

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
@Generable
struct PlaybookDraft {
    @Guide(description: "Playbook name in Title Case, under five words.")
    var name: String
    @Guide(description: "ISO date YYYY-MM-DD, only if a day was said. Otherwise omit.")
    var dueDate: String?
    @Guide(description: "A person's name, only if said. Otherwise omit.")
    var assignee: String?
    @Guide(description: "Ordered steps, each verb first in Title Case.")
    var steps: [ItemDraft]

    var value: PlaybookDraftValue {
        PlaybookDraftValue(name: name, dueDate: dueDate ?? "", assignee: assignee ?? "", steps: steps.map(\.taskValue))
    }
}

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
@Generable
struct RepeatDraft {
    @Guide(description: "once (not repeating), daily, weekly, monthly or custom")
    var frequency: String
    @Guide(description: "Weekly: the days as numbers, 1 = Sunday to 7 = Saturday. Empty otherwise.")
    var weekdays: [Int]
    @Guide(description: "2 for every other week, 3 for every third week. 0 if not said.")
    var everyNWeeks: Int
    @Guide(description: "Custom: days between repeats, 2 for every other day. 0 if not said.")
    var intervalDays: Int
    @Guide(description: "Monthly: the day of the month, 1 to 31. 0 if not said.")
    var dayOfMonth: Int
    @Guide(description: "The repeat exactly as the user said it.")
    var words: String

    var value: RepeatValue {
        RepeatValue(frequency: frequency, weekdays: weekdays, everyNWeeks: everyNWeeks, intervalDays: intervalDays,
                    dayOfMonth: dayOfMonth, words: words)
    }
}

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
@Generable
struct TaskOperation {
    @Guide(description: "What to do to the existing task.", .anyOf(["complete", "reopen", "delete", "update"]))
    var op: String
    @Guide(description: "The id of the task, exactly as a search tool returned it.")
    var taskID: String
    @Guide(description: "update only: just the fields to change (leave the title empty when it does not change). Otherwise omit.")
    var changes: ItemDraft?

    var value: OperationValue { OperationValue(op: op, taskID: taskID, changes: changes?.taskValue) }
}

/// The parameters of a read-only lookup. The model never sees the saved tasks: it says what to look for, Swift searches.
@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
@Generable
struct TaskQueryDraft {
    @Guide(description: "Words that appear in the title, notes or category of the tasks wanted. Omit if none.")
    var text: String?
    @Guide(description: "open, done or all. Omit for open.")
    var status: String?
    @Guide(description: "today, tomorrow, overdue, any, or an ISO date YYYY-MM-DD. Omit if no day was said.")
    var day: String?
    @Guide(description: "A person's name, only to see that person's tasks. Omit otherwise.")
    var assignee: String?
    @Guide(description: "The name of a list, only to see that list's tasks. Omit otherwise.")
    var list: String?

    var value: TaskQueryValue {
        TaskQueryValue(text: text ?? "", status: status ?? "", day: day ?? "", assignee: assignee ?? "", list: list ?? "")
    }
}

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
@Generable
struct BulkAgentDecision {
    @Guide(description: "True only when the speech is unfinished and nothing can be extracted yet.")
    var wait: Bool

    @Guide(description: "create (new items or a playbook), operate (change existing tasks), lookup (a question about saved tasks: fill query, nothing else), clarify (one essential detail is missing), or unrelated.",
           .anyOf(["create", "operate", "lookup", "clarify", "unrelated"]))
    var action: String

    @Guide(description: "The user-named list that groups the returned items. Omit for standalone tasks.")
    var listName: String?

    @Guide(description: "create: each thing the user asked for, once. Independent actions are separate items; the same request is never written twice.")
    var items: [ItemDraft]

    @Guide(description: "A playbook, only when the user described one. Otherwise omit.")
    var playbook: PlaybookDraft?

    @Guide(description: "operate only: the proposed changes to existing tasks, by the id of a task listed in RECENT TASKS. Empty for every other action: never invent an id.")
    var operations: [TaskOperation]

    @Guide(description: "A short reply only when action is unrelated. Must be empty for create, operate, lookup, and clarify.")
    var answer: String

    @Guide(description: "lookup only: what to look for. The tasks are never shown to you; the app searches. Otherwise omit.")
    var query: TaskQueryDraft?

    @Guide(description: "clarify: one short, specific question about the single missing detail. Otherwise empty.")
    var clarifyingQuestion: String

    var value: BulkDecisionValue {
        var tasks: [TaskDraftValue] = [], routines: [RoutineDraftValue] = []
        for i in items { i.read(into: &tasks, routines: &routines) }
        return BulkDecisionValue(wait: wait, action: action, tasks: tasks, routines: routines,
                                 playbook: playbook?.value, operations: operations.map(\.value), answer: answer, query: query?.value,
                                 clarifyingQuestion: clarifyingQuestion, listName: listName ?? "")
    }
}
#endif

// MARK: - Drafts that wait to be saved

struct DraftItem: Identifiable, Equatable {
    enum Kind: String { case task, routine }
    var id = UUID()
    var ref = ""                          // "d1", "d2" ...: how the model names this item in a follow-up. Stamped once, never reused.
    var kind: Kind = .task
    var title: String
    var categoryName: String? = nil
    var due: Date? = nil
    var timeMinutes: Int? = nil
    var priority: String? = nil
    var assignee: String? = nil
    var notes: String? = nil
    var reason: String? = nil
    var utteranceID: UUID? = nil
    var recurrence: RecurrenceSpec? = nil
    var listName: String? = nil           // the list the user named (flat path); made on approval, never at draft time
    var instructions: String? = nil       // quantity, dosage, method: what the user said about how
    var schedule: String? = nil           // the repeat as said (kept even when Swift read it)
    var softDue: String? = nil            // a timeframe that is not a day ("next week"), as said
    var slot: DaySlot? = nil              // the time of day the model gave (nil: none given)
    var heardAs: String? = nil            // the words the model says this task comes from: the MODEL's quote, never shown as the user's speech
    /// The model gave a quote and it is not word for word in the transcript. A flag for review, not a verdict on the task: the item
    /// stays in the draft and in the save proposal. A quote that does match is no proof that the task is right either.
    var quoteUnverified = false
    /// The user explicitly said to include this flagged item (voice yes, or Include in the edit sheet).
    var reviewed = false
    /// Where this item came from and what last changed it, newest last. The review prompt shows only the latest entry.
    var history: [Provenance] = []
    /// One thing that happened to an item: the numbered line of the conversation, what happened, and the words it came from.
    struct Provenance: Equatable {
        var line: Int
        var kind: String            // created, renamed or edited
        var words: String
    }
    /// A field the model gave that Swift could not read, kept as given so the user can correct it ("repeat": "when I remember").
    /// The card flags it. If it is still there at Save, the item is saved as a one-time task with these words in its notes.
    var unparsed: [String: String] = [:]
    /// Gentle notes for the card ("Same title as another item"). Never block or remove anything.
    var advisories: [String] = []
    /// The user's words that justified each value (attribute to words), or "added by you" for a hand edit. A value with no entry here
    /// was not stored: `EvidenceGate` clears it.
    var evidence: [String: String] = [:]
    /// The model said the speaker asked for this same item more than once (`distinctBecause`). Such an item is never folded into an
    /// identical one already on the draft. Only the older answer format can say it; a flat answer never sets it.
    var distinct = false

    init(_ v: ValidatedTask, kind: Kind) {
        self.kind = kind
        title = v.title
        categoryName = v.categoryName
        due = v.due
        timeMinutes = v.timeMinutes
        priority = v.priority
        assignee = v.assignee
        notes = v.notes
        reason = v.reason
        utteranceID = v.utteranceID
        slot = v.slot
        heardAs = v.heardAs
        recurrence = kind == .routine ? v.recurrence : nil
        listName = v.listName
        instructions = v.instructions
        schedule = v.schedule
        softDue = v.softDue
    }

    init(title: String, kind: Kind = .task) { self.title = title; self.kind = kind }

    var validated: ValidatedTask {
        ValidatedTask(title: title, categoryName: categoryName, due: due, timeMinutes: timeMinutes, priority: priority,
                      assignee: assignee, notes: notes, recurrence: kind == .routine ? recurrence : nil,
                      reason: reason, utteranceID: utteranceID, slot: slot, heardAs: heardAs,
                      listName: listName, instructions: instructions, schedule: schedule, softDue: softDue)
    }

    private static func readsAsDay(_ raw: String) -> Bool {
        if case .day = DateResolver.read(raw) { return true }
        return false
    }

    func planned() -> PlannedTask {
        var p = validated.planned()
        p.evidence = evidence
        // A day that was written where a repeat goes ("2026-10-30") is not a repeat Swift failed to read: no system text in the notes.
        if let raw = unparsed["repeat"], !raw.isEmpty, !Self.readsAsDay(raw) {
            p.notes = [p.notes, "Repeat not understood: \(raw)"].compactMap { $0 }.joined(separator: " · ")
        }
        return p
    }
    var key: String { Words.key(title) }
    /// What makes two items look the same: the title, and for a routine also its repeat. Only used for an advisory note.
    var identity: String {
        guard kind == .routine, let r = recurrence else { return key }
        return key + "|" + r.scheduleText.lowercased()
    }
    var needsFix: Bool { !unparsed.isEmpty }
}

/// What a saved task or routine is known by when a new item is compared with it: the title and the fields that tell two things
/// with the same title apart.
struct SavedKey: Equatable {
    var title: String                 // `Words.key` of the title
    var due: Date? = nil
    var assignee: String? = nil
    var schedule: String? = nil       // the repeat, for a routine
    var category: String? = nil
}

@MainActor
extension TaskStore {
    /// The open tasks and the routines, as keys for the saved-match check.
    var savedKeys: [SavedKey] {
        let one = tasks.filter { !$0.isDone && $0.routineID == nil }.map {
            SavedKey(title: Words.key($0.title), due: $0.dueDate, assignee: $0.assignee, category: $0.categoryName)
        }
        let repeating = routines.map {
            SavedKey(title: Words.key($0.title), assignee: $0.assignee, schedule: $0.scheduleText, category: $0.category?.label)
        }
        return one + repeating
    }
}

struct PlaybookDraftState: Equatable {
    var name: String
    var due: Date? = nil
    var assignee: String? = nil
    var steps: [DraftItem]
    var stated = false
}

/// The person, day and time the user said once for the tasks of a dictation ("house help tasks for tomorrow"), as said. Swift checked
/// each one before it was kept (`ScopeReader`), and it is cleared with the draft. It only fills a field a new task leaves empty.
struct DraftScope: Equatable {
    var assignee: String? = nil
    var day: String? = nil
    var time: String? = nil

    var isEmpty: Bool { assignee == nil && day == nil && time == nil }

    /// Each field the other one states replaces this one's; the rest stay.
    func merged(with other: DraftScope) -> DraftScope {
        DraftScope(assignee: other.assignee ?? assignee, day: other.day ?? day, time: other.time ?? time)
    }

    /// For the trace and for the prompt's STATE block.
    var lines: [String] {
        var out: [String] = []
        if let assignee { out.append("person: \(assignee)") }
        if let day { out.append("day: \(day)") }
        if let time { out.append("time: \(time)") }
        return out
    }
}

/// One piece of the dictation, as the draft recorded it: the new words and what became of them.
struct HeardChunk: Equatable {
    enum Status: String { case accepted, discarded, uncovered }
    var words: String
    var status: Status
    /// Content words of the chunk that no task, person, day, list or scope covers.
    var uncovered: [String] = []
    /// Words the recogniser was not sure of.
    var lowConfidence: [String] = []
}

/// Holds the pending tasks, routines and playbook steps while the user corrects them. Every change bumps `version`: an approval
/// is only valid for the version the user saw. The version moves only when the draft really changed, and once per change: a
/// pass over many items works on a copy and is assigned back in one step.
final class BulkDraftManager {
    private(set) var items: [DraftItem] = [] { didSet { if oldValue != items { version += 1 } } }
    private(set) var playbook: PlaybookDraftState? { didSet { if oldValue != playbook { version += 1 } } }
    /// Changes with every edit of the draft. A Save carries the version it was shown with.
    private(set) var version = 0
    /// The person, day and time said once for the draft's tasks. A change to it moves the version, like any change to the draft.
    private(set) var scope: DraftScope? { didSet { if oldValue != scope { version += 1 } } }
    /// What each piece of the dictation became, in order. Cleared with the draft; not part of what a Save approves.
    private(set) var chunks: [HeardChunk] = []
    func setScope(_ new: DraftScope?) { scope = (new?.isEmpty ?? true) ? nil : new }
    func noteChunk(_ chunk: HeardChunk) { chunks.append(chunk) }
    private var refCounter = 0

    var hasContent: Bool { !items.isEmpty || playbook != nil }
    var summaryLine: String {
        if let p = playbook { return "playbook \(p.name): " + p.steps.map(\.title).joined(separator: "; ") }
        return items.map(\.title).joined(separator: "; ")
    }

    /// The items in the order the card shows them (overdue first, then morning to night). The prompt lists them in this order too.
    var ordered: [DraftItem] { TaskSorting.ordered(items) }

    private func stamped(_ item: DraftItem) -> DraftItem {
        var i = item
        if i.ref.isEmpty { refCounter += 1; i.ref = "d\(refCounter)" }
        return i
    }

    /// Long turns: what the tasks came from, and what was heard but left out (offered back as "Skipped (N)").
    private(set) var used: String?
    private(set) var skipped: [String] = []
    func setContext(used: String?, skipped: [String]) { self.used = used; self.skipped = skipped }

    /// The raw words of the turn that made this draft, kept as heard. They become one `Utterance` only when Save is confirmed.
    /// Words that grow while the user keeps talking replace the earlier piece; a later piece (a correction) is added.
    private(set) var spoken: [String] = []
    var spokenText: String { spoken.joined(separator: " ") }

    func noteSpoken(_ text: String) {
        let t = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !t.isEmpty else { return }
        func norm(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber || $0 == " " } }
        if let last = spoken.last {
            if norm(t).hasPrefix(norm(last)) { spoken[spoken.count - 1] = t; return }
            if norm(last).hasPrefix(norm(t)) { return }
            // The recogniser settled the same request a little differently: a piece that mostly overlaps the last one replaces it
            // (when it is as long), so the original request is kept once. A short correction shares too few words to count.
            let a = norm(last).split(separator: " ").map(String.init), b = norm(t).split(separator: " ").map(String.init)
            let (small, big) = a.count <= b.count ? (a, b) : (b, a)
            if small.count >= 3 {
                var pool = big, hit = 0
                for w in small { if let i = pool.firstIndex(of: w) { pool.remove(at: i); hit += 1 } }
                if Double(hit) >= 0.7 * Double(small.count) {
                    if b.count >= a.count { spoken[spoken.count - 1] = t }
                    return
                }
            }
        }
        spoken.append(t)
    }

    /// The first flagged item the user has not yet decided on (quote unverified, not explicitly included). Nil when there is none.
    var unresolvedFlag: DraftItem? { ordered.first { $0.quoteUnverified && !$0.reviewed } }

    /// The user said to include a flagged item. It stays in the draft; the version moves, so an earlier approval cannot save it.
    @discardableResult
    func markReviewed(id: UUID) -> Bool {
        guard var i = item(id: id) else { return false }
        i.reviewed = true
        return update(i)
    }

    func clear() { items = []; playbook = nil; used = nil; skipped = []; spoken = []; scope = nil; chunks = [] }
    func setItems(_ new: [DraftItem]) { items = new.map(stamped); playbook = nil }

    /// The draft is wrong as a whole and the model gave the complete right list: it replaces everything on the draft, hand edits
    /// included. The change says what was added and removed.
    @discardableResult
    func replaceAll(_ new: [DraftItem]) -> Change {
        var change = Change()
        let before = items
        var fresh: [DraftItem] = []
        for var n in new {
            if let old = before.first(where: { $0.identity == n.identity }) {
                n.ref = old.ref; n.id = old.id
                if n != old { change.updated.append(n.title) }
            } else if !before.contains(where: { $0.key == n.key }) {
                change.added.append(n.title)
            } else if let old = before.first(where: { $0.key == n.key }) {
                n.ref = old.ref; n.id = old.id
                change.updated.append(n.title)
            }
            fresh.append(stamped(n))
        }
        for old in before where !fresh.contains(where: { $0.ref == old.ref }) { change.removed.append(old.title) }
        items = fresh
        playbook = nil
        return change
    }
    func setPlaybook(_ p: PlaybookDraftState?) { playbook = p; if p != nil { items = []; scope = nil } }

    /// Gives a due date to the drafts that still have none (matched by key). Returns how many were tagged.
    @discardableResult
    func applyDue(_ date: Date, toKeys keys: Set<String>) -> Int {
        var n = 0
        var working = items
        for i in working.indices where keys.contains(working[i].key) && working[i].due == nil && working[i].kind == .task {
            working[i].due = date
            n += 1
        }
        if n > 0 { items = working }
        return n
    }

    /// The note on an item that an exact copy of it was folded into.
    static let alreadyNote = "Already on the list"

    /// The item in `list` that is the same request as `item`, if there is one. Same request: the same kind, title, person, day, time and
    /// timeframe (and, for a routine, repeat), and no field that both set and that differs: list, instructions, purpose, category,
    /// priority, notes and time of day are compared only when both sides have one. What the model fills freely and differently from one
    /// answer to the next (`schedule` on a task, `unparsed`) is not compared. An item the model marked as asked for more than once has no
    /// match. A near match (the same title for someone else, or on another day) is not a match.
    static func existing(matching item: DraftItem, in list: [DraftItem]) -> Int? {
        guard !item.distinct else { return nil }
        return list.firstIndex { sameRequest($0, item) }
    }

    private static func sameRequest(_ a: DraftItem, _ b: DraftItem) -> Bool {
        func key(_ s: String?) -> String { s.map { Words.key($0) } ?? "" }
        func agree(_ x: String?, _ y: String?) -> Bool { let p = key(x), q = key(y); return p.isEmpty || q.isEmpty || p == q }
        guard a.kind == b.kind, a.key == b.key, key(a.assignee) == key(b.assignee), a.due == b.due,
              a.timeMinutes == b.timeMinutes, key(a.softDue) == key(b.softDue) else { return false }
        if a.kind == .routine, (a.recurrence?.scheduleText.lowercased() ?? "") != (b.recurrence?.scheduleText.lowercased() ?? "") { return false }
        if let x = a.slot, let y = b.slot, x != y { return false }
        return agree(a.listName, b.listName) && agree(a.instructions, b.instructions) && agree(a.reason, b.reason)
            && agree(a.categoryName, b.categoryName) && agree(a.priority, b.priority) && agree(a.notes, b.notes)
    }

    /// An exact copy arrived: the item already there stays as it is (same ref, same id), takes what it had left empty from the copy, and
    /// says so, once.
    private static func fold(into item: inout DraftItem, from copy: DraftItem) {
        func empty(_ s: String?) -> Bool { Words.trim(s ?? "").isEmpty }
        if empty(item.listName) { item.listName = copy.listName }
        if empty(item.instructions) { item.instructions = copy.instructions }
        if empty(item.reason) { item.reason = copy.reason }
        if empty(item.categoryName) { item.categoryName = copy.categoryName }
        if empty(item.priority) { item.priority = copy.priority }
        if empty(item.notes) { item.notes = copy.notes }
        if item.slot == nil { item.slot = copy.slot }
        if !item.advisories.contains(alreadyNote) { item.advisories.append(alreadyNote) }
    }

    /// What was said about the items that were folded into ones already on the draft ("Already had clean the baby mat.").
    static func alreadyHad(_ titles: [String]) -> String? {
        titles.isEmpty ? nil : "Already had \(Words.list(titles.map { $0.lowercased() }))."
    }

    /// New items that arrived while the draft waits join it. An exact copy of an item already there (not one the model marked as asked
    /// for more than once) is not added: it is folded into that item, which carries a note, and that item is returned in `merged` so the
    /// card can say so. A near copy (another person, day, time or list) is a row of its own, and the card says it looks like another.
    func join(_ new: [DraftItem]) -> (added: [DraftItem], merged: [DraftItem]) {
        var working = items
        var added: [DraftItem] = [], merged: [DraftItem] = []
        for n in new {
            if let k = Self.existing(matching: n, in: working) {
                Self.fold(into: &working[k], from: n)
                merged.append(working[k])
            } else {
                let s = stamped(n)
                working.append(s)
                added.append(s)
            }
        }
        items = working
        return (added, merged)
    }

    /// The items that were added by `join`.
    @discardableResult
    func append(contentsOf new: [DraftItem]) -> [DraftItem] { join(new).added }

    // MARK: Changes from the screen and from the review

    /// Whether these words are something Kitty heard and left out as chatter (offered back as "Skipped (N)").
    func isSkipped(_ text: String) -> Bool { skipped.contains { Self.sameWords($0, text) } }

    func item(id: UUID) -> DraftItem? { items.first { $0.id == id } }
    func item(ref: String) -> DraftItem? {
        let r = ref.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return items.first { $0.ref == r }
    }

    /// One item changed by hand. False if it is gone.
    @discardableResult
    func update(_ item: DraftItem) -> Bool {
        guard let i = items.firstIndex(where: { $0.id == item.id }) else { return false }
        items[i] = item
        return true
    }

    /// One item deleted by hand. True if something is left.
    @discardableResult
    func remove(id: UUID) -> Bool {
        items.removeAll { $0.id == id }
        return !items.isEmpty
    }

    /// An item added by hand. An exact copy of one already there is folded into it, like new items from speech. Returns its title when that
    /// happened (a different day, person, time or list makes it a row of its own).
    @discardableResult
    func append(_ item: DraftItem) -> String? { join([item]).merged.first?.title }

    /// The fields an edit may empty, in the names the apply step reads. Anything else in `clear` is not a field.
    static let clearable: Set<String> = ["day", "date", "due", "duedate", "time", "clock", "duetime", "timeofday", "slot", "daypart",
                                         "priority", "person", "assignee", "for", "who", "purpose", "reason", "instructions", "category", "categories",
                                         "tags", "tag", "repeat", "repeats", "recurrence", "schedule", "list", "listname", "timeframe", "softdue"]
    static func clearName(_ s: String) -> String { s.lowercased().filter { $0.isLetter } }

    /// An edit that sets a field and clears the same field says two things at once.
    static func contradicts(_ op: DraftEditOpValue) -> Bool {
        for field in op.clear {
            switch clearName(field) {
            case "day", "date", "due", "duedate": if !op.day.isEmpty || op.patch?.sets.contains("day") == true { return true }
            case "time", "clock", "duetime": if !op.time.isEmpty || op.patch?.sets.contains("time") == true { return true }
            case "timeofday", "slot", "daypart": if !op.timeOfDay.isEmpty { return true }
            case "priority": if !op.priority.isEmpty { return true }
            case "person", "assignee", "for", "who": if !op.person.isEmpty { return true }
            case "purpose", "reason": if !op.purpose.isEmpty { return true }
            case "instructions": if !op.instructions.isEmpty { return true }
            case "repeat", "repeats", "recurrence", "schedule": if op.repeating != nil || op.patch?.sets.contains("repeat") == true { return true }
            case "list", "listname": if !op.listName.isEmpty { return true }
            default: break
            }
        }
        return false
    }

    /// What a review changed, for the line on the card.
    struct Change: Equatable {
        var added: [String] = []
        var removed: [String] = []
        var updated: [String] = []
        /// One sentence for a change that reached many items at once ("Cleared tags on 4 items.") instead of listing each one.
        var notes: [String] = []
        /// The refs of the items that were changed or removed, for the conversation log ("them" in the next turn).
        var touched: [String] = []
        var ignored = 0                 // edits that named an item that is not on the list
        /// Edits Swift refused because they contradict themselves (a field set and cleared at once). The draft is left as it was.
        var warnings: [String] = []
        var isEmpty: Bool { added.isEmpty && removed.isEmpty && updated.isEmpty && notes.isEmpty && warnings.isEmpty }
        /// What was applied to the draft, without the warnings: this is what the conversation log keeps.
        var appliedText: String {
            var parts: [String] = []
            if !added.isEmpty { parts.append("Added \(Words.list(added.map { $0.lowercased() })).") }
            if !removed.isEmpty { parts.append("Removed \(Words.list(removed.map { $0.lowercased() })).") }
            if !updated.isEmpty { parts.append("Updated \(Words.list(updated.map { $0.lowercased() })).") }
            parts.append(contentsOf: notes)
            return parts.joined(separator: " ")
        }
        var text: String {
            var parts: [String] = []
            if !added.isEmpty { parts.append("Added \(Words.list(added.map { $0.lowercased() })).") }
            if !removed.isEmpty { parts.append("Removed \(Words.list(removed.map { $0.lowercased() })).") }
            if !updated.isEmpty { parts.append("Updated \(Words.list(updated.map { $0.lowercased() })).") }
            parts.append(contentsOf: notes)
            parts.append(contentsOf: warnings)
            return parts.joined(separator: " ")
        }
    }

    /// A person, day, time or list said once for the draft ("I said, Househelp tasks for tomorrow") with no new task. It fills what an item
    /// leaves empty and replaces nothing an item already has; the scope keeps it for the next words. One change, one version step.
    func applyHeader(_ r: DraftHeader.Reading, now: Date, calendar: Calendar, line: Int = 0, words: String = "") -> Change {
        var change = Change()
        var items = self.items
        for n in items.indices {
            var changed = false
            if let a = r.assignee, Words.key(items[n].assignee ?? "").isEmpty { items[n].assignee = a; changed = true }
            if let d = r.day, items[n].kind == .task, items[n].due == nil, items[n].softDue == nil {
                switch DateResolver.read(d, now: now, calendar: calendar) {
                case .day(let date): items[n].due = date; changed = true
                case .soft(let said): items[n].softDue = said; changed = true
                case .invalid: break
                }
            }
            if let t = r.time, items[n].timeMinutes == nil, items[n].slot == nil {
                switch TimeResolver.read(t) {
                case .minutes(let m): items[n].timeMinutes = m; changed = true
                case .slot(let slot): items[n].slot = slot; changed = true
                case .invalid: break
                }
            }
            if let l = r.list, items[n].kind == .task, Words.key(items[n].listName ?? "").isEmpty { items[n].listName = l; changed = true }
            if changed {
                items[n].history.append(DraftItem.Provenance(line: line, kind: "edited", words: words))
                change.touched.append(items[n].ref)
            }
        }
        self.items = items
        setScope((scope ?? DraftScope()).merged(with: r.scope))
        let many = change.touched.count
        change.notes.append(many == 0 ? "The tasks are already for \(Words.list(r.parts))."
                            : "Set \(Words.list(r.parts)) for \(many == items.count ? "the" : "\(many)") task\(many == 1 && items.count != 1 ? "" : "s").")
        return change
    }

    /// The model returned only what changes: edits by item ref ("d2", as the prompt listed them) and new tasks. An edit names one
    /// ref, several (`refs`) or the whole list (`all`): Swift applies it to each, so "remove all the tags" is one edit and cannot be
    /// forgotten for the fifth item. Every item keeps its id and every field the edit does not mention (what was said or typed
    /// earlier survives); `clear` empties a field and `remove` drops the item. A ref that is not on the draft is ignored. A repeat
    /// that cannot be read is kept on the item as given and flagged. A change that reached many items is one sentence, not a list.
    func apply(edits: [DraftEditOpValue], add: [DraftItem], context ctx: ValidationContext, line: Int = 0, words: String = "") -> Change {
        var change = Change()
        var gone = Set<UUID>()
        var retitled: [(old: String, new: String)] = []
        // Every change below is made on this copy and assigned to the draft once at the end, so the draft's version moves once
        // (and not at all when nothing changed), however many fields and items the edits touched.
        var items = self.items

        func note(_ title: String, in list: inout [String]) {
            if !list.contains(where: { Words.key($0) == Words.key(title) }) { list.append(title) }
        }
        func fieldName(_ s: String) -> String { s.lowercased().filter { $0.isLetter } }
        func clearsTags(_ op: DraftEditOpValue) -> Bool {
            let names = Set(op.clear.map(fieldName))
            return names.contains("tags")
        }
        /// "tags", or the fields in the words of the card: "day and time".
        func clearedText(_ op: DraftEditOpValue) -> String {
            if clearsTags(op) {
                let rest = op.clear.filter { !["tags", "category", "categories"].contains(fieldName($0)) }
                return Words.list(["tags"] + rest.map { $0.lowercased() })
            }
            return Words.list(op.clear.map { $0.lowercased() })
        }
        func noteTouched(_ ref: String) { if !change.touched.contains(ref) { change.touched.append(ref) } }

        func contradicts(_ op: DraftEditOpValue) -> Bool { Self.contradicts(op) }

        for op in edits {
            // A removal drops the item whole: whatever else the entry carries is moot, so it cannot contradict itself.
            if !op.remove, contradicts(op) {
                change.ignored += 1
                change.warnings.append("I skipped one change that set and cleared the same thing.")
                Trace.step("WARNING", "a draft edit both sets and clears a field (\(op.clear.joined(separator: ", "))): it was not applied and the draft is unchanged by it")
                continue
            }
            var targets: [String] = []
            if op.all {
                targets = items.map(\.ref)
            } else {
                for raw in [op.ref] + op.refs {
                    let r = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                    if !r.isEmpty, !targets.contains(r) { targets.append(r) }
                }
            }
            guard !targets.isEmpty else { change.ignored += 1; continue }
            var changed: [String] = []          // titles of the items this edit changed
            let onlyClears = !op.setsAnything && !op.remove && !op.clear.isEmpty

            for ref in targets {
                guard let i = items.firstIndex(where: { $0.ref == ref }) else { change.ignored += 1; continue }
                guard !gone.contains(items[i].id) else { continue }
                if op.remove {
                    gone.insert(items[i].id)
                    note(items[i].title, in: &change.removed)
                    noteTouched(ref)
                    continue
                }
                let before = items[i]
                for field in op.clear {
                    switch fieldName(field) {
                    case "day", "date", "due", "duedate": items[i].due = nil
                    case "time", "clock", "duetime": items[i].timeMinutes = nil
                    case "timeofday", "slot", "daypart": items[i].slot = nil
                    case "priority": items[i].priority = nil
                    case "person", "assignee", "for", "who": items[i].assignee = nil
                    case "purpose", "reason": items[i].reason = nil
                    case "instructions": items[i].instructions = nil
                    case "category", "categories": items[i].categoryName = nil
                    case "tags", "tag": items[i].categoryName = nil
                    case "repeat", "repeats", "recurrence", "schedule": items[i].kind = .task; items[i].recurrence = nil; items[i].schedule = nil; items[i].unparsed["repeat"] = nil
                    case "list", "listname": items[i].listName = nil
                    case "timeframe", "softdue": items[i].softDue = nil
                    default: break
                    }
                }
                let title = op.title.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
                if !title.isEmpty { items[i].title = title }
                if items[i].title != before.title { retitled.append((before.title, items[i].title)) }

                if let r = op.repeating {
                    switch BulkValidator.reading(r) {
                    case .spec(let spec):
                        items[i].kind = .routine
                        items[i].recurrence = spec
                        items[i].due = nil
                        items[i].unparsed["repeat"] = nil
                    case .once:
                        items[i].kind = .task
                        items[i].recurrence = nil
                        items[i].unparsed["repeat"] = nil
                    case .unreadable:
                        // Kept as given, flagged on the card, and nothing is guessed from it.
                        items[i].unparsed["repeat"] = Words.trim(r.words).isEmpty ? "repeat" : Words.trim(r.words)
                    case .none:
                        break
                    }
                }
                if let patch = op.patch { Self.apply(patch, to: &items[i]) }
                if let l = TaskDraftMapper.clean(op.listName) { items[i].listName = l }
                if items[i].kind == .task, let d = BulkValidator.date(op.day, calendar: ctx.calendar) { items[i].due = d }
                if let m = DaySlot.parseHHmm(op.time) { items[i].timeMinutes = m }
                if let s = BulkValidator.slot(op.timeOfDay) { items[i].slot = s }
                if let p = BulkValidator.priority(op.priority) { items[i].priority = p }
                let who = Assignee.normalize(op.person)
                if !who.isEmpty { items[i].assignee = who }
                if let why = TaskDraftMapper.clean(op.purpose) { items[i].reason = why }
                if let how = TaskDraftMapper.clean(op.instructions) { items[i].instructions = how }
                if items[i] != before {
                    items[i].history.append(DraftItem.Provenance(line: line, kind: items[i].title != before.title ? "renamed" : "edited", words: words))
                    changed.append(items[i].title); noteTouched(ref)
                }
            }
            // Many items changed in the same way: one sentence ("Cleared tags on 4 items."), not four titles.
            if changed.count > 1 && (op.all || targets.count > 1) {
                let n = changed.count
                if onlyClears { change.notes.append("Cleared \(clearedText(op)) on \(n) items.") }
                else { change.notes.append("Updated \(n) items.") }
            } else {
                for t in changed { note(t, in: &change.updated) }
            }
        }
        items.removeAll { gone.contains($0.id) }

        // One item retitled and others removed in the same answer is how the existing actions combine items. The card says so in one
        // line. Swift only sees the shape of the edits, not what was meant: nothing else about the change differs.
        if retitled.count == 1, !change.removed.isEmpty, change.updated.count <= 1 {
            let names = ([retitled[0].old] + change.removed).map { $0.lowercased() }
            change.notes.append("Combined \(Words.list(names)) into \(retitled[0].new.lowercased()).")
            change.removed = []
            change.updated = []
        }

        // An added item that is an exact copy of one on the list (as it is after the edits above) is folded into it, with a note.
        var already: [String] = []
        for n in add {
            if let k = Self.existing(matching: n, in: items) {
                Self.fold(into: &items[k], from: n)
                already.append(n.title)
                noteTouched(items[k].ref)
                continue
            }
            var item = stamped(n)
            item.history.append(DraftItem.Provenance(line: line, kind: "created", words: n.heardAs ?? words))
            items.append(item)
            change.added.append(n.title)
            noteTouched(item.ref)
        }
        if let said = Self.alreadyHad(already) { change.notes.append(said) }
        self.items = items
        return change
    }

    /// The same words, ignoring case, punctuation and "the/a/an".
    private static func sameWords(_ a: String, _ b: String) -> Bool {
        func key(_ s: String) -> [String] { Words.tokens(s).filter { !["the", "a", "an"].contains($0) } }
        let x = key(a), y = key(b)
        return !x.isEmpty && x == y
    }

    // MARK: Playbook steps by hand

    /// A step added, renamed or removed from the screen. The playbook is otherwise changed by a fresh model answer.
    func setSteps(_ steps: [DraftItem]) {
        guard var pb = playbook else { return }
        pb.steps = steps
        playbook = pb
    }
}

// MARK: - Which slot is missing, what was asked, how many rounds

enum ConversationPhase: String, Equatable {
    case idle, listening, pendingTask, pendingRoutine, pendingPlaybook, pendingBulkDraft, awaitingClarification, awaitingConfirmation

    var holdsDraft: Bool {
        switch self {
        case .pendingTask, .pendingRoutine, .pendingPlaybook, .pendingBulkDraft, .awaitingConfirmation: return true
        default: return false
        }
    }
}

enum MissingField: String, Equatable {
    case action, object, target, schedule, oneTimeOrRoutine, steps, change, validation
}

final class ClarificationStateManager {
    static let maxRounds = 3

    private(set) var missing: MissingField?
    private(set) var previousQuestions: [String] = []
    private(set) var answers: [(question: String, answer: String)] = []
    private(set) var rounds = 0
    private(set) var lastQuestion: String?
    /// The whole story of this loop, sent to the model on every call while it lasts (see `ClarificationDossier`).
    private(set) var dossier = ClarificationDossier()

    enum Verdict: Equatable {
        case ask(String)            // ask this one question
        case exhausted              // three rounds used: propose the best interpretation instead
    }

    func reset() {
        missing = nil
        previousQuestions = []
        answers = []
        rounds = 0
        lastQuestion = nil
        reshown = []
        dossier = ClarificationDossier()
    }

    /// The request as it is now, until the first question is asked. After that the first words are kept as they were.
    func noteTurn(_ utterance: String) { dossier.noteOriginal(utterance) }

    /// The answer to the open question. Said again or extended (the user kept talking), it replaces the earlier wording.
    func recordAnswer(_ answer: String) {
        guard let q = lastQuestion else { return }
        if let i = answers.indices.last, answers[i].question == q { answers[i].answer = answer } else { answers.append((q, answer)) }
        dossier.answer(answer)
    }

    /// Registers a question. A repeat of an earlier question is replaced by the fallback for that slot, and if that was
    /// asked too (or three rounds are used) the conversation proposes its best interpretation instead.
    func register(question: String, field: MissingField) -> Verdict {
        if rounds >= Self.maxRounds { return .exhausted }
        var q = question
        if previousQuestions.contains(VoiceTurnManager.norm(q)) {
            q = Self.fallbackQuestion(for: field)
            if previousQuestions.contains(VoiceTurnManager.norm(q)) { return .exhausted }
        }
        previousQuestions.append(VoiceTurnManager.norm(q))
        rounds += 1
        missing = field
        lastQuestion = q
        dossier.ask(question: q, field: field)
        return .ask(q)
    }

    enum ModelQuestionVerdict: Equatable {
        case ask(String)            // a new question: show it
        case again(String)          // asked before and not answered: show the same question once more
        case exhausted              // shown twice already, or three rounds used: stop asking
    }

    /// Questions already shown a second time, so the same one is never shown a third.
    private var reshown: Set<String> = []

    /// Registers a question the model wrote because the words had no task in them. Unlike `register`, a repeat is never replaced by a
    /// Swift sentence: the same question may be shown once more, and after that the caller stops asking.
    func registerModelQuestion(_ question: String, field: MissingField = .action) -> ModelQuestionVerdict {
        let key = VoiceTurnManager.norm(question)
        guard !key.isEmpty else { return .exhausted }
        if previousQuestions.contains(key) {
            guard !reshown.contains(key) else { return .exhausted }
            reshown.insert(key)
            lastQuestion = question
            missing = field
            return .again(question)
        }
        guard rounds < Self.maxRounds else { return .exhausted }
        previousQuestions.append(key)
        rounds += 1
        missing = field
        lastQuestion = question
        dossier.ask(question: question, field: field)
        return .ask(question)
    }

    static func fallbackQuestion(for field: MissingField) -> String {
        switch field {
        case .action: return "What would you like the task to be?"
        case .object: return "What is it for?"
        case .target: return "Which task do you mean?"
        case .schedule: return "How often should it repeat: daily, weekly, or on specific days?"
        case .oneTimeOrRoutine: return "Should this be a one-time task or a repeating routine?"
        case .steps: return "What steps should it include?"
        case .change: return "What would you like to change?"
        case .validation: return "Could you say that another way?"
        }
    }

    static func field(for question: String, action: String) -> MissingField {
        let t = question.lowercased()
        if t.contains("one-time") || t.contains("one time") || (t.contains("routine") && t.contains("or")) { return .oneTimeOrRoutine }
        if action == "create_routine" || action == "create_routines" || t.contains("how often") || t.contains("which day") || t.contains("repeat") {
            return .schedule
        }
        if t.contains("step") || t.contains("playbook") || t.contains("include") { return .steps }
        if t.contains("what would you like to change") || t.contains("what change") { return .change }
        if t.contains("which task") || t.contains("which one") || t.contains("which routine") { return .target }
        if t.contains("what would you like the task") || t.contains("what task") || t.contains("what would you like me to add")
            || t.contains("what should i add") { return .action }
        return .object
    }

    /// Whether this is exactly one question: one sentence that ends in a question mark. Anything else (a recap of what the user wants, a
    /// statement, two sentences) is never stored as the question the user is expected to answer.
    static func isOneQuestion(_ raw: String) -> Bool {
        let q = Words.trim(raw)
        guard q.count > 1, q.hasSuffix("?") else { return false }
        let body = q.dropLast()
        if body.contains("?") || body.contains("!") { return false }
        // A full stop followed by more words ends a sentence before the question does.
        var previous: Character = " "
        for (i, c) in body.enumerated() {
            if previous == ".", c == " ", i + 1 < body.count { return false }
            previous = c
        }
        return true
    }

    /// One short question: the first sentence ending in a question mark.
    static func oneQuestion(_ raw: String) -> String {
        let q = Words.trim(raw)
        guard let r = q.firstIndex(of: "?") else { return q }
        return String(q[...r])
    }
}

// MARK: - Confirmation: yes executes once

final class ConfirmationManager {
    enum Reply: Equatable { case yes, no, cancel, other }

    private(set) var armed: UUID?
    private(set) var executed: Set<UUID> = []

    func arm(_ id: UUID) { armed = id }
    func disarm() { armed = nil }
    /// After a Save that stored nothing: the same approval may be given once more.
    func rearm(_ id: UUID) { executed.remove(id); armed = id }

    /// True exactly once for an armed proposal. A second "yes", or a tap after a "yes", gets false.
    func consume(_ id: UUID) -> Bool {
        guard armed == id, !executed.contains(id) else { return false }
        executed.insert(id)
        armed = nil
        return true
    }

    private static let yes: Set<String> = ["yes", "yeah", "yep", "yup", "sure", "ok", "okay", "add it", "add them", "confirm", "go ahead",
                                           "do it", "thats right", "correct", "please do", "sounds good", "looks good", "perfect",
                                           "done", "save it", "save them", "save", "thats all", "that is all", "thats it", "that is it",
                                           "yes please", "go for it", "save all"]
    private static let yesTail: Set<String> = ["save", "them", "it", "please", "go", "ahead", "do", "thanks", "thank", "you", "confirm",
                                               "thats", "right", "sounds", "good", "looks", "all", "that", "is"]
    private static let cancel: Set<String> = ["cancel", "discard", "never mind", "nevermind", "forget it", "scrap that", "start over",
                                              "stop", "dont save", "dont save it", "dont save them", "do not save", "dont add it",
                                              "dont add them", "cancel that", "cancel it"]
    private static let no: Set<String> = ["no", "nope", "nah", "no thanks", "not yet", "not quite", "not really", "no thank you"]

    static func interpret(_ raw: String) -> Reply {
        let t = VoiceTurnManager.norm(raw)
        if t.isEmpty { return .other }
        if cancel.contains(t) { return .cancel }
        if yes.contains(t) { return .yes }
        if no.contains(t) { return .no }
        let words = t.split(separator: " ").map(String.init)
        if let first = words.first, ["yes", "yeah", "yep", "sure", "ok", "okay"].contains(first),
           words.dropFirst().allSatisfy({ yesTail.contains($0) }) { return .yes }
        return .other
    }
}

// MARK: - Where saved objects go

@MainActor
protocol SaveSink {
    /// Saves one-time tasks. Returns the ids created.
    func saveTasks(_ planned: [PlannedTask]) -> [UUID]
    /// Saves one routine. nil when an identical routine already exists.
    func saveRoutine(_ planned: PlannedTask) -> UUID?
    /// Saves a playbook (and its tasks when it has a due date).
    func savePlaybook(name: String, category: TaskCategory?, steps: [PlaybookStep], due: Date?) -> (replaced: Bool, created: [UUID])
    /// A playbook the user already taught, if this title refers to one.
    func playbook(matching title: String) -> Playbook?
    func addPlaybookTasks(_ playbook: Playbook, due: Date?) -> [UUID]
    /// Keeps the raw words of the turn that is being saved (once, shared by every task made from it). Nil when nothing is kept.
    func recordUtterance(_ rawText: String) -> UUID?
    /// The name of the saved list a list name the user said would join, or nil when it would be a new list. Only for the review card.
    func existingListName(for raw: String) -> String?
    /// Points tasks that were made some other way (playbook steps) at that utterance.
    func link(_ taskIDs: [UUID], to utteranceID: UUID)
    /// After saving: make today's routine copies, classify times of day. Returns extra task ids to show.
    func finishSaving(routineIDs: Set<UUID>) async -> [UUID]
}

extension SaveSink {
    func existingListName(for raw: String) -> String? { nil }
    /// The names of the saved lists (empty for a sink that has none).
    var existingListNames: [String] { [] }
}

@MainActor
struct StoreSaveSink: SaveSink {
    var existingListNames: [String] { TaskStore.shared.profiles.map(\.name) }
    func existingListName(for raw: String) -> String? { TaskStore.shared.profile(named: raw)?.name }

    func saveTasks(_ planned: [PlannedTask]) -> [UUID] {
        Trace.step("SAVED", "\(planned.count) task(s): " + planned.map { Trace.describe(planned: $0) }.joined(separator: "; "))
        return TaskStore.shared.addMany(planned).map(\.id)
    }

    func saveRoutine(_ p: PlannedTask) -> UUID? {
        guard let rec = p.recurrence else { return nil }
        Trace.step("SAVED", "routine: " + Trace.describe(planned: p))
        return TaskStore.shared.addRoutine(title: p.title, category: p.category, recurrence: rec, assignee: p.assignee,
                                           slot: p.slot, timeMinutes: p.timeMinutes, reason: p.reason, utteranceID: p.utteranceID,
                                           instructions: p.instructions, schedule: p.schedule, allowDuplicate: true)?.id        // approved on the card, which already said "You already have this saved"
    }

    func savePlaybook(name: String, category: TaskCategory?, steps: [PlaybookStep], due: Date?) -> (replaced: Bool, created: [UUID]) {
        let store = TaskStore.shared
        let replaced = store.savePlaybook(name: name, category: category, steps: steps)
        var created: [UUID] = []
        if let due, let pb = store.playbook(matching: name, minWords: 1) { created = store.addPlaybookTasks(pb, due: due).map(\.id) }
        return (replaced, created)
    }

    func recordUtterance(_ rawText: String) -> UUID? { UtteranceStore.shared.record(rawText) }
    func link(_ taskIDs: [UUID], to utteranceID: UUID) { TaskStore.shared.link(taskIDs, to: utteranceID) }

    func playbook(matching title: String) -> Playbook? { TaskStore.shared.playbook(matching: title) }
    func addPlaybookTasks(_ pb: Playbook, due: Date?) -> [UUID] { TaskStore.shared.addPlaybookTasks(pb, due: due).map(\.id) }

    func finishSaving(routineIDs: Set<UUID>) async -> [UUID] {
        let store = TaskStore.shared
        store.refreshRoutines()
        // Today's copy of each new routine is the card to show.
        let shown = store.tasks.filter { t in
            guard let rid = t.routineID, routineIDs.contains(rid) else { return false }
            return Calendar.current.isDateInToday(t.effectiveDue)
        }.map(\.id)
        return shown
    }
}

/// Used by the evals: nothing touches the user's real tasks.
@MainActor
final class InMemorySaveSink: SaveSink {
    private(set) var tasks: [PlannedTask] = []
    private(set) var routines: [PlannedTask] = []
    private(set) var playbooks: [(name: String, steps: [PlaybookStep], due: Date?)] = []
    /// What was kept as "the words of the turn", one entry per Save. Always on here: the evals read it.
    private(set) var utterances: [Utterance] = []
    private(set) var links: [(tasks: [UUID], utterance: UUID)] = []

    func recordUtterance(_ rawText: String) -> UUID? {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let u = Utterance(rawText: text)
        utterances.append(u)
        return u.id
    }
    func link(_ taskIDs: [UUID], to utteranceID: UUID) { links.append((taskIDs, utteranceID)) }

    func saveTasks(_ planned: [PlannedTask]) -> [UUID] {
        tasks.append(contentsOf: planned)
        return planned.map { _ in UUID() }
    }

    func saveRoutine(_ p: PlannedTask) -> UUID? {
        // An approved routine is saved even when a saved one has the same title and repeat: the card flagged it before approval.
        routines.append(p)
        return UUID()
    }

    func savePlaybook(name: String, category: TaskCategory?, steps: [PlaybookStep], due: Date?) -> (replaced: Bool, created: [UUID]) {
        let replaced = playbooks.contains { $0.name.lowercased() == name.lowercased() }
        playbooks.removeAll { $0.name.lowercased() == name.lowercased() }
        playbooks.append((name, steps, due))
        return (replaced, due == nil ? [] : steps.map { _ in UUID() })
    }

    func playbook(matching title: String) -> Playbook? { nil }
    func addPlaybookTasks(_ playbook: Playbook, due: Date?) -> [UUID] { [] }
    func finishSaving(routineIDs: Set<UUID>) async -> [UUID] { [] }
}

/// Guards an apply closure so it can run only once, whoever calls it.
final class Once {
    private var fired = false
    func fire() -> Bool { if fired { return false }; fired = true; return true }
    /// Only for a Save that stored nothing: the same approval may run again, and still stores at most once.
    func reset() { fired = false }
}

// MARK: - What Kitty says: summaries and grouped confirmations

enum DraftSummary {
    static func kindText(_ items: [DraftItem]) -> String {
        let tasks = items.filter { $0.kind == .task }.count
        let routines = items.count - tasks
        if routines == 0 { return Words.plural(tasks, "task") }
        if tasks == 0 {
            let daily = items.allSatisfy { ($0.recurrence?.scheduleText ?? "") == "every day" }
            return daily ? "\(routines) daily \(routines == 1 ? "routine" : "routines")" : Words.plural(routines, "routine")
        }
        return Words.plural(tasks, "task") + " and " + Words.plural(routines, "routine")
    }

    /// 2-5 items: name them. More than 5: group by category.
    static func question(for items: [DraftItem]) -> String {
        let named = items.compactMap(\.listName)
        if !named.isEmpty {
            var seen: [String] = []
            for n in named where !seen.contains(where: { TaskLabels.stemKey($0) == TaskLabels.stemKey(n) }) { seen.append(n) }
            if seen.count == 1, named.count == items.count {
                return "I have the list “\(seen[0])” with \(Words.plural(items.count, "task")). Should I save it?"
            }
            return "I have \(Words.plural(items.count, "task")) in \(Words.plural(seen.count, "list")). Should I save them?"
        }
        if items.count <= 5 {
            return "I have \(kindText(items)): \(Words.list(items.map { $0.title.lowercased() })). Should I save these?"
        }
        var order: [String] = []
        var counts: [String: Int] = [:]
        for i in items {
            let c = i.categoryName?.lowercased() ?? "other"
            if counts[c] == nil { order.append(c) }
            counts[c, default: 0] += 1
        }
        let groups = order.map { "\(counts[$0] ?? 0) \($0 == "other" ? "other" : "for \($0)")" }
        return "I have \(kindText(items)): \(Words.list(groups)). Should I save these?"
    }

    static func object(of title: String) -> String {
        let words = title.lowercased().split(separator: " ").map(String.init)
        let rest = words.dropFirst().filter { !["the", "a", "an", "my", "our"].contains($0) }
        return rest.isEmpty ? title.lowercased() : rest.joined(separator: " ")
    }

    static func label(_ i: DraftItem) -> String { i.categoryName?.lowercased() ?? object(of: i.title) }

    /// "Saved 4 tasks: bathroom, groceries, plants, and trash."
    static func saved(tasks: [PlannedTask], routines: [PlannedTask], alreadyHad: Int = 0) -> String {
        func labels(_ p: [PlannedTask]) -> [String] {
            let cats = p.map { ($0.categoryName ?? "").lowercased() }
            let usable = !cats.contains("") && Set(cats).count == cats.count
            return usable ? cats : p.map { object(of: $0.title) }
        }
        if tasks.count == 1, routines.isEmpty { return "Added: \(tasks[0].title)." }
        if routines.count == 1, tasks.isEmpty, let r = routines.first {
            let when = r.recurrence?.scheduleText ?? ""
            if when == "every day" { return "Added a daily routine: \(r.title.lowercased())." }
            let who = r.assignee.map { " for \($0.lowercased())" } ?? ""
            return "Added: \(r.title) \(when)\(who)."
        }
        let both = labels(tasks) + labels(routines)
        var kinds: [String] = []
        if !tasks.isEmpty { kinds.append(Words.plural(tasks.count, "task")) }
        if !routines.isEmpty { kinds.append(Words.plural(routines.count, "routine")) }
        var text = "Saved \(kinds.joined(separator: " and ")): \(Words.list(both))."
        if alreadyHad > 0 { text += " You already had \(alreadyHad)." }
        return text
    }
}

// MARK: - What actually happened when Save ran

/// What the sink really did, so the reply never says more than happened. The version is the draft version the Save was shown with.
struct SaveReport: Equatable {
    var version: Int? = nil
    var savedTaskIDs: [UUID] = []
    var savedRoutineIDs: [UUID] = []
    var alreadyHad = 0
    var notSaved: [String] = []
    /// Nothing was stored although items were approved. The draft is kept and the same approval can be given again.
    var persistenceFailed = false
    var message = ""
    var savedCount: Int { savedTaskIDs.count + savedRoutineIDs.count }
}

// MARK: - Previews and one-time saves for drafts

@MainActor
enum DraftProposals {
    static func tags(_ i: DraftItem) -> [PreviewTag] {
        var tags: [PreviewTag] = []
        if let raw = i.unparsed["repeat"] { tags.append(PreviewTag(text: "Repeat needs a fix: “\(raw)”", icon: "exclamationmark.triangle.fill", color: .orange)) }
        if let raw = i.unparsed["date"] { tags.append(PreviewTag(text: "Day needs a fix: “\(raw)”", icon: "exclamationmark.triangle.fill", color: .orange)) }
        if let raw = i.unparsed["time"] { tags.append(PreviewTag(text: "Time needs a fix: “\(raw)”", icon: "exclamationmark.triangle.fill", color: .orange)) }
        if let r = i.recurrence, i.kind == .routine { tags.append(PreviewTag(text: r.scheduleText, icon: "repeat", color: .purple)) }
        if let d = i.due { tags.append(PreviewTag(text: d.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()), icon: "calendar")) }
        if let soft = i.softDue, i.due == nil { tags.append(PreviewTag(text: soft, icon: "calendar.badge.clock")) }
        if let m = i.timeMinutes { tags.append(PreviewTag(text: DaySlot.clockLabel(m), icon: "clock", color: .indigo))
        } else if let s = i.slot { tags.append(PreviewTag(text: s.label, icon: s.symbol, color: .indigo)) }
        if let a = i.assignee { tags.append(PreviewTag(text: a, icon: "person.fill", color: .person(a))) }
        if let c = i.categoryName { tags.append(PreviewTag(text: c, icon: "tag.fill", isLabel: true)) }
        if let p = i.priority { tags.append(PreviewTag(text: p.capitalized + " priority", icon: "flag.fill", color: p == "high" ? .red : .orange)) }
        if let r = i.reason { tags.append(PreviewTag(text: r, icon: "target")) }
        if let h = i.instructions { tags.append(PreviewTag(text: h, icon: "text.alignleft")) }
        // The model's quote. A quote that is not word for word in the transcript is never shown as the user's speech: the row says it
        // is unverified (the quote and the original words are in the edit sheet). A quote that matches proves nothing about the task.
        if i.quoteUnverified {
            tags.append(PreviewTag(text: i.reviewed ? "Quote unverified, included" : "Quote unverified", icon: "questionmark.circle", color: .orange))
        } else if let h = i.heardAs { tags.append(PreviewTag(text: "“\(h)”", icon: "quote.bubble")) }
        for a in i.advisories { tags.append(PreviewTag(text: a, icon: "info.circle", color: .orange)) }
        return tags
    }

    /// The rows grouped by the list each task names, in the order the lists were first said; tasks that name none go together, last.
    /// Empty when no task names a list (the card is then flat, as it always was). Lists are only named here: made when approved.
    static func sections(_ items: [DraftItem], rows: [PreviewRow], sink: SaveSink) -> [PreviewSection] {
        guard items.contains(where: { $0.listName != nil }) else { return [] }
        var order: [String] = []
        var names: [String: String] = [:]
        var grouped: [String: [PreviewRow]] = [:]
        var loose: [PreviewRow] = []
        for (item, row) in zip(items, rows) {
            guard let name = item.listName else { loose.append(row); continue }
            let key = TaskLabels.stemKey(name)
            if names[key] == nil { names[key] = name; order.append(key) }
            grouped[key, default: []].append(row)
        }
        var out: [PreviewSection] = order.map { key in
            let name = names[key] ?? ""
            let list = grouped[key] ?? []
            let count = Words.plural(list.count, "task")
            let existing = sink.existingListName(for: name)
            return PreviewSection(listName: name, icon: TaskProfile.symbol(for: name),
                                  subtitle: existing.map { "Adding to your \($0) list · \(count)" } ?? "New list · \(count)",
                                  isNew: existing == nil, rows: list)
        }
        if !loose.isEmpty {
            out.append(PreviewSection(listName: nil, icon: "circle", subtitle: "\(Words.plural(loose.count, "task")), no list", isNew: false, rows: loose))
        }
        return out
    }

    /// "Save list" for one list, "Save 13 tasks in 2 lists" for several; nil when no task names a list.
    static func sectionsTitle(_ items: [DraftItem], sections: [PreviewSection]) -> String? {
        let lists = sections.filter { $0.listName != nil }
        guard !lists.isEmpty else { return nil }
        if lists.count == 1, sections.count == 1 { return "Save list" }
        return "Save \(Words.plural(items.count, "task")) in \(Words.plural(lists.count, "list"))"
    }

    /// Tasks and routines: always an explicit Save or "yes", never a countdown.
    static func bulk(_ drafts: [DraftItem], question: String? = nil, ack: String? = nil, used: String? = nil,
                     skipped: [String] = [], spoken: String? = nil, version: Int? = nil, sink: SaveSink) -> Proposal {
        var items = TaskSorting.ordered(drafts)         // overdue first, then morning to night, then by time
        // An exact copy never reaches here (it was folded into the item it copies). Items that only look alike (the same title for
        // someone else, or on another day) are both kept; the card says so, and the user decides.
        for n in items.indices where items.enumerated().contains(where: { $0.offset != n && $0.element.identity == items[n].identity }) {
            let note = "Looks like another item"
            if !items[n].advisories.contains(note) { items[n].advisories.append(note) }
        }
        // Every row shows only what was said: a person, day or category the user did not say is not filled in and not shown.
        let rows = items.map { item in
            PreviewRow(icon: item.kind == .routine ? "repeat" : "circle", title: item.title,
                       // The card shows what was given, flagged repeats and advice too.
                       tags: tags(item), draftID: item.id,
                       // The orange tag already says a repeat that could not be read, and the tags say the day, timeframe and person.
                       details: TaskDetailLines.lines(for: item, shownAsTag: [.forWhom, .around]).filter { line in
                           !line.isFlag && !(line.kind == .repeats && Words.key(line.value) == Words.key(item.recurrence?.scheduleText ?? "")) })
        }
        let prompt = question ?? DraftSummary.question(for: items)
        let sections = sections(items, rows: rows, sink: sink)
        let once = Once()
        let taskDrafts = items.filter { $0.kind == .task }
        let routineDrafts = items.filter { $0.kind == .routine }
        var p = Proposal(
            title: sectionsTitle(items, sections: sections) ?? (items.count == 1 ? "Save “\(items[0].title)”" : "Save \(DraftSummary.kindText(items))"),
            rows: rows,
            sections: sections,
            notes: [],
            confirmLabel: "Save",
            pendingTitle: items.first?.title,
            apply: {
                guard once.fire() else { return AgentReply(message: "Already saved.", didAdd: false) }
                // One Utterance for the whole turn, written now and never for an abandoned draft; every task and routine points to it.
                let utteranceID = spoken.flatMap { sink.recordUtterance($0) }
                func stamped(_ d: DraftItem) -> PlannedTask { var p = d.planned(); p.utteranceID = utteranceID; return p }
                let tasks = taskDrafts.map(stamped)
                let routines = routineDrafts.map(stamped)
                var report = SaveReport(version: version)
                report.savedTaskIDs = sink.saveTasks(tasks)
                var routineIDs = Set<UUID>()
                var savedRoutines: [PlannedTask] = []
                for r in routines {
                    if let id = sink.saveRoutine(r) { routineIDs.insert(id); savedRoutines.append(r); report.savedRoutineIDs.append(id) } else { report.alreadyHad += 1 }
                }
                if report.savedTaskIDs.count < tasks.count {
                    report.notSaved = Array(taskDrafts.dropFirst(report.savedTaskIDs.count)).map(\.title)
                }
                // Success is reported only after storing succeeded. Nothing stored for approved items: say so, keep the draft, and let
                // the same approval run again (it still stores at most once).
                if !(tasks.isEmpty && routines.isEmpty), report.savedCount == 0, report.alreadyHad == 0 {
                    once.reset()
                    report.persistenceFailed = true
                    report.message = "I couldn't save that, so nothing was saved. The list is still here: say yes or tap Save to try again."
                    return AgentReply(message: report.message, didAdd: false, didChange: false, report: report)
                }
                let shown = await sink.finishSaving(routineIDs: routineIDs)
                let savedTasks = Array(tasks.prefix(report.savedTaskIDs.count))
                report.message = (savedTasks.isEmpty && savedRoutines.isEmpty)
                    ? (report.alreadyHad > 0 ? "You already have \(report.alreadyHad == 1 ? "that" : "those")." : "I couldn't save that.")
                    : DraftSummary.saved(tasks: savedTasks, routines: savedRoutines, alreadyHad: report.alreadyHad)
                if !report.notSaved.isEmpty { report.message += " I couldn't save: \(Words.list(report.notSaved.map { $0.lowercased() }))." }
                return AgentReply(message: report.message, didAdd: !savedTasks.isEmpty || !savedRoutines.isEmpty, didChange: true,
                                  created: report.savedTaskIDs + shown, report: report)
            })
        p.draftVersion = version
        p.prompt = (ack.map { $0 + " " } ?? "") + (ack == nil ? prompt : "Should I save these?")
        // A flagged item nobody has decided on: one targeted question about the first of them, in place of the save prompt. The card
        // still lists every item and Save still saves everything shown, flagged items included.
        if question == nil, let flagged = items.first(where: { $0.quoteUnverified && !$0.reviewed }) {
            p.flagQuestionItemID = flagged.id
            p.prompt = (ack.map { $0 + " " } ?? "") + "Should I include ‘\(flagged.title)’?"
        }
        p.used = used
        p.skipped = skipped
        return p
    }

    static func playbook(_ pb: PlaybookDraftState, ack: String? = nil, spoken: String? = nil, sink: SaveSink) -> Proposal {
        let rows = pb.steps.enumerated().map { i, s in PreviewRow(icon: "\(min(i + 1, 50)).circle", title: s.title, tags: s.assignee.map { [PreviewTag(text: $0, icon: "person.fill", color: .person($0))] } ?? []) }
        var notes: [String] = []
        if !pb.stated { notes.append("These steps are my suggestion. Say “yes” to keep them, or tell me what to change.") }
        let once = Once()
        let steps = pb.steps.map { PlaybookStep(title: $0.title, assignee: $0.assignee) }
        let name = pb.name, due = pb.due
        var p = Proposal(
            title: "Save the \(pb.name) playbook",
            rows: rows,
            notes: notes,
            confirmLabel: "Save",
            pendingPlaybook: pb.name,
            apply: {
                guard once.fire() else { return AgentReply(message: "Already saved.", didAdd: false) }
                let result = sink.savePlaybook(name: name, category: nil, steps: steps, due: due)
                if let id = spoken.flatMap({ sink.recordUtterance($0) }), !result.created.isEmpty { sink.link(result.created, to: id) }
                let when = due.map { " for " + $0.formatted(.dateTime.weekday(.wide)) } ?? ""
                return AgentReply(message: "\(result.replaced ? "Updated" : "Saved") the \(name) playbook with \(Words.number(steps.count)) \(steps.count == 1 ? "step" : "steps")\(when).",
                                  didAdd: !result.created.isEmpty, didChange: true, created: result.created)
            })
        let list = Words.list(pb.steps.map { $0.title.lowercased() })
        p.prompt = ack.map { $0 + " Should I save the playbook?" }
            ?? (pb.stated ? "Should I save the \(pb.name) playbook with these steps?" : "Should I include these steps: \(list)?")
        return p
    }
}

// MARK: - Decoding the model's answer

/// An existing task to change, named by the id a tool returned.
struct ValidatedOperation: Equatable {
    var kind: BulkValidator.OperationKind
    var taskID: String
    var changes: ValidatedTask?       // update only: the fields to change; an empty title means no rename
    /// The change came from the flat edit call: it may also carry purpose, instructions, part of the day, timeframe, list and cleared
    /// fields, which are applied and checked too.
    var extended = false
}

enum BulkValidated: Equatable {
    case wait
    case clarify(String)
    case unrelated(String)
    case items([DraftItem])
    case playbook(PlaybookDraftState)
    case operations([ValidatedOperation])
    case lookup(TaskQueryValue)       // a read-only question: Swift searches with these parameters
    case clarifyWithItems(String, [DraftItem])   // flat path: the tasks that were understood, shown with the one question that is still open
    case noContent                    // every task named said nothing about a task: no card, the model is asked for one question
}

/// The model's answer, decoded and nothing more. The model's list is accepted as it is: Swift turns an ISO date into a date,
/// HH:mm into minutes, the time-of-day word into a slot, an empty string into nil. Whether the list is right is for the preview, the
/// edit sheet and "nothing saves until Save" to settle.
enum BulkValidator {
    private static let isoDay: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static func text(_ s: String) -> String? {
        let t = s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// "2026-10-26" as that day in the user's calendar. Anything else is nil.
    static func date(_ value: String, calendar: Calendar) -> Date? {
        guard let v = text(value) else { return nil }
        isoDay.calendar = calendar
        isoDay.timeZone = calendar.timeZone
        guard let d = isoDay.date(from: String(v.prefix(10))) else { return nil }
        return calendar.startOfDay(for: d)
    }

    static func priority(_ value: String) -> String? {
        let v = value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return ["low", "medium", "high"].contains(v) ? v : nil
    }

    static func slot(_ value: String) -> DaySlot? {
        DaySlot(rawValue: value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The category in the household's own spelling when it already has it, else as given.
    private static func category(_ value: String, known: [String]) -> String? {
        guard let v = text(value) else { return nil }
        return known.first { Words.key($0) == Words.key(v) } ?? v
    }

    private static func task(_ d: TaskDraftValue, ctx: ValidationContext) -> ValidatedTask? {
        guard let title = text(d.title) else { return nil }
        let cat = category(d.category, known: ctx.knownCategories)
        return ValidatedTask(
            title: title,
            categoryName: cat,
            due: date(d.dueDate, calendar: ctx.calendar),
            timeMinutes: DaySlot.parseHHmm(d.dueTime),
            priority: priority(d.priority),
            assignee: text(d.assignee).map(Assignee.normalize).flatMap { $0.isEmpty ? nil : $0 },
            notes: text(d.notes),
            reason: text(d.reason),
            slot: slot(d.timeOfDay),
            heardAs: text(d.heardAs))
    }

    /// How a repeat reads: a real recurrence, "not repeating", nothing given, or numbers that do not make sense (kept as given).
    enum RepeatReading: Equatable { case spec(RecurrenceSpec), once, none, unreadable }

    /// Reads the structured repeat. Only ranges are checked; the words are never parsed.
    static func reading(frequency: String, weekdays: [Int], everyNWeeks: Int, intervalDays: Int, dayOfMonth: Int) -> RepeatReading {
        let freq = frequency.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let days = Array(Set(weekdays)).sorted()
        if days.contains(where: { !(1...7).contains($0) }) || everyNWeeks < 0 || everyNWeeks > 52
            || intervalDays < 0 || intervalDays > 365 || dayOfMonth < 0 || dayOfMonth > 31 { return .unreadable }
        if freq == "once" || freq == "one-time" || freq == "none" { return .once }
        // A repeat is ONE pattern: a day of the month, a gap of days, or weekdays. Two at once contradict each other, so nothing
        // is guessed from them: the repeat is kept as given and flagged for a fix.
        if [dayOfMonth > 0, intervalDays > 1, !days.isEmpty].filter({ $0 }).count > 1 { return .unreadable }
        if dayOfMonth > 0 { return .spec(RecurrenceSpec(dayOfMonth: dayOfMonth)) }
        if intervalDays > 1 { return .spec(RecurrenceSpec(intervalDays: intervalDays)) }
        if !days.isEmpty { return .spec(RecurrenceSpec(weekdays: days, everyNWeeks: max(1, everyNWeeks))) }
        if freq == "daily" || freq == "every day" || intervalDays == 1 { return .spec(RecurrenceSpec()) }
        if freq.isEmpty && everyNWeeks == 0 && intervalDays == 0 { return .none }
        return .unreadable
    }

    static func reading(_ r: RepeatValue) -> RepeatReading {
        reading(frequency: r.frequency, weekdays: r.weekdays, everyNWeeks: r.everyNWeeks, intervalDays: r.intervalDays, dayOfMonth: r.dayOfMonth)
    }

    /// A routine when the repeat reads; otherwise a one-time task that keeps the repeat as given and is flagged for a fix.
    private static func routine(_ d: RoutineDraftValue, ctx: ValidationContext) -> DraftItem? {
        guard let v = task(TaskDraftValue(title: d.title, reason: d.reason, category: d.category, dueTime: d.dueTime,
                                          timeOfDay: d.timeOfDay, assignee: d.assignee, notes: d.notes,
                                          heardAs: d.heardAs), ctx: ctx) else { return nil }
        let r = reading(frequency: d.frequency, weekdays: d.weekdays, everyNWeeks: d.everyNWeeks, intervalDays: d.intervalDays, dayOfMonth: d.dayOfMonth)
        switch r {
        case .spec(let spec):
            var routine = v
            routine.recurrence = spec
            return DraftItem(routine, kind: .routine)
        case .once:
            return DraftItem(v, kind: .task)
        case .none, .unreadable:
            var item = DraftItem(v, kind: .task)
            item.unparsed["repeat"] = text(d.schedule) ?? text(d.frequency) ?? "repeat"
            return item
        }
    }

    /// An action the app can do to an existing task, by id.
    enum OperationKind: String, Equatable { case complete, reopen, delete, update }

    private static func operationKind(_ raw: String) -> OperationKind? {
        switch raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) {
        case "complete", "complete_task", "done", "finish": return .complete
        case "reopen", "reopen_task": return .reopen
        case "delete", "delete_task", "remove": return .delete
        case "update", "update_task", "assign", "reschedule", "rename": return .update
        default: return nil
        }
    }

    private static func operation(_ o: OperationValue, ctx: ValidationContext) -> ValidatedOperation? {
        guard let kind = operationKind(o.op), let id = text(o.taskID) else { return nil }
        guard kind == .update else { return ValidatedOperation(kind: kind, taskID: id, changes: nil) }
        guard let c = o.changes, let v = task(TaskDraftValue(title: c.title.isEmpty ? "change" : c.title, reason: c.reason, category: c.category,
                                                              dueDate: c.dueDate, dueTime: c.dueTime, timeOfDay: c.timeOfDay,
                                                              priority: c.priority, assignee: c.assignee, notes: c.notes), ctx: ctx) else { return nil }
        var changes = v
        if text(c.title) == nil { changes.title = "" }
        let any = !changes.title.isEmpty || changes.priority != nil || changes.assignee != nil || changes.due != nil || changes.timeMinutes != nil
            || changes.notes != nil || changes.categoryName != nil || (changes.slot ?? .anytime) != .anytime
        return any ? ValidatedOperation(kind: kind, taskID: id, changes: changes) : nil
    }

    /// Letters and digits only, lower case, single spaces: the form in which a quote is compared with the transcript.
    static func quoteForm(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber || $0 == " " || $0.isWhitespace }
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Whether the quote an item carries is word for word in the transcript. A structural check: no stemming, no overlap, no meaning.
    static func quoteIsInTranscript(_ quote: String?, transcript: String) -> Bool {
        guard let quote, !quoteForm(quote).isEmpty else { return false }
        return quoteForm(transcript).contains(quoteForm(quote))
    }

    /// Flags (never removes) items whose quote (`heardAs`) is not word for word in what the speaker said. Every item is returned, in
    /// order, whether one, several or all of the quotes fail: "quote unverified" is a request to review, not a verdict that the task
    /// is wrong. An item with no quote makes no claim and is not flagged. A quote that does match proves nothing about whether the
    /// task is right, so a match changes nothing on the item. Nothing here retries the model.
    static func flagQuotes(_ items: [DraftItem], transcript: String) -> [DraftItem] {
        items.map { item in
            var i = item
            guard !quoteForm(item.heardAs ?? "").isEmpty, !quoteIsInTranscript(item.heardAs, transcript: transcript) else { return i }
            i.quoteUnverified = true
            Trace.step("WARNING", "\(i.title): its quote \"\(item.heardAs ?? "")\" is not in the transcript word for word: quote unverified, the task stays in the draft for review")
            return i
        }
    }

    /// The parts of an item that make it the same request as another: everything except where the model says it came from.
    private static func payload(_ i: DraftItem) -> String {
        [i.kind.rawValue, i.key, i.categoryName.map(Words.key) ?? "", i.due.map { String($0.timeIntervalSince1970) } ?? "",
         i.timeMinutes.map(String.init) ?? "", i.priority ?? "", i.assignee.map(Words.key) ?? "", Words.key(i.notes ?? ""),
         i.recurrence?.scheduleText.lowercased() ?? "",
         i.slot?.rawValue ?? "", i.unparsed["repeat"] ?? ""].joined(separator: "|")
    }

    /// An item the saved list already has: the same title and the same day, person, repeat and category. Title alone is not enough.
    static func matches(_ i: DraftItem, _ s: SavedKey, calendar: Calendar) -> Bool {
        guard s.title == i.key else { return false }
        func day(_ d: Date?) -> Date? { d.map { calendar.startOfDay(for: $0) } }
        func same(_ a: String?, _ b: String?) -> Bool { (a.map(Words.key) ?? "") == (b.map(Words.key) ?? "") }
        return day(i.due) == day(s.due) && same(i.assignee, s.assignee) && same(i.categoryName, s.category)
            && (i.recurrence?.scheduleText.lowercased() ?? "") == (s.schedule?.lowercased() ?? "")
    }

    /// The model's action word, in the app's own few words. The old names still read.
    static func normalizedAction(_ raw: String) -> String {
        let a = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        switch a {
        case "create", "create_tasks", "create_task", "create_routines", "create_routine", "create_playbook", "playbook", "teach_playbook": return "create"
        case "operate", "update_task", "complete_task", "delete_task", "update", "complete", "delete": return "operate"
        case "lookup", "answer", "view_tasks", "view", "search", "find": return "lookup"
        case "clarify", "wait", "unrelated", "": return a
        default: return "other"
        }
    }

    /// Reads the model's answer into drafts the app can show. Checks only: a supported action, the fields it needs, values that parse
    /// (an ISO date, HH:mm, a repeat in range), and references that exist. Nothing is dropped because it looks like something else (an exact copy of an item already on a waiting draft is folded into it, `join`), and
    /// a field that cannot be read is kept as given and flagged, never invented or silently discarded.
    static func decode(_ d: BulkDecisionValue, context ctx: ValidationContext) -> BulkValidated {
        if let e = d.extraction { return decodeFlat(e, context: ctx) }
        let action = normalizedAction(d.action)

        if action == "clarify" {
            let q = ClarificationStateManager.oneQuestion(d.clarifyingQuestion)
            return .clarify(q.isEmpty ? "What would you like me to add?" : q)
        }
        if action == "unrelated" { return .unrelated(Words.trim(d.answer)) }

        // Proposed changes to existing tasks, by id. Only when the model said operate: operations written beside a create are ignored.
        if action == "operate" {
            let ops = d.operations.compactMap { operation($0, ctx: ctx) }
            if ops.isEmpty { return .clarify(d.operations.isEmpty ? "Which task do you mean?" : "What would you like to change?") }
            return .operations(ops)
        }
        if action == "lookup" {
            guard let q = d.query, !q.isEmpty else { return .clarify("What would you like to see?") }
            return .lookup(q)
        }
        if !d.operations.isEmpty { Trace.step("SWIFT", "the model also wrote \(d.operations.count) change(s) to saved tasks beside \"\(d.action)\": ignored") }

        // Anything that creates: tasks, routines or a playbook.
        if let p = d.playbook, text(p.name) != nil || !p.steps.isEmpty, d.tasks.isEmpty, d.routines.isEmpty {
            var seen = Set<String>()
            let steps = p.steps.compactMap { task($0, ctx: ctx) }.filter { seen.insert(Words.key($0.title)).inserted }
            guard let name = text(p.name) else { return .clarify("What should I call the playbook?") }
            guard !steps.isEmpty else { return .clarify("What steps should it include?") }
            return .playbook(PlaybookDraftState(
                name: name, due: date(p.dueDate, calendar: ctx.calendar), assignee: text(p.assignee).map(Assignee.normalize),
                steps: steps.prefix(12).map { DraftItem($0, kind: .task) }, stated: true))
        }

        if let p = d.playbook, text(p.name) != nil || !p.steps.isEmpty {
            Trace.step("WARNING", "the model also gave a playbook (\"\(p.name)\") beside tasks: the playbook is ignored, the raw answer is in the trace")
        }

        // One request is one item. Items whose payload is identical are combined into the first (the raw answer stays in the trace
        // and the card says so); an item the model marked as a distinct occurrence is kept. Items that differ in any field are
        // never combined, and titles are never compared for meaning.
        var items: [DraftItem] = []
        var firstIndex: [String: Int] = [:]
        var copies: [String: Int] = [:]
        func take(_ item: DraftItem, distinct: Bool) {
            var item = item
            item.distinct = distinct
            let key = payload(item)
            if !distinct, firstIndex[key] != nil {
                copies[key, default: 1] += 1
                return
            }
            if firstIndex[key] == nil { firstIndex[key] = items.count }
            items.append(item)
        }
        // One list applies to the items of one response. It is a grouping name only: made on approval, never from a category.
        let list = text(d.listName)
        if !Words.trim(d.answer).isEmpty, action == "create" {
            Trace.step("WARNING", "the model wrote an answer (\"\(Words.trim(d.answer))\") beside a create: ignored, the app controls what is said")
        }
        for t in d.tasks { if let v = task(t, ctx: ctx) { var i = DraftItem(v, kind: .task); if i.listName == nil { i.listName = list }; take(i, distinct: text(t.distinctBecause) != nil) } }
        for r in d.routines { if var i = routine(r, ctx: ctx) { if i.listName == nil { i.listName = list }; take(i, distinct: text(r.distinctBecause) != nil) } }
        Trace.step("SWIFT", "read the model's answer: \(items.count) item(s)")
        for (key, count) in copies {
            guard let n = firstIndex[key] else { continue }
            items[n].advisories.append("Combined \(count) identical items")
            Trace.step("WARNING", "\(count) generated items were identical (\"\(items[n].title)\"): combined into one; the raw answer in the trace keeps all of them")
        }

        guard !items.isEmpty else {
            if d.wait || action == "wait" { return .wait }
            if action == "create" { return .clarify("What would you like me to add?") }
            if action == "other" { return .clarify("I can't do that yet. What would you like me to add or change?") }
            return .clarify("Sorry, I didn't catch that. What would you like me to do?")
        }

        // Already saved (same title, day, person, repeat and category): still shown, with a note to review. Never removed.
        for n in items.indices where ctx.saved.contains(where: { matches(items[n], $0, calendar: ctx.calendar) }) {
            items[n].advisories.append("You already have this saved")
            Trace.step("SWIFT", "\(items[n].title): matches a saved task on title, day, person, repeat and category (kept, with a note to review)")
        }
        return .items(items)
    }
}
