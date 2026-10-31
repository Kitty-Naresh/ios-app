import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Talking to the model about a draft that is waiting to be saved

/// One change to one item of the draft, as the model words it. Items are named by their ref ("d2"), as the prompt lists them. An
/// empty string (or empty list) means "leave this field as it is"; `clear` names fields to empty.
struct DraftEditOpValue: Equatable {
    var ref = ""
    var refs: [String] = []         // more items the same change applies to
    var all = false                 // the change applies to every item of the list (ref and refs are then empty)
    var title = ""
    var day = ""                    // ISO date YYYY-MM-DD
    var time = ""                   // HH:mm
    var timeOfDay = ""              // morning, afternoon, evening, night or anytime
    var priority = ""
    var person = ""
    var purpose = ""                // why, as the user said it (stored as the reason)
    var instructions = ""           // how: quantity, dosage, method, as the user said it
    var clear: [String] = []        // day, time, timeOfDay, priority, person, purpose, instructions, category, tags (= category), repeat
    var remove = false
    var repeating: RepeatValue? = nil   // set when this item should now repeat (or stop: frequency "once")
    var listName = ""               // move to this list, as said (the flat edit call)
    /// The day, time or repeat as Swift read them from the user's words (the flat edit call). The model never writes an ISO day.
    var patch: DraftPatch? = nil

    /// Does this entry set anything (as opposed to only clearing, or removing)?
    var setsAnything: Bool {
        !title.isEmpty || !day.isEmpty || !time.isEmpty || !timeOfDay.isEmpty || !priority.isEmpty || !person.isEmpty
            || !purpose.isEmpty || !instructions.isEmpty || repeating != nil || !listName.isEmpty || patch != nil
    }
}

/// What the draft call returns: Kitty's answer, and when the user asked for a change, only what changes (edits by ref, plus new
/// tasks). Swift applies it to the draft. Plain Swift, so the validator and the tests do not depend on iOS 26.
struct DraftEditValue: Equatable {
    var action = ""                 // answer, change, clarify or unrelated (edit, add and ask still read)
    var reply = ""
    var edits: [DraftEditOpValue] = []
    var add: [TaskDraftValue] = []
    var addRoutines: [RoutineDraftValue] = []
    /// New tasks the flat edit call asked for, already read by `TaskDraftMapper` (list, instructions, day, time and repeat resolved).
    var addItems: [DraftItem] = []

    init(action: String = "", reply: String = "", edits: [DraftEditOpValue] = [], add: [TaskDraftValue] = [],
         addRoutines: [RoutineDraftValue] = [], addItems: [DraftItem] = []) {
        self.action = action; self.reply = reply; self.edits = edits; self.add = add; self.addRoutines = addRoutines; self.addItems = addItems
    }
}

/// What makes a draft review answer unusable, judged by its shape alone. Nothing here reads meaning: whether the words fit what the
/// user said is not checked. A problem means NOTHING in the answer is applied.
enum DraftReviewValidator {
    enum Problem: Equatable {
        case unknownAction(String)
        case changesBesideReply(String)         // an answer or a question that also carries edits or new items
        case emptyAnswer
        case emptyChange                        // said "change" and changed nothing
        case emptyEdit                          // an entry with no field, no clear and no removal
        case noTarget
        case unknownRefs([String])
        case editedAndRemoved([String])
        case setAndCleared
        case unknownClearField(String)
        case notOneQuestion

        /// A plain clause, for "I couldn't apply that: …".
        var text: String {
            switch self {
            case .unknownAction: return "the model's answer wasn't one I recognise"
            case .changesBesideReply(let what): return "the model \(what == "clarify" ? "asked a question" : "answered") but also tried to change the list"
            case .emptyAnswer: return "the model gave no answer"
            case .emptyChange: return "the model said the list should change but gave no change"
            case .emptyEdit: return "one change had nothing in it"
            case .noTarget: return "a change didn't say which item it was for"
            case .unknownRefs: return "a change named an item that isn't on the list"
            case .editedAndRemoved: return "the same item was both changed and removed"
            case .setAndCleared: return "one change set and emptied the same thing"
            case .unknownClearField: return "a change tried to empty something that isn't a field"
            case .notOneQuestion: return "the model's question wasn't one question"
            }
        }
    }

    static let actions: Set<String> = ["answer", "change", "clarify", "unrelated"]

