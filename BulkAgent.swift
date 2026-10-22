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

    static let stop: Set<String> = ["the", "a", "an", "my", "our", "your", "task", "tasks", "item", "items", "one", "step", "please",
                                    "it", "that", "this", "to", "for", "of", "and", "also", "too", "from", "with", "on", "in", "at", "as",
                                    "again", "now", "then", "so", "just"]

    static func stem(_ w: String) -> String {
        var s = w
        if s.hasSuffix("ies"), s.count > 4 { s = String(s.dropLast(3)) + "y" }
        else if s.hasSuffix("s"), !s.hasSuffix("ss"), s.count > 3 { s.removeLast() }
        return s
    }

    /// Meaningful words: no filler, no action verbs. "Take out the trash task" gives ["take"? no: verbs dropped] -> ["out", "trash"].
    static func nouns(_ text: String) -> [String] {
        LocalSemanticPrechecker.tokens(text).filter { !stop.contains($0) && !ActionLexicon.verbs.contains($0) }.map(stem)
    }

    static func nounOverlap(_ a: String, _ b: String) -> Int {
        Set(nouns(a)).intersection(Set(nouns(b))).count
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
    var category = ""
    var dueDate = ""
    var dueTime = ""
    var priority = ""
    var assignee = ""
    var notes = ""
}

struct RoutineDraftValue: Equatable {
    var title = ""
    var category = ""
    var frequency = ""
    var schedule = ""
    var assignee = ""
    var notes = ""
}

struct PlaybookDraftValue: Equatable {
    var name = ""
    var dueDate = ""
    var assignee = ""
    var steps: [TaskDraftValue] = []
}

struct BulkDecisionValue: Equatable {
    var action = ""
    var tasks: [TaskDraftValue] = []
    var routines: [RoutineDraftValue] = []
    var playbook: PlaybookDraftValue? = nil
    var clarifyingQuestion = ""
    var spokenResponse = ""
}

#if canImport(FoundationModels)
@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
@Generable
struct TaskDraft {
    @Guide(description: "Short actionable title: an action and an object, for example 'Clean bathroom'")
    var title: String
    @Guide(description: "Specific household category such as Bathroom or Groceries, or empty")
    var category: String
    @Guide(description: "ISO date only if the user said a day, otherwise empty")
    var dueDate: String
    @Guide(description: "ISO time only if the user said a time, otherwise empty")
    var dueTime: String
    @Guide(description: "low, medium, high, or empty. Only if the user said it")
    var priority: String
    @Guide(description: "Assignee only if the user named one, otherwise empty")
    var assignee: String
    @Guide(description: "Optional notes, or empty")
    var notes: String

    var value: TaskDraftValue {
        TaskDraftValue(title: title, category: category, dueDate: dueDate, dueTime: dueTime, priority: priority,
                       assignee: assignee, notes: notes)
    }
}

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
@Generable
struct RoutineDraft {
    @Guide(description: "Short actionable title: an action and an object")
    var title: String
    @Guide(description: "Specific household category, or empty")
    var category: String
    @Guide(description: "once, daily, weekly, monthly, custom, or empty")
    var frequency: String
    @Guide(description: "The schedule in the user's words, for example 'every Monday' or 'every morning'")
    var schedule: String
    @Guide(description: "Assignee only if the user named one, otherwise empty")
    var assignee: String
    @Guide(description: "Optional notes, or empty")
    var notes: String

    var value: RoutineDraftValue {
        RoutineDraftValue(title: title, category: category, frequency: frequency, schedule: schedule, assignee: assignee, notes: notes)
    }
}

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
@Generable
struct PlaybookDraft {
    @Guide(description: "Playbook name, under five words")
    var name: String
    @Guide(description: "ISO date only if the user said a day, otherwise empty")
    var dueDate: String
    @Guide(description: "Assignee only if the user named one, otherwise empty")
    var assignee: String
    @Guide(description: "Ordered steps")
    var steps: [TaskDraft]

    var value: PlaybookDraftValue {
        PlaybookDraftValue(name: name, dueDate: dueDate, assignee: assignee, steps: steps.map(\.value))
    }
}

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
@Generable
struct BulkAgentDecision {
    @Guide(description: "create_tasks, create_routines, create_playbook, clarify, wait, update, or unrelated")
    var action: String

    @Guide(description: "Task drafts to create")
    var tasks: [TaskDraft]

    @Guide(description: "Routine drafts to create")
    var routines: [RoutineDraft]

    @Guide(description: "Playbook draft to create")
    var playbook: PlaybookDraft?

    @Guide(description: "One short clarifying question, or empty")
    var clarifyingQuestion: String

    @Guide(description: "One short natural spoken response, or empty while waiting")
    var spokenResponse: String

    var value: BulkDecisionValue {
        BulkDecisionValue(action: action, tasks: tasks.map(\.value), routines: routines.map(\.value),
                          playbook: playbook?.value, clarifyingQuestion: clarifyingQuestion, spokenResponse: spokenResponse)
    }
}
#endif

// MARK: - Bulk detection (Swift, before the model)

enum BulkDetector {
    enum Kind: String, Equatable { case none, tasks, routines, playbook }

