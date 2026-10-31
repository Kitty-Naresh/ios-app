import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - The flat edit (`PathProfile.flat`, a draft that waits)
//
// A draft waits to be saved and the user says something about it: "add bread to that", "make the milk for Friday", "drop the
// last one", "what's on the list?". This is its own small call, apart from extraction: a different job with a different schema.
// The model sees the draft by ref (d1, d2) and the user's words, and returns only what changes, in the user's words.
//
// Swift owns the rest. It reads the day, the time and the repeat (`TaskDraftMapper`), keeps the draft's list for a task that is
// added to it, drops a purpose or instructions the user never said, checks every ref, and applies the change to the draft through
// the same `BulkDraftManager.apply` and review gate as before. Nothing is saved without the user's approval.

/// One change to one task, as the model wrote it. A field is nil when the user did not change it; `clear` names fields to empty.
struct FlatEditUpdateValue: Equatable {
    var target = ""                   // d1, d2 … (a draft item) or t1 … t5 (a recent saved task)
    var title: String? = nil
    var schedule: String? = nil       // a repeat, as said
    var assignee: String? = nil
    var dueDate: String? = nil        // as said ("Friday"); Swift resolves it
    var dueTime: String? = nil        // as said ("5 pm", "evening"); Swift resolves it
    var purpose: String? = nil
    var instructions: String? = nil
    var listName: String? = nil
    var clear: [String] = []
}

/// What one edit call returned, in plain Swift (so the mapper and the tests do not depend on iOS 26).
struct FlatEditValue: Equatable {
    var outcome = "change"            // change, answer, clarify or unrelated
    var answer: String? = nil
    var question: String? = nil
    /// The list the added tasks belong to, only when it differs from the draft's own list.
    var listName: String? = nil
    var add: [ExtractionTaskValue] = []
    var update: [FlatEditUpdateValue] = []
    var remove: [String] = []

    init(outcome: String = "change", answer: String? = nil, question: String? = nil, listName: String? = nil,
         add: [ExtractionTaskValue] = [], update: [FlatEditUpdateValue] = [], remove: [String] = []) {
        self.outcome = outcome; self.answer = answer; self.question = question; self.listName = listName
        self.add = add; self.update = update; self.remove = remove
    }
}

/// The day, time or repeat of an edit as Swift read them from the user's words. `probe` is a blank task built by the same reader
/// that reads a new task, so an edit and a creation understand "Friday evening" or "every morning" in exactly the same way.
struct DraftPatch: Equatable {
    /// Which of "day", "time" and "repeat" the user changed. Fields not in the set are left as they are.
    var sets: Set<String>
    var probe: DraftItem
}

/// A question about saved tasks, read by Swift alone (no model call). Deliberately simple: a list name, a day, a status, and the
/// content words that are left. A question this cannot read shows too much or too little, and the reply says what was looked for.
enum FlatQueryParser {
    private static let filler: Set<String> = [
        "what", "whats", "what's", "which", "show", "list", "tell", "give", "me", "my", "the", "a", "an", "is", "are", "was", "do", "does",
        "did", "i", "we", "have", "has", "there", "any", "all", "on", "in", "of", "for", "to", "at", "from", "with", "and", "or", "about",
        "task", "tasks", "todo", "todos", "to-do", "open", "pending", "left", "remaining", "still", "due", "s", "got", "get", "see", "can",
        "you", "please", "how", "many", "much", "need", "needs", "now", "so", "far"]
    private static let done: Set<String> = ["done", "finished", "completed", "complete", "ticked"]

    static func parse(_ words: String, lists: [String]) -> TaskQueryValue {
        var q = TaskQueryValue()
        let tokens = words.lowercased().split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init)
        var used = Set<String>()
        for t in tokens {
            switch t {
            case "today": q.day = "today"; used.insert(t)
            case "tomorrow": q.day = "tomorrow"; used.insert(t)
            case "overdue", "late": q.day = "overdue"; used.insert(t)
            default: if done.contains(t) { q.status = "done"; used.insert(t) }
            }
        }
        let stems = Set(tokens.map { TaskLabels.stem($0) })
        for name in lists {
            for candidate in [name, TaskLabels.listShort(name)] where !candidate.isEmpty {
                let parts = TaskLabels.stemKey(candidate).split(separator: " ").map(String.init)
                if !parts.isEmpty, parts.allSatisfy({ stems.contains($0) }) {
                    q.list = name
                    for t in tokens where parts.contains(TaskLabels.stem(t)) { used.insert(t) }
                    break
                }
            }
            if !q.list.isEmpty { break }
        }
        let rest = tokens.filter { !used.contains($0) && !filler.contains($0) && $0.count > 1 }
        q.text = rest.joined(separator: " ")
        return q
    }
}