    /// Every problem found, empty when the answer is usable. `refs` are the items on the draft now.
    static func check(_ v: DraftEditValue, refs: Set<String>) -> [Problem] {
        let action = v.action.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard actions.contains(action) else { return [.unknownAction(v.action)] }
        let reply = v.reply.trimmingCharacters(in: .whitespacesAndNewlines)
        let carries = !v.edits.isEmpty || !v.add.isEmpty || !v.addRoutines.isEmpty || !v.addItems.isEmpty
        switch action {
        case "unrelated": return []
        case "answer":
            var out: [Problem] = []
            if carries { out.append(.changesBesideReply(action)) }
            if reply.isEmpty { out.append(.emptyAnswer) }
            return out
        case "clarify":
            var out: [Problem] = []
            if carries { out.append(.changesBesideReply(action)) }
            if !ClarificationStateManager.isOneQuestion(reply) { out.append(.notOneQuestion) }
            return out
        default:
            guard carries else { return [.emptyChange] }
            var out: [Problem] = []
            var edited = Set<String>(), removed = Set<String>(), unknown: [String] = []
            for op in v.edits {
                let named = ([op.ref] + op.refs).map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                if !op.all {
                    if named.isEmpty { out.append(.noTarget) }
                    for r in named where !refs.contains(r) && !unknown.contains(r) { unknown.append(r) }
                }
                let sets = op.setsAnything
                if op.remove { removed.formUnion(named) }
                else {
                    edited.formUnion(named)
                    if !sets && op.clear.isEmpty { out.append(.emptyEdit) }
                    if BulkDraftManager.contradicts(op) { out.append(.setAndCleared) }
                    for f in op.clear where !BulkDraftManager.clearable.contains(BulkDraftManager.clearName(f)) {
                        out.append(.unknownClearField(f)); break
                    }
                }
            }
            if !unknown.isEmpty { out.append(.unknownRefs(unknown)) }
            let both = edited.intersection(removed)
            if !both.isEmpty { out.append(.editedAndRemoved(both.sorted())) }
            var seen = [Problem]()
            for p in out where !seen.contains(p) { seen.append(p) }
            return seen
        }
    }

    /// The refs a problem names that are on the list, for the "Edit" offers of the card.
    static func namedRefs(_ v: DraftEditValue, on refs: Set<String>) -> [String] {
        var out: [String] = []
        for op in v.edits {
            for r in ([op.ref] + op.refs).map({ $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) })
            where refs.contains(r) && !out.contains(r) { out.append(r) }
        }
        return out
    }
}

#if canImport(FoundationModels)
/// One change to existing items. Only the fields that change are present: an omitted field is unchanged, and a field is emptied only
/// by naming it in `clear`.
@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
@Generable
struct DraftEditOp {
    @Guide(description: "The refs of the items this change applies to, exactly as listed. Empty when all is true.")
    var refs: [String]
    @Guide(description: "True when the change applies to every item of the list. Then refs is empty and ONE entry is enough. Otherwise omit.")
    var all: Bool?
    @Guide(description: "A new title in Title Case, verb first. Only if the title changes. Otherwise omit.")
    var title: String?
    @Guide(description: "ISO date YYYY-MM-DD. Only if the day changes (work it out from today's date). Otherwise omit.")
    var day: String?
    @Guide(description: "Clock time HH:mm in 24 hours. Only if the time changes. Otherwise omit.")
    var time: String?
    @Guide(description: "morning, afternoon, evening, night or anytime. Only if it changes. Otherwise omit.")
    var timeOfDay: String?
    @Guide(description: "low, medium or high. Only if it changes. Otherwise omit.")
    var priority: String?
    @Guide(description: "A person's name. Only if who it is for changes. Otherwise omit.")
    var person: String?
    @Guide(description: "The reason, event or goal the user states for the task. Only if it changes. Otherwise omit.")
    var purpose: String?
    @Guide(description: "What the user states about how: quantity, dosage, variant, method. Only if it changes. Otherwise omit.")
    var instructions: String?
    @Guide(description: "Names of fields to empty, only when the user takes something away from the item. Almost always empty. Never a field this same entry sets.")
    var clear: [String]
    @Guide(description: "Only when these items now repeat (or stop repeating: frequency once). Otherwise omit.")
    var repeating: RepeatDraft?

    var value: DraftEditOpValue {
        DraftEditOpValue(ref: "", refs: refs, all: all ?? false, title: title ?? "", day: day ?? "", time: time ?? "",
                         timeOfDay: timeOfDay ?? "", priority: priority ?? "", person: person ?? "", purpose: purpose ?? "",
                         instructions: instructions ?? "", clear: clear,
                         remove: false, repeating: repeating?.value)
    }
}

/// The answer about "what are they asking". Nothing in it can change the list.
@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
@Generable(description: "Only when the user asks a question about the list and nothing needs to change. Never for a correction, a complaint, a request, or a spelling the user gives.")
struct ReviewAnswer {
    @Guide(description: "One or two short spoken sentences, using only what the user said and the list. The list is not changed.")
    var reply: String
}