    struct Analysis: Equatable {
        var kind: Kind = .none
        var segments: [String] = []
        var isBulk: Bool { kind != .none }
    }

    static let scheduleCues = ["every ", "each ", "daily", "weekly", "monthly", "weekdays", "weekends", "alternate day", "routine"]
    static let listCues = ["add these", "add the following", "these tasks", "following tasks", "these chores", "these routines",
                           "add a few tasks", "add some tasks"]
    private static let numberWords: Set<String> = ["two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
                                                   "2", "3", "4", "5", "6", "7", "8", "9", "10"]
    private static let frames: [String] = ["add a task to ", "add a task for ", "add a task ", "add task to ", "add task ", "create a task to ",
                                           "i need to ", "i have to ", "i want to ", "i should ", "remind me to ", "please ", "can you ",
                                           "could you ", "also ", "and ", "then ", "to "]
    private static let separators = [" and then ", " and also ", " then ", " also ", ";", ",", " and "]

    static func hasSchedule(_ text: String) -> Bool {
        let t = text.lowercased()
        return scheduleCues.contains { t.contains($0) }
    }

    /// "wash", "milk and bread": splits a list into the pieces the user named.
    static func splitList(_ text: String) -> [String] {
        var s = text.lowercased().replacingOccurrences(of: "’", with: "'")
        for sep in separators { s = s.replacingOccurrences(of: sep, with: "|") }
        return s.split(separator: "|").map { stripFrames(Words.trim(String($0))) }.filter { !$0.isEmpty }
    }

    static func stripFrames(_ text: String) -> String {
        var s = Words.trim(text).trimmingCharacters(in: CharacterSet(charactersIn: " ,.;:-"))
        var changed = true
        while changed {
            changed = false
            for f in frames where s.lowercased().hasPrefix(f) {
                s = Words.trim(String(s.dropFirst(f.count)))
                changed = true
                break
            }
        }
        return s
    }

    /// Words that are often nouns too ("buy bottled water", "book flights"): a new action only when a determiner follows.
    private static let nounLikeVerbs: Set<String> = ["water", "iron", "book", "order", "plan", "set", "file", "label", "walk", "dust",
                                                      "polish", "steam", "heat", "clear", "fill", "pack", "drink", "cook", "mop", "load"]

    /// "clean bathroom buy milk water the plants" (no commas, no "and"): a new verb that follows a finished action
    /// ("clean bathroom") starts the next one. A verb after "to", "the", "and"... is part of the current action, and a
    /// word that is usually a noun only starts one when it is followed by "the", "my"...
    static func splitRunOns(_ piece: String) -> [String] {
        let words = piece.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard words.count >= 4, ActionLexicon.verbs.contains(SpeechLexicon.bare(words[0])) else { return [piece] }
        var out: [[String]] = [[words[0]]]
        for i in 1..<words.count {
            let w = SpeechLexicon.bare(words[i])
            let prev = SpeechLexicon.bare(words[i - 1])
            let objectSoFar = out[out.count - 1].count >= 2          // "clean bathroom" already has its object
            let hasObject = words.count - i >= 2                     // the new action has one too
            var starts = ActionLexicon.verbs.contains(w) && objectSoFar && hasObject
                && !SpeechLexicon.dangling.contains(prev) && !SpeechLexicon.determiners.contains(prev)
            if starts, nounLikeVerbs.contains(w) {
                starts = SpeechLexicon.determiners.contains(SpeechLexicon.bare(words[i + 1])) && !["to", "of", "in", "on", "at", "for", "with", "from"].contains(SpeechLexicon.bare(words[i + 1]))
            }
            if starts { out.append([words[i]]) } else { out[out.count - 1].append(words[i]) }
        }
        return out.map { $0.joined(separator: " ") }
    }

    /// Splits an utterance into verb-led actions. A piece without its own verb belongs to the piece before it
    /// ("buy milk and bread" is one action), and a bare verb joins the piece after it ("wash and fold the laundry").
    static func actionSegments(_ text: String) -> [String] {
        let pieces = splitList(text).flatMap(splitRunOns)
        var out: [String] = []
        var carryVerb: String?
        for piece in pieces {
            let words = LocalSemanticPrechecker.tokens(piece)
            guard let first = words.first else { continue }
            var current = piece
            if let v = carryVerb { current = v + " and " + piece; carryVerb = nil }
            let verbLed = ActionLexicon.verbs.contains(first)
            if words.count == 1, verbLed, carryVerb == nil, current == piece {
                carryVerb = piece                      // "wash" ... "fold the laundry"
                continue
            }
            if !verbLed, carryVerb == nil, current == piece, let last = out.indices.last {
                out[last] += " and " + piece           // "milk and bread"
                continue
            }
            out.append(current)
        }
        if let v = carryVerb { out.append(v) }
        // "buy milk and buy bread": the same shopping verb twice is one shopping task.
        let shopping: Set<String> = ["buy", "get", "order", "pick", "shop"]
        let leads = out.compactMap { LocalSemanticPrechecker.tokens($0).first }
        if out.count > 1, Set(leads).count == 1, let l = leads.first, shopping.contains(l),
           !LocalSemanticPrechecker.tokens(text).contains("separate") {
            return [out.joined(separator: " and ")]
        }
        return out
    }