/// Lines that were added without a real-model before and after. Each one is a single switch: flip it to take the line out.
enum FlatExperiments {
    /// One sentence about a speaker who corrects themselves, in the extraction and edit instructions.
    static let correctionLine = true
    /// One sentence that "A and B" are two tasks, in the extraction instructions.
    static let separateTargets = true
    /// A few sentences about the STATE block and the person, day and time said once for several tasks, in the extraction instructions.
    /// OFF. Measured on the real model (REAL_MODEL_PROMPT_ARMS.md, 8 single-task sentences x 6 runs): with this paragraph the model
    /// named a person nobody said in 21 of 48 runs; the same schema without it, in 0 of 48. A person, day or time is filled only
    /// from the user's own words, so nothing here may invite the model to write one "once for the whole list".
    static let scopeLine = false
    /// The draft half of that paragraph, with nothing about people or days: what STATE and DRAFT are, and not to repeat a DRAFT task.
    /// Without it the model is shown a STATE block that the instructions never explain. Not measured on its own: the scoreboard's
    /// conversation cases (J01 to J06) are its test.
    static let draftLine = true
    /// When words in the request were left without a task, ask once more with the previous accepted sentence added. A second call:
    /// not measured on the real model. Switch it off to keep only the note on the card.
    static let coverageRetryCall = true

    static let correctionText = "If the user corrects themselves or says \"not X, do Y\", the latest words win: only the final version is a task, and X is removed or renamed to Y."
    static let separateTargetsText = "\"A and B\" as separate targets are separate tasks."
    /// A note is not a command: a fact, a memory or a feeling makes no task, and words with nothing to do return "wait". Measured on
    /// the notes scoreboard (notes_v1.json): switch it off if it makes real tasks disappear.
    static let actionsOnly = true
    static let actionsOnlyText = """
    Make a task only for something the user says they will do, need to do, or want done. A fact, a memory, a feeling, or information
    to remember (a password, a number, something that happened) is not a task. If nothing in the words is something to do, return wait.
    """
    static let draftText = "When the request starts with STATE, the app has already accepted some tasks (DRAFT). Return only the tasks in the Request. Never repeat a DRAFT task."
    /// Not sent while `scopeLine` is off. Kept so the measurement can be repeated.
    static let scopeText = """
    When the request starts with STATE, the app has already accepted some tasks (DRAFT) and may hold a Scope: a person, day or time the user said once for the whole list. Return only the tasks in the Request. Never repeat a DRAFT task.
    A person, day or time the user says once for several tasks ("house help tasks for tomorrow") is written once, in assignee, dueDate or dueTime of the answer. Leave it out of the tasks, and never copy the Scope into the answer. A person or day said for one task goes on that task.
    Set leavesScope only when the Scope exists and the new tasks are for someone or some day else, or for no one in particular.
    """
}

enum FlatEditInstructions {
    /// The instructions follow what is really there: a draft, recent saved tasks, or both. They never say a draft waits when none does.
    static func text(draftWaits: Bool = true, recentShown: Bool = false) -> String {
        var out: [String] = []
        switch (draftWaits, recentShown) {
        case (true, true):
            out.append("A draft of new tasks waits to be saved, and the user's last saved tasks may be changed too. The request lists the draft tasks by ref (d1, d2) and the saved tasks by ref (t1, t2), then the user's new words. Their latest words win.")
        case (true, false):
            out.append("A draft of tasks waits to be saved. The request lists the tasks by ref (d1, d2), then the user's new words. Their latest words win.")
        default:
            out.append("The user's last saved tasks are listed by ref (t1, t2), then the user's new words. No draft waits. Their latest words win.")
        }
        out.append("""
        Choose one outcome.
        change: add, update or remove tasks.
        answer: the user only asks something; nothing changes. Write a short reply.
        clarify: one essential detail is missing; ask one question.
        unrelated: the words are not about these tasks.

        Name a task only by a ref from the list. Never invent a ref.
        Return only what changes. Leave every other task and every other field as it is. Leave add, update, remove and clear out when the user did not ask for them.
        Use update for a task that changes, with only the fields the user changed. Use clear only to take a field away.
        """)
        out.append(draftWaits
            ? "Use add for a new task, with the same fields as a new task. A new task joins the draft's list. Set listName only when the user names a different list."
            : "Use add for a new task, with the same fields as a new task. A new task that belongs with a saved task goes on that task's list: set listName to that list's name.")
        out.append("Use remove for a task the user wants gone.\nA spelling or misheard-name correction changes the title of the one task whose title sounds most like it, and nothing else.")
        if recentShown {
            out.append("Saved tasks change only after the user approves, so update and remove work on them the same way.")
        }
        if FlatExperiments.correctionLine { out.append(FlatExperiments.correctionText) }
        out.append("""
        Fields hold the user's words. Swift works out dates, times and repeats: never write a date or time you worked out yourself.
        Use purpose for a reason the user stated. Use instructions for a quantity, dosage, variant, preference or method.
        Never invent tasks, values or people. Never say a change was made; the app reports what changed.
        """)
        return out.joined(separator: "\n\n")
    }
}