/// The list must change: edits, removals and new items together, so a wrong draft is repaired in one answer.
@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
@Generable(description: "The list must change: edit items, remove items, or add items. This includes a polite request (\"can you remove the cab?\"), a complaint that items are wrong, repeated or were never asked for, a correction of a spelling or a misheard name, and a request to combine items into one (the first item gets the combined title, the others are removed).")
struct ReviewChange {
    @Guide(description: "One entry per kind of change, by refs (or all), with only the changed fields. To combine items into one task, one entry sets the combined title on the first ref (the others go in remove). Never retype the list. Empty if none.")
    var edits: [DraftEditOp]

    @Guide(description: "The refs of the items to delete, when the user asks to remove, delete or drop them (or says they are repeats or were never asked for, or asks to combine them: every item except the first, which keeps the combined title). Empty if none.")
    var remove: [String]

    @Guide(description: "Only the new items the new words ask for, each once. Empty if none.")
    var add: [ItemDraft]
}

/// One detail is missing and the list cannot be changed without it.
@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
@Generable(description: "Only when one essential detail is missing and the list cannot change without it.")
struct ReviewClarify {
    @Guide(description: "ONE specific question about the one missing detail. One sentence ending in a question mark.")
    var question: String
}

/// The one call about a draft that waits to be saved. The model chooses ONE variant: an answer (nothing changes), a change (edits,
/// removals, additions), a question, or "not about this list". A variant cannot hold the fields of another, so an answer cannot
/// carry changes and a question cannot carry edits.
@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
@Generable
enum DraftReview {
    case answer(ReviewAnswer)
    case change(ReviewChange)
    case clarify(ReviewClarify)
    case unrelated

    var value: DraftEditValue {
        switch self {
        case .answer(let a): return DraftEditValue(action: "answer", reply: a.reply)
        case .clarify(let c): return DraftEditValue(action: "clarify", reply: c.question)
        case .unrelated: return DraftEditValue(action: "unrelated")
        case .change(let c):
            var tasks: [TaskDraftValue] = [], routines: [RoutineDraftValue] = []
            for i in c.add { i.read(into: &tasks, routines: &routines) }
            // The refs to delete are one removal edit: the same path as any other change, applied once.
            var all = c.edits.map(\.value)
            let gone = c.remove.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            if !gone.isEmpty { all.append(DraftEditOpValue(ref: "", refs: gone, remove: true)) }
            return DraftEditValue(action: "change", edits: all, add: tasks, addRoutines: routines)
        }
    }
}
#endif

/// The prompt for the draft call: a snapshot of the state, not the conversation. It runs in its own fresh session with the same
/// instructions as every call. Sections, each left out when empty:
///
///     STATE: reviewing a draft of 5 items, version 7, not saved
///     QUESTION: you asked "Which day?" about d2 and are waiting for the answer
///     ITEMS (by ref, in the order the card shows them)
///     d1. "Buy Milk" | ... | created in L1 from "buy milk"
///     RECENT CHANGES (made by the app, newest last): Removed book cardamom. (d2, d3)
///     USER: "..."
///
/// How much of it is sent is decided by `ContextAssembler` against the measured window, in a fixed order. Nothing here cuts text
/// to a fixed length: the user's words and the open question are always whole, and a long original request is shortened only
/// at the highest levels of pressure by the assembler dropping whole sections.
enum DraftReviewPrompt {
    static let instructions = PersistentInstructions.review

    static func build(_ s: DraftSnapshot, level: SnapshotLevel = .init(vocabulary: .full, items: .full, skipped: true)) -> String {
        func clean(_ t: String) -> String { t.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\"", with: "'") }
        func shortened(_ t: String, to limit: Int) -> String {
            guard t.count > limit else { return t }
            return String(t.prefix(limit * 2 / 3)) + " … " + String(t.suffix(limit / 3))
        }
        let items = s.items
        func ref(_ n: Int, _ item: DraftItem) -> String { item.ref.isEmpty ? "d\(n + 1)" : item.ref }

        var lines = ["Today: \(PromptBuilder.today(s.now, calendar: s.calendar))"]
        let count = items.count
        lines.append("STATE: reviewing a draft of \(count) item\(count == 1 ? "" : "s"), version \(s.version), not saved")

        let asked = clean(s.openQuestion)
        if !asked.isEmpty { lines.append("QUESTION: you asked \"\(asked)\" and are waiting for the answer") }

        lines.append("ITEMS (by ref, in the order the card shows them)")
        for (n, item) in items.enumerated() {
            let r = ref(n, item)
            switch level.items {
            case .full: lines.append("\(r). " + describe(item, now: s.now, calendar: s.calendar) + provenance(item))
            case .compact:
                var row = "\(r). \"\(item.title)\""
                if let c = item.categoryName, !c.isEmpty { row += " | category \(c)" }
                lines.append(row)
            case .titles: lines.append("\(r). \"\(item.title)\"")
            }
        }

