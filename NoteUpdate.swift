import Foundation

// MARK: - When a note is edited, what changes in the tasks made from it

/// What an edited note would do to the tasks that were made from it: change some, add some, and offer to remove those whose words
/// are gone. Worked out by Swift from the words, with no model call: the edited note was already read into a draft.
struct NoteUpdatePlan {
    struct Change: Identifiable {
        var id: UUID { task.id }
        let task: TaskItem
        let draft: DraftItem
        /// One short line for each thing that changes: "Buy milk → Buy 2 litres of milk", "Day: Thu 29 Oct → Fri 30 Oct".
        let lines: [String]
    }

    var changes: [Change] = []
    var additions: [DraftItem] = []
    var removals: [TaskItem] = []
    /// Tasks the edit left exactly as they were.
    var unchanged = 0

    var isEmpty: Bool { changes.isEmpty && additions.isEmpty && removals.isEmpty }
}

/// What the user ticked. Changes and additions start ticked; removals start unticked, so nothing is ever deleted without a tick.
struct NoteUpdateChoice: Equatable {
    var changes: Set<UUID>
    var additions: Set<UUID>
    var removals: Set<UUID> = []

    init(for plan: NoteUpdatePlan) {
        changes = Set(plan.changes.map(\.id))
        additions = Set(plan.additions.map(\.id))
    }

    var isEmpty: Bool { changes.isEmpty && additions.isEmpty && removals.isEmpty }
}

/// The sheet that shows a plan: one at a time, gone when it is applied or cancelled. Nothing in it is kept.
struct NoteUpdateSession: Identifiable {
    let id = UUID()
    let noteID: UUID
    let plan: NoteUpdatePlan
}

enum NoteUpdate {
    private static let small: Set<String> = ["a", "an", "the", "to", "for", "of", "and", "my", "please", "some", "any", "on", "in", "at"]

    private static func tokens(_ text: String) -> Set<String> {
        Set(text.lowercased().split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init).filter { !small.contains($0) })
    }

    /// How alike two titles are, 0 to 1 (shared words over all words).
    static func similarity(_ a: String, _ b: String) -> Double {
        let x = tokens(a), y = tokens(b)
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        return Double(x.intersection(y).count) / Double(x.union(y).count)
    }

    /// Titles that are the same, or at least this alike, are the same task reworded.
    static let sameTaskThreshold = 0.5

    static func plan(tasks: [TaskItem], drafts: [DraftItem], calendar: Calendar = .current) -> NoteUpdatePlan {
        var plan = NoteUpdatePlan()
        var freeDrafts = drafts
        var freeTasks: [TaskItem] = []

        func pair(_ task: TaskItem, _ draft: DraftItem) {
            let lines = differences(task, draft, calendar: calendar)
            if lines.isEmpty { plan.unchanged += 1 } else { plan.changes.append(.init(task: task, draft: draft, lines: lines)) }
        }

        // The same title first, then the closest wording.
        for task in tasks {
            if let i = freeDrafts.firstIndex(where: { Words.key($0.title) == Words.key(task.title) }) {
                pair(task, freeDrafts.remove(at: i))
            } else {
                freeTasks.append(task)
            }
        }
        var left: [TaskItem] = []
        for task in freeTasks {
            let scored = freeDrafts.enumerated().map { ($0.offset, similarity(task.title, $0.element.title)) }
            if let best = scored.max(by: { $0.1 < $1.1 }), best.1 >= sameTaskThreshold {
                pair(task, freeDrafts.remove(at: best.0))
            } else {
                left.append(task)
            }
        }
        plan.additions = freeDrafts
        plan.removals = left
        return plan
    }

    /// What the edited words would change on a saved task. Only what the words now say is compared: a value the edit no longer
    /// mentions is left alone, never cleared.
    static func differences(_ task: TaskItem, _ draft: DraftItem, calendar: Calendar) -> [String] {
        var out: [String] = []
        func day(_ d: Date?) -> String { d.map { $0.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) } ?? "no day" }
        if Words.key(task.title) != Words.key(draft.title) { out.append("\(task.title) → \(draft.title)") }
        if let d = draft.due, task.dueDate.map({ !calendar.isDate($0, inSameDayAs: d) }) ?? true {
            out.append("Day: \(day(task.dueDate)) → \(day(d))")
        }
        if let m = draft.timeMinutes, m != task.timeMinutes {
            out.append("Time: \(task.timeMinutes.map { DaySlot.clockLabel($0) } ?? "none") → \(DaySlot.clockLabel(m))")
        }
        if let a = draft.assignee, !a.isEmpty, Assignee.normalize(a) != Assignee.normalize(task.assignee ?? "") {
            out.append("For: \(task.assignee.map { Assignee.normalize($0) } ?? "no one") → \(Assignee.normalize(a))")
        }
        if let n = draft.instructions, !n.isEmpty, n != task.instructions { out.append("Details: \(task.instructions ?? "none") → \(n)") }
        if let r = draft.reason, !r.isEmpty, r != task.reason { out.append("Why: \(task.reason ?? "none") → \(r)") }
        if let s = draft.softDue, !s.isEmpty, s != task.softDue { out.append("Around: \(task.softDue ?? "none") → \(s)") }
        return out
    }

    /// Does what was ticked. Returns the ids of the tasks added, so the note remembers them.
    @MainActor
    static func apply(_ plan: NoteUpdatePlan, choice: NoteUpdateChoice, store: TaskStore, calendar: Calendar = .current)
        -> (added: [UUID], changed: Int, removed: Int) {
        var changed = 0
        for c in plan.changes where choice.changes.contains(c.id) {
            var t = c.task
            let d = c.draft
            t.title = d.title
            if let day = d.due { t.dueDate = calendar.startOfDay(for: day) }
            if let m = d.timeMinutes { t.timeMinutes = m } else if let s = d.slot { t.slot = s }
            if let a = d.assignee, !a.isEmpty { t.assignee = a }
            if let n = d.instructions, !n.isEmpty { t.instructions = n }
            if let r = d.reason, !r.isEmpty { t.reason = r }
            if let s = d.softDue, !s.isEmpty { t.softDue = s }
            if store.update(t) { changed += 1 }
        }
        let added = store.addMany(plan.additions.filter { choice.additions.contains($0.id) }.map { $0.planned() })
        var removed = 0
        for t in plan.removals where choice.removals.contains(t.id) { store.remove(t.id); removed += 1 }
        return (added.map(\.id), changed, removed)
    }
}