// MARK: - The intent of the words
//
// One tiny call that says what the words are for, so a plain request is never read as an edit. It sees the words and one line of
// real state, never a task. Swift decides what to do with the answer (`VoiceTurnManager`), and when the call gives nothing the
// words are treated as a request to make tasks.

/// What the intent call returned, in plain Swift.
struct FlatIntentValue: Equatable {
    var intent = "create"             // create, change, query or unrelated
    var correction = false            // the speaker takes back or fixes something they just said
}

enum FlatIntentInstructions {
    static let text = """
    Decide what the user's words are for. Choose one intent.
    create: they want new tasks or reminders made.
    change: they want to change, correct, remove or add to something that already exists, a waiting draft or a recently saved task. They point at it ("that", "the last one", "the X list") or take back what they just said.
    query: they ask a question about their saved tasks. Nothing changes.
    unrelated: it is none of these.
    Set correction to true when they take back or fix something they just said.
    When unsure, choose create.
    """
}

enum FlatIntentPrompt {
    static func build(words: String, draftWaits: Bool, recentExist: Bool) -> String {
        var state: [String] = []
        state.append(draftWaits ? "A draft of new tasks waits to be saved." : "No draft waits.")
        state.append(recentExist ? "Recently saved tasks exist." : "No tasks were saved recently.")
        return "State: " + state.joined(separator: " ") + "\nRequest:\n" + words.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - The question when the words hold no task
//
// "Can you create a new task? task?" says nothing to add. Swift decides that (`TaskMeaning`); the model only words ONE short question
// about what to add. It sees the words as heard and names (a list that was named, whether a draft waits, the last task titles), so the
// question can sound natural. It is told never to suggest or invent a task.

enum ContentQuestionInstructions {
    static let text = """
    The user asked to add a task but did not say what it is. Ask one short, specific question asking what they want to add.
    Never suggest or invent a task. Never say that anything was added. Reply with one sentence that ends with a question mark.
    """
}

enum ContentQuestionPrompt {
    static func build(words: String, list: String?, draftWaits: Bool, recent: [String]) -> String {
        var lines = ["The user said:\n" + words.trimmingCharacters(in: .whitespacesAndNewlines)]
        if let list, !list.isEmpty { lines.append("A list was named: \(list)") }
        if draftWaits { lines.append("A draft of tasks waits to be saved.") }
        if !recent.isEmpty { lines.append("Their last saved tasks, for context only: " + recent.joined(separator: "; ")) }
        return lines.joined(separator: "\n")
    }
}

/// What the edit call sends: the draft by ref, the open question, and the words. No date and no vocabulary.
enum FlatEditPrompt {
    static func build(items: [DraftItem], words: String, openQuestion: String = "", recent: [String] = [],
                      now: Date = Date(), calendar: Calendar = .current) -> String {
        var lines: [String] = []
        if !items.isEmpty || recent.isEmpty { lines.append("DRAFT (refs as listed)") }
        if items.isEmpty, recent.isEmpty { lines.append("(empty)") }
        for (n, item) in items.enumerated() {
            let ref = item.ref.isEmpty ? "d\(n + 1)" : item.ref
            lines.append("\(ref). " + DraftReviewPrompt.describe(item, now: now, calendar: calendar))
        }
        if !recent.isEmpty {
            if !lines.isEmpty { lines.append("") }
            lines.append("RECENT SAVED TASKS (by ref)")
            lines.append(contentsOf: recent)
        }
        let asked = openQuestion.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\"", with: "'")
        if !asked.isEmpty { lines.append("\nYou asked \"\(asked)\" and are waiting for the answer.") }
        lines.append("\nRequest:\n" + words.trimmingCharacters(in: .whitespacesAndNewlines))
        return lines.joined(separator: "\n")
    }
}

/// From the model's edit to the value the draft review already applies (`DraftEditValue`): the new tasks are read into drafts, the
/// day, time and repeat into a patch. A ref is passed through as given; the review gate refuses one that is not on the draft.
enum FlatEditMapper {
    static func map(_ v: FlatEditValue, draft: [DraftItem], transcript: String, words: String = "", knownLists: [String] = [],
                    now: Date = Date(), calendar: Calendar = .current) -> DraftEditValue {
        switch v.outcome.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) {
        case "answer": return DraftEditValue(action: "answer", reply: v.answer ?? "")
        case "clarify": return DraftEditValue(action: "clarify", reply: v.question ?? "")
        case "unrelated": return DraftEditValue(action: "unrelated")
        case "change": break
        default: return DraftEditValue(action: v.outcome)
        }