        if !s.recentChanges.isEmpty {
            lines.append("RECENT CHANGES (made by the app, newest last): " + s.recentChanges.joined(separator: " "))
        }
        if level.skipped {
            let left = s.skipped.filter { !$0.isEmpty }.prefix(6).map { "\"\(shortened(clean($0), to: 120))\"" }
            if !left.isEmpty { lines.append("HEARD BUT NOT MADE INTO TASKS: " + left.joined(separator: ", ")) }
        }
        switch level.vocabulary {
        case .full: if !s.vocabulary.isEmpty { lines.append(s.vocabulary) }
        case .relevant:
            let seen = ([s.newWords, s.openQuestion] + items.map(\.title)).joined(separator: " ")
            let v = ContextAssembler.relevantVocabulary(s.vocabulary, to: seen)
            if !v.isEmpty { lines.append(v) }
        case .none: break
        }
        lines.append("USER: \"\(clean(s.newWords))\"")
        return lines.joined(separator: "\n")
    }

    /// The same prompt from loose parts, at the fullest level. Used by the tests and by callers that have no snapshot.
    static func build(said original: String, newWords: String, items: [DraftItem], skipped: [String], now: Date,
                      calendar: Calendar = .current, openQuestion: String = "", vocabulary: String = "",
                      version: Int = 0, recentChanges: [String] = []) -> String {
        build(DraftSnapshot(now: now, calendar: calendar, items: items, version: version, newWords: newWords, originalWords: original,
                            skipped: skipped, openQuestion: openQuestion, recentChanges: recentChanges, vocabulary: vocabulary))
    }

    /// Where an item came from, as the latest thing that happened to it: ` | created in L4 from "Get sip curl"`. Only the newest
    /// entry, and only a short piece of the words: the model needs to find the item, not to re-read the conversation.
    static func provenance(_ i: DraftItem) -> String {
        guard let h = i.history.last else { return "" }
        // An unverified quote is the model's wording, not something the user said: it is never given back as "from \"…\"".
        if i.quoteUnverified, h.kind == "created" { return " | created" + (h.line > 0 ? " in L\(h.line)" : "") + " (quote unverified)" }
        var words = h.words.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\"", with: "'")
        if words.count > 80 { words = String(words.prefix(80)) + "…" }
        return " | \(h.kind)" + (h.line > 0 ? " in L\(h.line)" : "") + (words.isEmpty ? "" : " from \"\(words)\"")
    }

    private static func words(for day: Date, now: Date, calendar: Calendar) -> String {
        let offset = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: day)).day ?? 99
        switch offset {
        case 0: return "today"
        case 1: return "tomorrow"
        case -1: return "yesterday"
        default:
            let f = DateFormatter()
            f.calendar = calendar
            f.timeZone = calendar.timeZone
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "EEE d MMM"
            return f.string(from: day)
        }
    }

    /// "Buy milk | day 2026-10-26 | high priority | for Rani | category Groceries": what the model needs to copy an item unchanged.
    /// `dayInWords`: the day as the speaker would say it ("tomorrow", "Fri 30 Oct"), not as a date. The extraction's state block uses it: shown
    /// "2026-10-30", the model copied that date into the repeat field.
    static func describe(_ i: DraftItem, now: Date, calendar: Calendar = .current, dayInWords: Bool = false) -> String {
        var parts = ["\"\(i.title)\""]
        if i.kind == .routine { parts.append("routine" + (i.recurrence.map { " \($0.scheduleText)" } ?? "")) }
        if let d = i.due, i.kind == .task, dayInWords {
            parts.append("day " + words(for: d, now: now, calendar: calendar))
        } else if let d = i.due, i.kind == .task {
            let f = DateFormatter()
            f.calendar = calendar
            f.timeZone = calendar.timeZone
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd"
            parts.append("day " + f.string(from: d))
        }
        if let m = i.timeMinutes { parts.append(String(format: "time %02d:%02d", m / 60, m % 60)) }
        if let p = i.priority, !p.isEmpty { parts.append("\(p) priority") }
        if let a = i.assignee, !a.isEmpty { parts.append("for \(a)") }
        if let c = i.categoryName, !c.isEmpty { parts.append("category \(c)") }
        if let l = i.listName, !l.isEmpty { parts.append("list \(l)") }
        if let r = i.reason, !r.isEmpty { parts.append("purpose \"\(r)\"") }
        if let h = i.instructions, !h.isEmpty { parts.append("instructions \"\(h)\"") }
        for (field, raw) in i.unparsed.sorted(by: { $0.key < $1.key }) { parts.append("could not read \(field): \"\(raw)\"") }
        return parts.joined(separator: " | ")
    }
}