    static func analyze(_ raw: String) -> Analysis {
        let text = raw.lowercased().replacingOccurrences(of: "’", with: "'")
        let tokens = LocalSemanticPrechecker.tokens(text)
        guard !tokens.isEmpty else { return Analysis() }

        if tokens.contains("playbook") || tokens.contains("playbooks") { return Analysis(kind: .playbook, segments: []) }

        // "add these tasks: dishes, laundry, trash"  /  "daily househelp tasks: make beds, wash dishes"
        if let colon = text.firstIndex(of: ":") {
            let head = String(text[..<colon])
            let items = splitList(String(text[text.index(after: colon)...]))
            if items.count >= 2 {
                return Analysis(kind: hasSchedule(head) ? .routines : .tasks, segments: items)
            }
        }
        // "add five tasks dishes laundry trash" without a colon
        if let cue = listCues.first(where: { text.contains($0) }) ?? numberedCue(text) {
            if let r = text.range(of: cue) {
                var tail = String(text[r.upperBound...])
                for w in ["tasks", "task", "chores", "routines", "to my list", "please"] where Words.trim(tail).hasPrefix(w) {
                    tail = String(Words.trim(tail).dropFirst(w.count))
                }
                let items = splitList(tail)
                if items.count >= 2 { return Analysis(kind: hasSchedule(text) ? .routines : .tasks, segments: items) }
            }
        }

        let segments = actionSegments(text)
        let verbLed = segments.filter { s in LocalSemanticPrechecker.tokens(s).first.map { ActionLexicon.verbs.contains($0) } ?? false }
        guard verbLed.count >= 2, verbLed.count == segments.count else { return Analysis() }
        let scheduled = segments.contains { hasSchedule($0) }
        return Analysis(kind: scheduled ? .routines : .tasks, segments: segments)
    }

    private static func numberedCue(_ text: String) -> String? {
        let words = LocalSemanticPrechecker.tokens(text)
        guard let i = words.firstIndex(where: { numberWords.contains($0) }), i > 0, i + 1 < words.count,
              ["task", "tasks", "chores", "routines"].contains(words[i + 1]) else { return nil }
        return words[i + 1]
    }

    /// The part of the utterance that is not one of the items: "tomorrow:" in "tomorrow: dishes, laundry".
    static func head(of utterance: String, segments: [String]) -> String {
        let lower = utterance.lowercased()
        var cut = lower.endIndex
        for s in segments { if let r = lower.range(of: s), r.lowerBound < cut { cut = r.lowerBound } }
        return String(lower[..<cut])
    }
}

// MARK: - Drafts that wait to be saved

struct DraftItem: Identifiable, Equatable {
    enum Kind: String { case task, routine }
    var id = UUID()
    var kind: Kind = .task
    var title: String
    var categoryName: String? = nil
    var due: Date? = nil
    var timeMinutes: Int? = nil
    var priority: String? = nil
    var assignee: String? = nil
    var notes: String? = nil
    var recurrence: RecurrenceSpec? = nil

    init(_ v: ValidatedTask, kind: Kind) {
        self.kind = kind
        title = v.title
        categoryName = v.categoryName
        due = v.due
        timeMinutes = v.timeMinutes
        priority = v.priority
        assignee = v.assignee
        notes = v.notes
        recurrence = kind == .routine ? v.recurrence : nil
    }

    init(title: String, kind: Kind = .task) { self.title = title; self.kind = kind }

    var validated: ValidatedTask {
        ValidatedTask(title: title, categoryName: categoryName, due: due, timeMinutes: timeMinutes, priority: priority,
                      assignee: assignee, notes: notes, recurrence: kind == .routine ? recurrence : nil)
    }

    func planned() -> PlannedTask { validated.planned() }
    var key: String { TaskValidator.key(title) }
}

struct PlaybookDraftState: Equatable {
    var name: String
    var due: Date? = nil
    var assignee: String? = nil
    var steps: [DraftItem]
    var stated = false
}

enum DraftEdit: Equatable {
    case addItem(String)
    case remove(String)
    case replace(from: String, to: String)
    case priority(target: String, level: String)
    case changeFields(target: String, changes: ValidatedTask)
    case addStep(String)
    case replaceStep(index: Int, text: String)       // index is 0-based; -1 is the last step
    case removeStep(index: Int)
}

enum EditOutcome: Equatable {
    case applied(String)           // a short acknowledgement, "Changed it to Buy bread."
    case question(String)
    case emptied
}

/// Holds the pending tasks, routines and playbook steps while the user corrects them one item at a time.
final class BulkDraftManager {
    private(set) var items: [DraftItem] = []
    private(set) var playbook: PlaybookDraftState?

    var hasContent: Bool { !items.isEmpty || playbook != nil }
    var labels: String {
        if let p = playbook { return "playbook \(p.name): " + p.steps.map(\.title).joined(separator: "; ") }
        return items.map(\.title).joined(separator: "; ")
    }

    func clear() { items = []; playbook = nil }
    func setItems(_ new: [DraftItem]) { items = new; playbook = nil }
    func setPlaybook(_ p: PlaybookDraftState?) { playbook = p; if p != nil { items = [] } }