        // A task that is added goes to the list the model named; else to an existing list the new words put it on ("to the Blinkit
        // order"); else to the draft's list when the draft has exactly one.
        let inherited = singleList(of: draft)
        // A name the words give no cue for is not used (see `ListNameGate`); an edit with no words at all (a test) is not checked.
        let said = [transcript, words].filter { !$0.isEmpty }.joined(separator: " ")
        func gated(_ name: String?) -> String? {
            guard let clean = TaskDraftMapper.clean(name) else { return nil }
            guard !said.isEmpty, let why = ListNameGate.rejection(clean, words: said, known: knownLists) else { return clean }
            Trace.step("WARNING", "the list name \"\(clean)\" is not used: \(why)")
            return nil
        }
        var named = gated(v.listName)
        if named == nil, let found = ListMention.existing(in: words, among: knownLists) { named = found }
        var added: [DraftItem] = []
        for t in v.add {
            var task = t
            task.listName = gated(task.listName)
            if task.listName == nil { task.listName = named }
            if let item = TaskDraftMapper.item(from: task, listName: inherited, now: now, calendar: calendar, transcript: transcript) {
                added.append(item)
            }
        }

        var edits = v.update.map { op($0, now: now, calendar: calendar) }
        let gone = v.remove.map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if !gone.isEmpty { edits.append(DraftEditOpValue(refs: gone, remove: true)) }
        return DraftEditValue(action: "change", edits: edits, addItems: added)
    }

    /// The one list every task in the draft names, or nil when there is none or more than one.
    static func singleList(of items: [DraftItem]) -> String? {
        var found: String?
        for item in items {
            guard let l = TaskDraftMapper.clean(item.listName) else { continue }
            if let f = found, !TaskLabels.same(f, l) { return nil }
            if found == nil { found = l }
        }
        return found
    }

    static func op(_ u: FlatEditUpdateValue, now: Date, calendar: Calendar) -> DraftEditOpValue {
        var op = DraftEditOpValue(ref: u.target.lowercased().trimmingCharacters(in: .whitespacesAndNewlines))
        op.title = TaskDraftMapper.clean(u.title) ?? ""
        if !op.title.isEmpty, !TaskMeaning.isMeaningful(title: op.title) {
            Trace.step("WARNING", "the retitle \"\(op.title)\" says nothing about a task: the title is left as it is")
            op.title = ""
        }
        op.person = TaskDraftMapper.clean(u.assignee) ?? ""
        op.purpose = TaskDraftMapper.clean(u.purpose) ?? ""
        op.instructions = TaskDraftMapper.clean(u.instructions) ?? ""
        op.listName = TaskDraftMapper.clean(u.listName) ?? ""
        op.clear = u.clear

        var probe = ExtractionTaskValue(title: "x")
        var sets: Set<String> = []
        if let d = TaskDraftMapper.clean(u.dueDate) { probe.dueDate = d; sets.insert("day") }
        if let t = TaskDraftMapper.clean(u.dueTime) { probe.dueTime = t; sets.insert("time") }
        if let s = TaskDraftMapper.clean(u.schedule) { probe.schedule = s; sets.insert("repeat") }
        guard !sets.isEmpty, let item = TaskDraftMapper.item(from: probe, now: now, calendar: calendar) else { return op }

        // A "repeat" that says a day ("Friday evening") was read as the day, with no repeat left on the item.
        if sets.contains("repeat"), item.kind == .task, item.schedule == nil, item.unparsed["repeat"] == nil {
            sets.remove("repeat")
            sets.insert("day")
        }
        op.patch = DraftPatch(sets: sets, probe: item)
        return op
    }
}

// MARK: - What an edit may not do

