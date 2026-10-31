import Foundation

// MARK: - What a task says about itself, line by line
//
// The one place that decides which of the user's words are shown under a title: on a preview row, on a saved task card. It is pure
// (no SwiftUI), so a field added later (a quantity, a place) is one more case and one more line here, and every surface shows it.

/// One line under a task's title: a short label ("Why") and the user's words.
struct TaskDetailLine: Identifiable, Equatable {
    enum Kind: String, Equatable { case why, how, repeats, around, forWhom, flag, evidence }
    var kind: Kind
    var label: String
    var value: String
    var id: String { kind.rawValue + "|" + value }
    /// A flagged line is something Kitty could not read. It is shown in a warning colour.
    var isFlag: Bool { kind == .flag }
    /// "Why: for my knee", for VoiceOver and plain text.
    var text: String { label.isEmpty ? value : label + ": " + value }
}

enum TaskDetailLines {
    /// The system text a draft's unreadable repeat leaves in a saved task's notes (`DraftItem.planned`).
    static let unreadRepeatPrefix = "Repeat not understood:"

    /// `shownAsTag`: kinds a tag beside the title already says, so the line is left out.
    static func lines(for item: DraftItem, shownAsTag: Set<TaskDetailLine.Kind> = []) -> [TaskDetailLine] {
        var repeatLine: TaskDetailLine?
        if let raw = clean(item.unparsed["repeat"]) {
            repeatLine = flag(raw)
        } else if let said = clean(item.schedule) ?? item.recurrence.flatMap({ item.kind == .routine ? clean($0.scheduleText) : nil }) {
            repeatLine = TaskDetailLine(kind: .repeats, label: "Repeats", value: said)
        }
        var out = build(title: item.title, why: item.reason, how: item.instructions, repeatLine: repeatLine,
                        around: item.due == nil ? item.softDue : nil, person: item.assignee, shownAsTag: shownAsTag)
        // Each value and the user's words that backed it. On a draft only: a saved card shows what was kept, not why.
        if let text = EvidenceGate.caption(evidence: item.evidence, assignee: item.assignee, due: item.due, timeMinutes: item.timeMinutes,
                                           slot: item.slot, softDue: item.softDue, category: item.categoryName,
                                           repeatText: item.kind == .routine ? item.recurrence?.scheduleText : nil) {
            out.append(TaskDetailLine(kind: .evidence, label: "Your words", value: text))
        }
        return out
    }

    static func lines(for task: TaskItem, shownAsTag: Set<TaskDetailLine.Kind> = []) -> [TaskDetailLine] {
        var repeatLine: TaskDetailLine?
        if let raw = unreadRepeat(inNotes: task.notes) {
            repeatLine = flag(raw)
        } else if let said = clean(task.schedule) {
            repeatLine = TaskDetailLine(kind: .repeats, label: "Repeats", value: said)
        }
        // `notes` is never shown as the user's words: it can hold system text. Only an unreadable repeat in it is surfaced, as a flag.
        return build(title: task.title, why: task.reason, how: task.instructions, repeatLine: repeatLine,
                     around: task.dueDate == nil ? task.softDue : nil, person: task.assignee, shownAsTag: shownAsTag)
    }

    /// The repeat Swift could not read, out of a saved task's notes ("Repeat not understood: when I remember · other"), or nil.
    static func unreadRepeat(inNotes notes: String?) -> String? {
        guard let notes else { return nil }
        for part in notes.components(separatedBy: " · ") {
            let p = part.trimmingCharacters(in: .whitespacesAndNewlines)
            if p.hasPrefix(unreadRepeatPrefix) { return clean(String(p.dropFirst(unreadRepeatPrefix.count))) }
        }
        return nil
    }

    private static func flag(_ raw: String) -> TaskDetailLine {
        TaskDetailLine(kind: .flag, label: "", value: "Couldn't read the repeat: “\(raw)”")
    }

    private static func clean(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }

    private static func build(title: String, why: String?, how: String?, repeatLine: TaskDetailLine?, around: String?, person: String?,
                              shownAsTag: Set<TaskDetailLine.Kind>) -> [TaskDetailLine] {
        let titleKey = Words.key(title)
        var out: [TaskDetailLine] = []
        func add(_ line: TaskDetailLine) {
            guard !shownAsTag.contains(line.kind), !line.value.isEmpty else { return }
            if line.kind != .flag, Words.key(line.value) == titleKey { return }
            if out.contains(where: { $0.kind != .flag && $0.kind == line.kind && Words.key($0.value) == Words.key(line.value) }) { return }
            out.append(line)
        }
        if let v = clean(why) { add(TaskDetailLine(kind: .why, label: "Why", value: v)) }
        if let v = clean(how) { add(TaskDetailLine(kind: .how, label: "How", value: v)) }
        if let line = repeatLine { add(line) }
        if let v = clean(around) { add(TaskDetailLine(kind: .around, label: "Around", value: v)) }
        if let v = clean(person) { add(TaskDetailLine(kind: .forWhom, label: "For", value: v)) }
        return out
    }
}