    /// Adds items that are not already pending. Returns the ones that were added.
    @discardableResult
    func merge(_ new: [DraftItem]) -> [DraftItem] {
        var added: [DraftItem] = []
        for n in new where !items.contains(where: { $0.key == n.key }) { items.append(n); added.append(n) }
        return added
    }

    enum Match: Equatable { case one(Int), none, ambiguous }

    static let pronouns: Set<String> = ["", "it", "that", "this", "one", "that one", "this one", "the one"]

    func find(_ phrase: String) -> Match {
        let p = VoiceTurnManager.norm(phrase)
        if Self.pronouns.contains(p) { return items.count == 1 ? .one(0) : .ambiguous }
        let scores = items.map { Words.nounOverlap(p, $0.title) }
        guard let best = scores.max(), best > 0 else { return .none }
        let hits = scores.indices.filter { scores[$0] == best }
        return hits.count == 1 ? .one(hits[0]) : .ambiguous
    }

    private static let ordinals: [String: Int] = ["first": 0, "1st": 0, "second": 1, "2nd": 1, "third": 2, "3rd": 2, "fourth": 3, "4th": 3,
                                                  "fifth": 4, "5th": 4, "sixth": 5, "6th": 5, "last": -1, "final": -1]
    static func ordinalIndex(_ word: String) -> Int? {
        if let n = ordinals[word.lowercased()] { return n }
        if let n = Int(word), n >= 1 { return n - 1 }
        return nil
    }

    private func label(_ item: DraftItem) -> String { item.title }

    func apply(_ edit: DraftEdit, context ctx: ValidationContext) -> EditOutcome {
        switch edit {
        case .addItem(let text):
            guard let item = Self.makeItem(from: text, context: ctx) else {
                return .question("What should I do with \(Words.trim(text).lowercased())?")
            }
            return merge([item]).isEmpty ? .applied("That's already on the list.") : .applied("Added \(item.title.lowercased()).")

        case .remove(let phrase):
            switch find(phrase) {
            case .one(let i):
                let gone = items.remove(at: i)
                return items.isEmpty ? .emptied : .applied("Removed \(gone.title.lowercased()).")
            case .none: return .question("I couldn't find that on the list. Which one should I remove?")
            case .ambiguous: return .question("Which one should I remove?")
            }

        case .replace(let from, let to):
            switch find(from) {
            case .one(let i):
                items[i].title = Self.replacing(from: from, to: to, in: items[i].title)
                return .applied("Changed it to \(items[i].title).")
            case .none: return .question("I couldn't find that on the list. Which one should I change?")
            case .ambiguous: return .question("Which one should I change?")
            }

        case .priority(let target, let level):
            let t = VoiceTurnManager.norm(target)
            if ["all", "them", "everything", "all of them", "all tasks"].contains(t) {
                for i in items.indices { items[i].priority = level }
                return .applied("Made them all \(level) priority.")
            }
            switch find(target) {
            case .one(let i):
                items[i].priority = level
                return .applied("Made \(items[i].title.lowercased()) \(level) priority.")
            case .none: return .question("Which task should be \(level) priority?")
            case .ambiguous: return .question("Which task should be \(level) priority?")
            }

        case .changeFields(let target, let c):
            switch find(target) {
            case .one(let i):
                if let p = c.priority { items[i].priority = p }
                if let a = c.assignee { items[i].assignee = a }
                if let d = c.due, items[i].kind == .task { items[i].due = d }
                if let m = c.timeMinutes { items[i].timeMinutes = m }
                if let n = c.notes { items[i].notes = n }
                if let cat = c.categoryName { items[i].categoryName = cat }
                return .applied("Updated \(items[i].title.lowercased()).")
            default: return .question("Which one should I change?")
            }

        case .addStep(let text):
            guard var pb = playbook else { return .question("Which playbook?") }
            let title = TaskPlanner.tidyTitle(text, removingDay: false)
            guard !title.isEmpty else { return .question("What should the step be?") }
            if !pb.steps.contains(where: { $0.key == TaskValidator.key(title) }) { pb.steps.append(DraftItem(title: title)) }
            playbook = pb
            return .applied("Added step \(pb.steps.count).")

        case .replaceStep(let index, let text):
            guard var pb = playbook, !pb.steps.isEmpty else { return .question("Which playbook?") }
            let i = index == -1 ? pb.steps.count - 1 : index
            guard pb.steps.indices.contains(i) else { return .question("I only have \(Words.number(pb.steps.count)) steps. Which one?") }
            let title = TaskPlanner.tidyTitle(text, removingDay: false)
            guard !title.isEmpty else { return .question("What should that step be?") }
            pb.steps[i].title = title            // same position, same item: never a duplicate
            playbook = pb
            return .applied("Changed step \(i + 1) to \(title.lowercased()).")

        case .removeStep(let index):
            guard var pb = playbook, !pb.steps.isEmpty else { return .question("Which playbook?") }
            let i = index == -1 ? pb.steps.count - 1 : index
            guard pb.steps.indices.contains(i) else { return .question("I only have \(Words.number(pb.steps.count)) steps. Which one?") }
            let gone = pb.steps.remove(at: i)
            playbook = pb
            return pb.steps.isEmpty ? .emptied : .applied("Removed \(gone.title.lowercased()).")
        }
    }

