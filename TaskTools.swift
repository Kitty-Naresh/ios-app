import Foundation

// MARK: - Swift reads the household's tasks
//
// The model never searches. For a read-only question it returns search parameters and Swift runs them here, then writes the
// reply and shows the real records. For a change to a saved task the model is shown a short RECENT TASKS block (built here) and
// names a task by the id on one of its lines; an id that is not on that list is dropped by Swift, never looked up.

/// A task as the model reads it. The id is stable: the first eight hex digits of the task's own id.
struct ToolRecord: Equatable {
    var id: String
    var title: String
    var status: String                // open or done
    var due: String                   // YYYY-MM-DD
    var assignee: String
    var category: String
    var list: String?
    var notes: String?
    var repeats: String?

    /// One line, the way the model reads it: `[3fa8c1d2] Order Food | open | due 2026-10-26 | for Me | category Food | list Blinkit order`.
    var line: String {
        var parts = ["[\(id)] \(title)", status, "due \(due)", "for \(assignee)", "category \(category)"]
        if let list { parts.append("list \(list)") }
        if let repeats { parts.append("repeats \(repeats)") }
        if let notes, !notes.isEmpty { parts.append("notes \(notes.prefix(80))") }
        return parts.joined(separator: " | ")
    }
}

/// Reads the real store. Plain Swift, so the tests can call it directly. Nothing here is a model tool.
@MainActor
final class TaskToolbox {
    static let maxResults = 12
    /// How many saved tasks a change request shows the model: the most recently created, newest first.
    static let recentCount = 8
    let store: TaskStore

    init(store: TaskStore = .shared) { self.store = store }

    static func shortID(_ id: UUID) -> String { String(id.uuidString.lowercased().prefix(8)) }

    static func isoDay(_ date: Date, calendar: Calendar = .current) -> String {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    func record(_ t: TaskItem) -> ToolRecord {
        ToolRecord(id: Self.shortID(t.id), title: t.title, status: t.isDone ? "done" : "open", due: t.dueDate.map { Self.isoDay($0) } ?? "",
                   assignee: t.effectiveAssignee, category: t.categoryLabel, list: t.listName,
                   notes: t.notes, repeats: t.routineID.flatMap { rid in store.routines.first { $0.id == rid }?.scheduleText })
    }

    /// The task behind an id the model gave: the short id, or a full id. Nil when no task has it, or when more than one does.
    func resolve(_ raw: String) -> TaskItem? {
        let id = raw.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[] \n\t"))
        guard id.count >= 6 else { return nil }
        let hits = store.tasks.filter { $0.id.uuidString.lowercased().hasPrefix(id) }
        return hits.count == 1 ? hits[0] : nil
    }

    /// Tasks matching every filter that is given. Every filter is optional; `query` words must each appear in the title, notes, the
    /// category or the list. At most `maxResults` come back, in the order the app shows tasks, and the total is said.
    func search(query: String = "", status: String = "open", day: String = "", assignee: String = "", list: String = "",
                now: Date = Date(), calendar: Calendar = .current) -> (records: [ToolRecord], total: Int) {
        var items = store.tasks
        switch status.lowercased() {
        case "done": items = items.filter(\.isDone)
        case "all": break
        default: items = items.filter { !$0.isDone }
        }
        let today = calendar.startOfDay(for: now)
        switch day.lowercased().trimmingCharacters(in: .whitespaces) {
        case "", "any": break
        case "today": items = items.filter { calendar.isDate($0.effectiveDue, inSameDayAs: today) }
        case "tomorrow":
            if let t = calendar.date(byAdding: .day, value: 1, to: today) { items = items.filter { calendar.isDate($0.effectiveDue, inSameDayAs: t) } }
        case "overdue": items = items.filter { calendar.startOfDay(for: $0.effectiveDue) < today && !$0.isDone }
        case let iso:
            if let d = BulkValidator.date(iso, calendar: calendar) { items = items.filter { calendar.isDate($0.effectiveDue, inSameDayAs: d) } }
        }
        let who = assignee.trimmingCharacters(in: .whitespaces)
        if !who.isEmpty {
            let n = Assignee.normalize(who).lowercased()
            items = items.filter { $0.isFor([n]) }
        }
        let listName = list.trimmingCharacters(in: .whitespaces)
        if !listName.isEmpty { items = items.filter { $0.isOnList(listName) } }
        let words = query.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        if !words.isEmpty {
            items = items.filter { t in
                let hay = ([t.title, t.notes ?? "", t.categoryLabel, t.listName ?? "", t.storedWords]).joined(separator: " ").lowercased()
                return words.allSatisfy { hay.contains($0) }
            }
        }
        let ordered = TaskSorting.ordered(items, acrossDays: true)
        return (ordered.prefix(Self.maxResults).map(record), ordered.count)
    }

    // MARK: What the model is shown for a change

    /// The most recently created saved tasks, newest first (the store puts new tasks at the front).
    func recent(limit: Int = TaskToolbox.recentCount) -> [ToolRecord] {
        store.tasks.prefix(limit).map(record)
    }

    /// The RECENT TASKS block of a change request: one line per task with its id. Empty when nothing is saved.
    func recentBlock(limit: Int = TaskToolbox.recentCount) -> String {
        let r = recent(limit: limit)
        guard !r.isEmpty else { return "" }
        return "RECENT TASKS (saved; name a task only by the id in brackets; if the one meant is not here, say so with action clarify):\n"
            + r.map(\.line).joined(separator: "\n")
    }
}

// MARK: The last five tasks created, for a spoken change

extension TaskToolbox {
    /// How many saved tasks a spoken change can name.
    static let editWindow = 5

    /// The last five tasks created (by `createdAt`, newest first) as t1 … t5. Copies of a routine and tasks saved before the
    /// creation time was kept are not offered: they are not something the user just made.
    func recentFive() -> [(ref: String, task: TaskItem)] {
        let made = store.tasks
            .filter { $0.createdAt != nil && $0.routineID == nil }
            .sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
        return made.prefix(Self.editWindow).enumerated().map { (ref: "t\($0.offset + 1)", task: $0.element) }
    }

    /// A saved task in the shape the draft describer reads, so the edit call sees a saved task like a draft item.
    func asDraft(_ t: TaskItem) -> DraftItem {
        var d = DraftItem(title: t.title)
        d.due = t.dueDate
        d.timeMinutes = t.timeMinutes
        if t.timeMinutes == nil { d.slot = t.slot }
        d.assignee = t.assignee
        d.priority = t.priority
        d.categoryName = t.categoryName
        d.reason = t.reason
        d.instructions = t.instructions
        d.listName = t.listName
        d.softDue = t.softDue
        return d
    }
}

extension TaskItem {
    /// Is it on the list people call `name`? "Blinkit" finds the list "Blinkit order". Looks at the task's own list only.
    func isOnList(_ name: String) -> Bool {
        guard let list = listName else { return false }
        if TaskLabels.same(list, name) { return true }
        let short = TaskLabels.listShort(list)
        return !short.isEmpty && TaskLabels.same(short, name)
    }
}