/// Whether a piece of text can be a task at all. One generic rule, used wherever a task can appear: the model's titles, tasks added by an
/// edit, a retitle, the hand-edit sheet and the words themselves before any model call.
///
/// This is a SHAPE check. It does not interpret meaning: it removes words about using the app and bare command verbs, and asks only
/// whether anything is left. "Make dinner" and "Create presentation" keep their noun; "create", "a new task" and "can you create a
/// task? task?" keep nothing. A real task made only of these words ("Make a list") is refused too, and the user is asked what it is.
enum TaskMeaning {
    /// Words about talking to the app, not about a task: filler, polite frames, and the app's own object words.
    static let appTalk: Set<String> = [
        "can", "could", "you", "please", "i", "want", "need", "would", "like", "just", "said", "a", "an", "the", "new", "another",
        "one", "to", "for", "me",
        "task", "tasks", "reminder", "reminders", "todo", "item", "list", "something",
        // Hesitation sounds say nothing: a title made of them ("uh the...") is not a task.
        "uh", "uhh", "um", "umm", "hmm", "hm", "er", "erm", "ah"]
    /// Verbs that are commands to the app. Removed for this check only: inside a longer title they are fine.
    static let bareVerbs: Set<String> = ["add", "create", "make", "remove", "delete", "start", "set", "remind"]

    /// Object words that make a leading command verb a spoken command, not a task ("Add a task to …").
    private static let objects: Set<String> = ["task", "tasks", "reminder", "reminders", "todo"]
    private static let frames = ["please ", "can you ", "could you ", "i want to ", "i need to ", "i just said ", "i said ", "remind me to "]

    private static func tokens(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init)
    }

    /// At least one word is left once repeats ("task task"), app-talk, bare command verbs and number-only words are removed.
    static func hasContent(_ text: String) -> Bool {
        var previous = ""
        for t in tokens(text) {
            if t == previous { continue }
            previous = t
            if appTalk.contains(t) || bareVerbs.contains(t) || !t.contains(where: { $0.isLetter }) { continue }
            return true
        }
        return false
    }

    /// A title that is the user's spoken command and not a task ("Add a task to buy bread and milk", "Add milk to the blanket list"):
    /// it starts with a polite or reporting frame, or with a command verb and then names an app object (or ends in "list").
    /// `hasContent` alone passes these, because the words after the command are real. A long sentence with real content and neither
    /// is a normal imperative ("call the plumber about the leaking tap"): the model copying it whole as the title is not a reason to
    /// refuse it, so length and equality with the utterance do not count. `utterance` is kept for the callers and is not used.
    static func isCommandEcho(_ title: String, utterance: String) -> Bool {
        let words = tokens(title)
        guard let first = words.first else { return false }
        let t = words.joined(separator: " ")
        if frames.contains(where: { t.hasPrefix($0) }) { return true }
        return bareVerbs.contains(first) && (words.dropFirst().contains(where: { objects.contains($0) }) || words.last == "list")
    }

    /// A retitle of five or more words that is the whole sentence the user said for the edit: the model copied the spoken edit command
    /// into the title. Used only for a retitle, never for a new task.
    static func copiesWholeUtterance(_ title: String, _ utterance: String) -> Bool {
        let words = tokens(title)
        return words.count >= 5 && words == tokens(utterance)
    }

    static func isMeaningful(title: String, utterance: String = "") -> Bool {
        hasContent(title) && !isCommandEcho(title, utterance: utterance)
    }
}

/// Checks an edit before anything is applied or shown. It rejects the whole edit: a half-applied edit from a model that wrote
/// something wrong is worse than "say it again". Pure Swift; it sees the refs, their titles and lists, and the user's words.
enum EditGuard {
    static let reply = "I couldn't apply that, nothing changed."

    /// One task the edit may touch: its ref, title and list.
    struct Target: Equatable {
        var ref: String
        var title: String
        var listName: String?
    }

    private static let pointers: Set<String> = ["that", "it", "this", "those", "them", "these", "last", "previous", "earlier", "first",
                                                "second", "third", "other", "one", "ones", "both", "all", "every", "each", "everything"]
    private static let everyone: Set<String> = ["all", "every", "each", "both", "everything"]
    private static let small: Set<String> = ["the", "and", "for", "with", "from", "that", "this", "add", "get", "buy"]