    /// "change milk to bread" turns "Buy milk" into "Buy bread".
    static func replacing(from: String, to: String, in title: String) -> String {
        func clean(_ s: String) -> String {
            var t = Words.trim(s).lowercased()
            for d in ["the ", "a ", "an ", "my "] where t.hasPrefix(d) { t = String(t.dropFirst(d.count)) }
            return t
        }
        let f = clean(from), t = clean(to)
        guard !t.isEmpty else { return title }
        if !f.isEmpty, let r = title.range(of: f, options: .caseInsensitive) {
            return TaskPlanner.tidyTitle(title.replacingCharacters(in: r, with: t), removingDay: false)
        }
        let words = LocalSemanticPrechecker.tokens(t)
        if let first = words.first, ActionLexicon.verbs.contains(first) { return TaskPlanner.tidyTitle(t, removingDay: false) }
        let verb = LocalSemanticPrechecker.tokens(title).first ?? ""
        return TaskPlanner.tidyTitle(verb + " " + t, removingDay: false)
    }

    /// A draft from a few words the user added ("water plants", "water the plants every morning").
    static func makeItem(from text: String, context ctx: ValidationContext) -> DraftItem? {
        var working = BulkDetector.stripFrames(text)
        var recurrence: RecurrenceSpec?
        if let r = TaskPlanner.ruleRecurrence(in: working) { recurrence = r.spec; working = r.cleaned }
        let title = TaskPlanner.tidyTitle(working, removingDay: false)
        guard TaskValidator.isActionable(title), title.count <= 80 else { return nil }
        var v = ValidatedTask(title: title)
        let nouns = Set(Words.nouns(title))
        v.categoryName = ctx.knownCategories.first { c in !Set(Words.nouns(c)).isDisjoint(with: nouns) }
        v.due = TaskValidator.resolveDate("", utterance: text, ctx: ctx)
        v.recurrence = recurrence
        return DraftItem(v, kind: recurrence == nil ? .task : .routine)
    }
}

// MARK: - Understanding corrections to a pending draft

enum DraftEditParser {
    private static let lead = ["no", "nope", "actually", "okay", "ok", "wait", "hmm", "um", "uh", "so", "please", "oh", "but",
                               "and also", "also", "and", "then", "yes"]
    private static let ordinal = "first|second|third|fourth|fifth|sixth|last|final|1st|2nd|3rd|4th|5th|6th"

    /// Recognises "also add water plants", "remove the trash task", "change milk to bread", "make the bathroom task high
    /// priority", "change the first step to buy vegetables". Anything else returns nil and goes to the model.
    static func parse(_ raw: String, hasPlaybook: Bool) -> DraftEdit? {
        var t = VoiceTurnManager.norm(raw)
        var hadAlso = false
        var changed = true
        while changed {
            changed = false
            for l in lead where t == l || t.hasPrefix(l + " ") {
                if l == "also" || l == "and also" { hadAlso = true }
                t = Words.trim(String(t.dropFirst(l.count)))
                changed = true
                break
            }
        }
        guard !t.isEmpty else { return nil }

        // Playbook steps
        if let g = Rx.groups("^(?:change|replace|update|set|make|edit)\\s+(?:the\\s+)?(\(ordinal))\\s+step\\s+(?:to|with|into|as)?\\s*(.+)$", in: t),
           let i = BulkDraftManager.ordinalIndex(g[1]) { return .replaceStep(index: i, text: g[2]) }
        if let g = Rx.groups("^(?:change|replace|update|edit)\\s+step\\s+(\\d+)\\s+(?:to|with|into|as)\\s+(.+)$", in: t),
           let n = Int(g[1]), n >= 1 { return .replaceStep(index: n - 1, text: g[2]) }
        if let g = Rx.groups("^(?:remove|delete|drop|cut)\\s+(?:the\\s+)?(\(ordinal))\\s+step$", in: t),
           let i = BulkDraftManager.ordinalIndex(g[1]) { return .removeStep(index: i) }
        if let g = Rx.groups("^(?:remove|delete|drop)\\s+step\\s+(\\d+)$", in: t), let n = Int(g[1]), n >= 1 { return .removeStep(index: n - 1) }
        if let g = Rx.groups("^(?:add|include|insert)\\s+(?:a\\s+|another\\s+|one more\\s+)?(?:playbook\\s+)?step\\s+(?:to\\s+)?(.+)$", in: t) {
            return .addStep(g[1])
        }

        // Priority: "make the bathroom task high priority", "make it urgent"
        if let level = ["high", "medium", "low"].first(where: { TaskValidator.resolvePriority($0, utterance: t) != nil }),
           let first = t.split(separator: " ").first, ["make", "set", "mark", "change", "put", "give", "turn"].contains(String(first)) {
            let cues = ["high priority", "medium priority", "low priority", "top priority", "highest priority", "lowest priority",
                        "normal priority", "moderate priority", "not urgent", "no rush", "urgent", "important", "critical", "asap", "priority"]
            var rest = " " + t.dropFirst(first.count) + " "
            for c in cues { rest = rest.replacingOccurrences(of: " \(c) ", with: " ") }
            let words = rest.split(separator: " ").map(String.init).filter { !["to", "as", "the", "a", "an", "task", "tasks", "item", "is", "be"].contains($0) }
            return .priority(target: words.joined(separator: " "), level: level)
        }

        // Remove
        if let g = Rx.groups("^(?:remove|delete|drop|skip|scrap|cancel|take off|get rid of|cross off|forget)\\s+(?:the\\s+|that\\s+|a\\s+)?(.+)$", in: t),
           !["it", "that", "this", "everything", "all", "them", "all of them"].contains(g[1]) {
            return .remove(g[1])
        }

        // Replace: "change milk to bread", "replace milk with bread", "bread instead of milk"
        if let g = Rx.groups("^(?:use\\s+|make it\\s+)?(.+?)\\s+instead of\\s+(.+)$", in: t) { return .replace(from: g[2], to: g[1]) }
        if let g = Rx.groups("^(?:change|replace|swap|switch|make|update)\\s+(?:the\\s+)?(.+?)\\s+(?:to|with|into|for)\\s+(.+)$", in: t),
           !g[2].contains("priority"), !TaskValidator.mentionsDate(g[2]), !g[1].hasPrefix("it ") {
            return .replace(from: g[1], to: g[2])
        }

        // Add
        if let g = Rx.groups("^(?:add|include|put|plus)\\s+(?:a\\s+|an\\s+|another\\s+)?(?:task\\s+)?(?:to\\s+)?(.+?)(?:\\s+too|\\s+as well)?$", in: t) {
            return hasPlaybook ? .addStep(g[1]) : .addItem(g[1])
        }
        if hadAlso || t.hasSuffix(" too") || t.hasSuffix(" as well"),
           let first = LocalSemanticPrechecker.tokens(t).first, ActionLexicon.verbs.contains(first) {
            var item = t
            for s in [" too", " as well"] where item.hasSuffix(s) { item = String(item.dropLast(s.count)) }
            return hasPlaybook ? .addStep(item) : .addItem(item)
        }
        return nil
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
    }

    func recordAnswer(_ answer: String) {
        guard let q = lastQuestion else { return }
        answers.append((q, answer))
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
        return .ask(q)
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

    /// Questions about due dates, priority, assignees, categories or notes are never needed to save a task.
    static func asksForOptionalMetadata(_ question: String) -> Bool {
        let t = question.lowercased()
        if ["how often", "every", "repeat", "routine", "one-time", "one time"].contains(where: { t.contains($0) }) { return false }
        return ["due", "when should", "when do you", "what day", "what time", "what date", "priority", "who should", "who is it for",
                "who will", "assign", "which category", "what category", "notes", "deadline", "by when", "how urgent", "any other detail"]
            .contains { t.contains($0) }
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

    /// True exactly once for an armed proposal. A second "yes", a tap after a "yes", or the countdown after a "yes" get false.
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
    /// After saving: make today's routine copies, classify times of day. Returns extra task ids to show.
    func finishSaving(routineIDs: Set<UUID>) async -> [UUID]
}

@MainActor
struct StoreSaveSink: SaveSink {
    func saveTasks(_ planned: [PlannedTask]) -> [UUID] { TaskStore.shared.addMany(planned).map(\.id) }

    func saveRoutine(_ p: PlannedTask) -> UUID? {
        guard let rec = p.recurrence else { return nil }
        return TaskStore.shared.addRoutine(title: p.title, category: p.category, recurrence: rec, assignee: p.assignee,
                                           slot: p.slot, timeMinutes: p.timeMinutes)?.id
    }

    func savePlaybook(name: String, category: TaskCategory?, steps: [PlaybookStep], due: Date?) -> (replaced: Bool, created: [UUID]) {
        let store = TaskStore.shared
        let replaced = store.savePlaybook(name: name, category: category, steps: steps)
        var created: [UUID] = []
        if let due, let pb = store.playbook(matching: name, minWords: 1) { created = store.addPlaybookTasks(pb, due: due).map(\.id) }
        return (replaced, created)
    }

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
        await TaskAgent.classifyUntimed()
        return shown
    }
}

/// Used by the evals: nothing touches the user's real tasks.
@MainActor
final class InMemorySaveSink: SaveSink {
    private(set) var tasks: [PlannedTask] = []
    private(set) var routines: [PlannedTask] = []
    private(set) var playbooks: [(name: String, steps: [PlaybookStep], due: Date?)] = []

    func saveTasks(_ planned: [PlannedTask]) -> [UUID] {
        tasks.append(contentsOf: planned)
        return planned.map { _ in UUID() }
    }