    /// Nil when the edit may go on, else why it was refused (for the trace). `allowMany`: a draft edit that says all, every, each or both.
    static func check(_ v: FlatEditValue, targets: [Target], words: String, allowMany: Bool) -> String? {
        let listed = Dictionary(targets.map { ($0.ref.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
        func key(_ s: String) -> String { s.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }

        for u in v.update {
            for field in u.clear where !BulkDraftManager.clearable.contains(BulkDraftManager.clearName(field)) {
                return "it clears \"\(field)\", which is not a field that may be emptied"
            }
        }
        var touched: [String] = []
        for ref in v.update.map({ key($0.target) }) + v.remove.map(key) where !ref.isEmpty {
            guard listed[ref] != nil else { return "it names \"\(ref)\", which is not in the list" }
            if !touched.contains(ref) { touched.append(ref) }
        }
        let tokens = words.lowercased().split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init)
        let said = Set(tokens)
        let everyTask = allowMany && !said.isDisjoint(with: everyone)
        if everyTask { return nil }
        if touched.count > 2 { return "it changes \(touched.count) tasks and the words do not say all of them" }

        let stems = Set(tokens.map { TaskLabels.stem($0) })
        for ref in touched {
            guard let t = listed[ref] else { continue }
            if said.contains(ref) || !said.isDisjoint(with: pointers) { continue }
            let titleWords = t.title.lowercased().split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init)
                .filter { $0.count >= 3 && !small.contains($0) }
            if titleWords.contains(where: { stems.contains(TaskLabels.stem($0)) }) { continue }
            if let list = t.listName, !list.isEmpty {
                let parts = (TaskLabels.stemKey(list) + " " + TaskLabels.stemKey(TaskLabels.listShort(list))).split(separator: " ").map(String.init)
                if parts.contains(where: { $0.count >= 3 && stems.contains($0) }) { continue }
            }
            return "it touches \"\(t.title)\" (\(ref)), which the words neither name nor point at"
        }
        return nil
    }
}

// MARK: - Changing the last five saved tasks

/// A cheap Swift check that decides whether a turn that has no draft could be about a task the user just saved. When it is false no
/// model call is spent and the words make tasks. When unsure it says no: a missed edit is said again, a wrong edit is a wrong card.
enum SavedEditGate {
    /// Words that point at something that already exists. "just", "one" and "also" are not here: they turn up in plain requests.
    static let references: Set<String> = ["that", "it", "this", "those", "them", "these", "last", "previous", "earlier"]
    /// Verbs that only mean a change to something that exists.
    static let verbs: Set<String> = ["change", "update", "rename", "move", "delete", "remove", "cancel", "reschedule", "postpone",
                                     "edit", "correct", "undo"]

    /// Could these words be about a task that already exists? A task's own title is not a cue (it matched "milk" in a plain request).
    static func shouldAsk(words: String, hasRecent: Bool, lists: [String]) -> Bool {
        guard hasRecent else { return false }
        let tokens = words.lowercased().split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init)
        let set = Set(tokens)
        if !set.isDisjoint(with: references) || !set.isDisjoint(with: verbs) { return true }
        let stems = Set(tokens.map { TaskLabels.stem($0) })
        for list in lists {
            for name in [list, TaskLabels.listShort(list)] where !name.isEmpty {
                let parts = TaskLabels.stemKey(name).split(separator: " ").map(String.init)
                if !parts.isEmpty, parts.allSatisfy({ stems.contains($0) }) { return true }
            }
        }
        return false
    }
}

/// The edit call's answer about saved tasks, as operations the existing approval card shows and applies, and new tasks that become an
/// ordinary draft. A ref that names no recent task is dropped and said. Nothing here changes a task.
enum SavedEditMapper {
    struct Result: Equatable {
        var operations: [ValidatedOperation] = []
        var adds: [DraftItem] = []
        var notes: [String] = []
        var dropped: [String] = []
    }

    /// `refs` maps t1 … t5 to the task ids the toolbox resolves.
    static func map(_ v: FlatEditValue, refs: [String: String], words: String, knownLists: [String] = [],
                    now: Date = Date(), calendar: Calendar = .current) -> Result {
        var out = Result()

        var named = TaskDraftMapper.clean(v.listName)
        if named == nil, let found = ListMention.existing(in: words, among: knownLists) { named = found }
        for t in v.add {
            var task = t
            if TaskDraftMapper.clean(task.listName) == nil { task.listName = named }
            if let item = TaskDraftMapper.item(from: task, now: now, calendar: calendar, transcript: words) { out.adds.append(item) }
        }

        func id(_ raw: String) -> String? {
            let key = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            if let found = refs[key] { return found }
            if !key.isEmpty { out.dropped.append(raw) }
            return nil
        }

        var seen = Set<String>()
        for u in v.update {
            guard let task = id(u.target), seen.insert(task).inserted else { continue }
            if let c = changes(u, words: words, now: now, calendar: calendar, notes: &out.notes) {
                out.operations.append(ValidatedOperation(kind: .update, taskID: task, changes: c, extended: true))
            }
        }
        for raw in v.remove {
            guard let task = id(raw), seen.insert(task).inserted else { continue }
            out.operations.append(ValidatedOperation(kind: .delete, taskID: task, changes: nil))
        }
        return out
    }

    /// The fields one update sets or clears, with the day, time and part of the day read by Swift. Nil when nothing is left to change.
    static func changes(_ u: FlatEditUpdateValue, words: String, now: Date, calendar: Calendar, notes: inout [String]) -> ValidatedTask? {
        var c = ValidatedTask(title: TaskDraftMapper.clean(u.title) ?? "")
        if !c.title.isEmpty, !TaskMeaning.isMeaningful(title: c.title, utterance: words) || TaskMeaning.copiesWholeUtterance(c.title, words) {
            Trace.step("WARNING", "the retitle \"\(c.title)\" says nothing about a task: the title is left as it is")
            c.title = ""
        }
        let who = Assignee.normalize(TaskDraftMapper.clean(u.assignee) ?? "")
        if !who.isEmpty { c.assignee = who }
        c.listName = TaskDraftMapper.clean(u.listName)
        // A purpose or instructions made of words the user never said is not kept.
        let titleForCheck = c.title.isEmpty ? " " : c.title
        if let r = TaskDraftMapper.clean(u.purpose) {
            if Provenance.said(r, in: words, notRepeating: titleForCheck) { c.reason = r } else { Trace.step("SWIFT", "purpose \"\(r)\" is not in what the user said: not kept") }
        }
        if let h = TaskDraftMapper.clean(u.instructions) {
            if Provenance.said(h, in: words, notRepeating: titleForCheck) { c.instructions = h } else { Trace.step("SWIFT", "instructions \"\(h)\" are not in what the user said: not kept") }
        }
        c.cleared = u.clear.filter { BulkDraftManager.clearable.contains(BulkDraftManager.clearName($0)) }

        var probe = ExtractionTaskValue(title: "x")
        probe.dueDate = TaskDraftMapper.clean(u.dueDate)
        probe.dueTime = TaskDraftMapper.clean(u.dueTime)
        if probe.dueDate != nil || probe.dueTime != nil, let item = TaskDraftMapper.item(from: probe, now: now, calendar: calendar) {
            if probe.dueDate != nil {
                if let raw = item.unparsed["date"] { notes.append("I couldn't read the day “\(raw)”, so I left the day alone.") }
                else { c.due = item.due; c.softDue = item.softDue }
            }
            if probe.dueTime != nil {
                if let raw = item.unparsed["time"] { notes.append("I couldn't read the time “\(raw)”, so I left the time alone.") }
                else if let m = item.timeMinutes { c.timeMinutes = m }
                else if let s = item.slot { c.slot = s }
            } else if let s = item.slot, item.timeMinutes == nil {
                c.slot = s          // "tomorrow evening": the part of the day travels with the day
            }
        }
        if TaskDraftMapper.clean(u.schedule) != nil { notes.append("I can't make a saved task repeat from here, so I left the repeat alone.") }

        let any = !c.title.isEmpty || c.assignee != nil || c.listName != nil || c.reason != nil || c.instructions != nil || c.due != nil
            || c.timeMinutes != nil || c.slot != nil || c.softDue != nil || !c.cleared.isEmpty
        return any ? c : nil
    }
}

extension BulkDraftManager {
    /// Puts what Swift read from the user's words onto an item. Only the fields the user changed.
    static func apply(_ patch: DraftPatch, to item: inout DraftItem) {
        let p = patch.probe
        if patch.sets.contains("day"), item.kind == .task {
            item.due = p.due
            item.softDue = p.softDue
            item.unparsed["date"] = p.unparsed["date"]
            // "tomorrow evening": the part of the day travels with the day.
            if !patch.sets.contains("time"), let s = p.slot { item.slot = s; item.timeMinutes = nil }
        }
        if patch.sets.contains("time") {
            if let m = p.timeMinutes { item.timeMinutes = m; item.slot = nil }
            else if let s = p.slot { item.slot = s; item.timeMinutes = nil }
            item.unparsed["time"] = p.unparsed["time"]
        }
        if patch.sets.contains("repeat") {
            if p.kind == .routine {
                item.kind = .routine
                item.recurrence = p.recurrence
                item.schedule = p.schedule
                item.due = nil
                item.softDue = nil
                item.unparsed["repeat"] = nil
                if !patch.sets.contains("time") {
                    if let m = p.timeMinutes { item.timeMinutes = m; item.slot = nil }
                    else if item.timeMinutes == nil, item.slot == nil { item.slot = p.slot }
                }
            } else if let raw = p.unparsed["repeat"] {
                // Kept as said and flagged on the card; nothing is guessed from it.
                item.schedule = p.schedule
                item.unparsed["repeat"] = raw
            } else {
                // "once", "just once": the item stops repeating.
                item.kind = .task
                item.recurrence = nil
                item.schedule = nil
                item.unparsed["repeat"] = nil
            }
        }
    }
}