    func saveRoutine(_ p: PlannedTask) -> UUID? {
        let schedule = p.recurrence?.scheduleText ?? ""
        if routines.contains(where: { $0.title.lowercased() == p.title.lowercased() && ($0.recurrence?.scheduleText ?? "") == schedule }) { return nil }
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

// MARK: - Previews and one-time saves for drafts

@MainActor
enum DraftProposals {
    static func tags(_ i: DraftItem) -> [PreviewTag] {
        var tags: [PreviewTag] = []
        if let r = i.recurrence, i.kind == .routine { tags.append(PreviewTag(text: r.scheduleText, icon: "repeat", color: .purple)) }
        if let d = i.due { tags.append(PreviewTag(text: d.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()), icon: "calendar")) }
        if let m = i.timeMinutes { tags.append(PreviewTag(text: DaySlot.clockLabel(m), icon: "clock", color: .indigo)) }
        if let a = i.assignee { tags.append(PreviewTag(text: a, icon: "person.fill", color: .person(a))) }
        if let c = i.categoryName { tags.append(PreviewTag(text: c, icon: "tag.fill")) }
        if let p = i.priority { tags.append(PreviewTag(text: p.capitalized + " priority", icon: "flag.fill", color: p == "high" ? .red : .orange)) }
        return tags
    }

    /// Several tasks and routines: always an explicit "yes", never a countdown.
    static func bulk(_ items: [DraftItem], question: String? = nil, ack: String? = nil, sink: SaveSink) -> Proposal {
        let rows = items.map { PreviewRow(icon: $0.kind == .routine ? "repeat" : "circle", title: $0.title, tags: tags($0)) }
        let prompt = question ?? DraftSummary.question(for: items)
        let once = Once()
        let tasks = items.filter { $0.kind == .task }.map { $0.planned() }
        let routines = items.filter { $0.kind == .routine }.map { $0.planned() }
        var p = Proposal(
            title: items.count == 1 ? "Save “\(items[0].title)”" : "Save \(DraftSummary.kindText(items))",
            rows: rows,
            confirmLabel: "Save",
            autoConfirm: false,
            pendingTitle: items.first?.title,
            apply: {
                guard once.fire() else { return AgentReply(message: "Already saved.", didAdd: false) }
                var created = sink.saveTasks(tasks)
                var routineIDs = Set<UUID>()
                var savedRoutines: [PlannedTask] = []
                var already = 0
                for r in routines {
                    if let id = sink.saveRoutine(r) { routineIDs.insert(id); savedRoutines.append(r) } else { already += 1 }
                }
                created += await sink.finishSaving(routineIDs: routineIDs)
                let message = (tasks.isEmpty && savedRoutines.isEmpty)
                    ? "You already have \(already == 1 ? "that" : "those")."
                    : DraftSummary.saved(tasks: tasks, routines: savedRoutines, alreadyHad: already)
                return AgentReply(message: message, didAdd: true, didChange: true, created: created)
            })
        p.prompt = (ack.map { $0 + " " } ?? "") + (ack == nil ? prompt : "Should I save these?")
        return p
    }

    static func playbook(_ pb: PlaybookDraftState, ack: String? = nil, sink: SaveSink) -> Proposal {
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
            autoConfirm: false,
            pendingPlaybook: pb.name,
            apply: {
                guard once.fire() else { return AgentReply(message: "Already saved.", didAdd: false) }
                let result = sink.savePlaybook(name: name, category: TaskCategory.guess(from: name), steps: steps, due: due)
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

// MARK: - Validating the model's drafts

enum BulkValidated: Equatable {
    case wait
    case clarify(String)
    case unrelated(String)
    case duplicate(String)
    case items([DraftItem])
    case playbook(PlaybookDraftState)
}

enum BulkValidator {
    private static func cleanNotes(_ s: String) -> String? {
        let t = Words.trim(s)
        return t.isEmpty ? nil : String(t.prefix(200))
    }

    /// The words the user said about this item: its own piece of the utterance.
    private static func segment(for title: String, segments: [String], whole: String) -> String {
        guard !segments.isEmpty else { return whole }
        let scored = segments.map { ($0, Words.nounOverlap($0, title)) }
        if let best = scored.max(by: { $0.1 < $1.1 }), best.1 > 0 { return best.0 }
        return whole
    }

    private static func dateText(segment seg: String, head: String) -> String {
        TaskValidator.mentionsDate(seg) || !TaskValidator.mentionsDate(head) ? seg : head + " " + seg
    }

    private static func make(title raw: String, category: String, dueDate: String, dueTime: String, priority: String, assignee: String,
                             notes: String, segments: [String], utterance: String, ctx: ValidationContext) -> ValidatedTask? {
        let title = TaskPlanner.tidyTitle(raw, removingDay: false)
        guard TaskValidator.isActionable(title), title.count <= 80 else { return nil }
        let seg = segment(for: title, segments: segments, whole: utterance)
        let dates = dateText(segment: seg, head: BulkDetector.head(of: utterance, segments: segments))
        return ValidatedTask(
            title: title,
            categoryName: TaskValidator.resolveCategory(category, known: ctx.knownCategories),
            due: TaskValidator.resolveDate(dueDate, utterance: dates, ctx: ctx),
            timeMinutes: TaskValidator.resolveTime(dueTime, utterance: dates),
            priority: TaskValidator.resolvePriority(priority, utterance: seg),
            assignee: TaskValidator.resolveAssignee(assignee, utterance: utterance, known: ctx.knownAssignees),
            notes: cleanNotes(notes))
    }

    private static func clarifyAbout(_ title: String) -> String {
        let t = Words.trim(title)
        return t.isEmpty ? "What would you like me to add?" : "What would you like me to do with \(t.lowercased())?"
    }

    static func validate(_ d: BulkDecisionValue, utterance: String, segments: [String], context ctx: ValidationContext) -> BulkValidated {
        let action = d.action.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        switch action {
        case "wait":
            return .wait
        case "clarify":
            let q = ClarificationStateManager.oneQuestion(d.clarifyingQuestion)
            return .clarify(q.isEmpty ? "What would you like me to add?" : q)
        case "unrelated":
            return .unrelated(Words.trim(d.spokenResponse))
        case "update":
            return .clarify("Which task would you like to update?")

        case "create_playbook":
            guard let p = d.playbook else { return .clarify("What should the playbook be for?") }
            let name = TaskPlanner.tidyTitle(p.name, removingDay: false)
            guard !name.isEmpty else { return .clarify("What should I call the playbook?") }
            let titles = p.steps.map { TaskPlanner.tidyTitle($0.title, removingDay: false) }.filter { !$0.isEmpty }
            var seen = Set<String>()
            let steps = titles.filter { seen.insert(TaskValidator.key($0)).inserted }
            guard !steps.isEmpty else { return .clarify("What steps should it include?") }
            return .playbook(PlaybookDraftState(
                name: name,
                due: TaskValidator.resolveDate(p.dueDate, utterance: utterance, ctx: ctx),
                assignee: TaskValidator.resolveAssignee(p.assignee, utterance: utterance, known: ctx.knownAssignees),
                steps: steps.prefix(12).map { DraftItem(title: $0) },
                stated: TaskValidator.stepsStated(utterance)))

        case "create_tasks", "create_routines", "create_task", "create_routine":
            var items: [DraftItem] = []
            let utterNouns = Words.nouns(utterance)

            for t in d.tasks {
                // Never invent a task: it has to name something the user said.
                if !t.title.isEmpty, Words.nounOverlap(t.title, utterance) == 0, !Words.nouns(t.title).isEmpty, !utterNouns.isEmpty { continue }
                guard let v = make(title: t.title, category: t.category, dueDate: t.dueDate, dueTime: t.dueTime, priority: t.priority,
                                   assignee: t.assignee, notes: t.notes, segments: segments, utterance: utterance, ctx: ctx) else {
                    return .clarify(clarifyAbout(t.title))
                }
                items.append(DraftItem(v, kind: .task))
            }

            for r in d.routines {
                if !r.title.isEmpty, Words.nounOverlap(r.title, utterance) == 0, !Words.nouns(r.title).isEmpty, !utterNouns.isEmpty { continue }
                guard var v = make(title: r.title, category: r.category, dueDate: "", dueTime: "", priority: "", assignee: r.assignee,
                                   notes: r.notes, segments: segments, utterance: utterance, ctx: ctx) else {
                    return .clarify(clarifyAbout(r.title))
                }
                let freq = r.frequency.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                guard TaskValidator.frequencies.contains(freq) else {
                    return .clarify("How often should I repeat \(v.title.lowercased())?")
                }
                let seg = segment(for: v.title, segments: segments, whole: utterance)
                let scheduleText = (r.schedule + " " + seg).lowercased()
                var spec = TaskPlanner.ruleRecurrence(in: r.schedule)?.spec
                    ?? TaskPlanner.ruleRecurrence(in: seg)?.spec
                    ?? TaskPlanner.ruleRecurrence(in: utterance)?.spec
                let days = TaskPlanner.weekdaysMentioned(scheduleText)
                switch freq {
                case "daily": if spec == nil { spec = RecurrenceSpec() }
                case "weekly":
                    if days.isEmpty { return .clarify("Which day should I \(v.title.lowercased()) each week?") }
                    if spec == nil { spec = RecurrenceSpec(weekdays: days) }
                case "monthly":
                    if scheduleText.range(of: "\\d{1,2}(st|nd|rd|th)", options: .regularExpression) == nil, spec == nil {
                        return .clarify("Which day of the month should I \(v.title.lowercased())?")
                    }
                default: break
                }
                guard let schedule = spec else { return .clarify("How often should I repeat \(v.title.lowercased())?") }
                v.recurrence = schedule
                items.append(DraftItem(v, kind: .routine))
            }

            // The detector found pieces the model left out: keep them as the user said them.
            for s in segments where !items.contains(where: { Words.nounOverlap($0.title, s) > 0 }) {
                if let local = BulkDraftManager.makeItem(from: s, context: ctx) { items.append(local) }
            }

            var seen = Set<String>()
            items = items.filter { seen.insert($0.key).inserted }           // no duplicates inside one draft
            guard !items.isEmpty else { return .clarify("What would you like me to add?") }

            let recent = Set(ctx.recentTitles.map(TaskValidator.key))
            let fresh = items.filter { !recent.contains($0.key) }
            return fresh.isEmpty ? .duplicate(items[0].title) : .items(fresh)

        default:
            return .clarify("Sorry, I didn't catch that. What would you like me to do?")
        }
    }
}