#if canImport(FoundationModels)
@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
@Generable
enum EditOutcome: String, Codable {
    case change
    case answer
    case clarify
    case unrelated
}

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
@Generable
struct TaskChange {
    @Guide(description: "Ref of the task, as listed, such as d1")
    var target: String
    @Guide(description: "New title, only if the user renamed or corrected it")
    var title: String?
    @Guide(description: "A repeat the user asked for, in their words. Omit if unchanged")
    var schedule: String?
    @Guide(description: "Person the user named for this task. Omit if unchanged")
    var assignee: String?
    @Guide(description: "Day the user said, in their words, such as Friday. Omit if unchanged")
    var dueDate: String?
    @Guide(description: "Time or part of the day the user said, such as 5 pm or evening. Omit if unchanged")
    var dueTime: String?
    @Guide(description: "A reason the user stated, in their words. Omit if unchanged")
    var purpose: String?
    @Guide(description: "A quantity, dosage or preference the user stated. Omit if unchanged")
    var instructions: String?
    @Guide(description: "Name of a different list the user moved it to. Omit if unchanged")
    var listName: String?
    @Guide(description: "Names of fields to empty, such as day or time. Omit if none", .maximumCount(6))
    var clear: [String]?
}

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
@Generable
struct TaskEditing {
    @Guide(description: "change, answer, clarify, or unrelated")
    var outcome: EditOutcome
    @Guide(description: "A short reply, only for an answer")
    var answer: String?
    @Guide(description: "One essential question, only for a clarify")
    var question: String?
    @Guide(description: "A different list for the added tasks. Omit to keep the draft's list")
    var listName: String?
    // Optional on purpose: a required array made the model pad update, remove and clear with entries nobody asked for.
    @Guide(description: "New tasks to add. Omit if none", .maximumCount(12))
    var add: [TaskDraft]?
    @Guide(description: "Tasks that change, one entry per task. Omit if none", .maximumCount(12))
    var update: [TaskChange]?
    @Guide(description: "Refs of the tasks to remove. Omit if none", .maximumCount(12))
    var remove: [String]?

    var value: FlatEditValue {
        let word: String
        switch outcome {
        case .change: word = "change"
        case .answer: word = "answer"
        case .clarify: word = "clarify"
        case .unrelated: word = "unrelated"
        }
        let name = listName
        let added = (add ?? []).map {
            ExtractionTaskValue(title: $0.title, schedule: $0.schedule, assignee: $0.assignee, dueDate: $0.dueDate, dueTime: $0.dueTime,
                                purpose: $0.purpose, instructions: $0.instructions, listName: name)
        }
        let changed = (update ?? []).map {
            FlatEditUpdateValue(target: $0.target, title: $0.title, schedule: $0.schedule, assignee: $0.assignee, dueDate: $0.dueDate,
                                dueTime: $0.dueTime, purpose: $0.purpose, instructions: $0.instructions, listName: $0.listName, clear: $0.clear ?? [])
        }
        return FlatEditValue(outcome: word, answer: answer, question: question, listName: name, add: added, update: changed, remove: remove ?? [])
    }
}

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
@Generable
enum TaskIntentKind: String, Codable {
    case create
    case change
    case query
    case unrelated
}

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
@Generable
struct TaskIntent {
    @Guide(description: "create, change, query, or unrelated")
    var intent: TaskIntentKind
    @Guide(description: "True when the user takes back or fixes something they just said")
    var correction: Bool

    var value: FlatIntentValue { FlatIntentValue(intent: intent.rawValue, correction: correction) }
}

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
@Generable
struct ContentQuestion {
    @Guide(description: "One short question asking what the user wants to add. One sentence ending with a question mark")
    var question: String
}
#endif
