import SwiftUI

// MARK: - One form for a task of the draft and a saved task
//
// The draft sheet and the saved-task sheet show the same fields, built here once, and read them back with the same `commit()`, so the
// two cannot drift apart. What differs (where the data goes, what else the sheet offers) stays in the sheets.

/// Which task the form is for. A saved task that is today's copy of a routine cannot change its repeat here.
enum TaskFormMode: Equatable {
    case draft
    case saved(routineCopy: Bool, partOfBigger: Bool)

    var isSaved: Bool { if case .saved = self { return true } else { return false } }
    var routineCopy: Bool { if case .saved(let copy, _) = self { return copy } else { return false } }
    var partOfBigger: Bool { if case .saved(_, let bigger) = self { return bigger } else { return false } }
}

/// What the form edits: the item, and the day and time as the pickers hold them. `commit()` writes them back and touches a day or a
/// time only when the user changed it, so opening and saving without a change leaves the task as it was.
struct TaskFormState {
    var item: DraftItem
    var hasDay: Bool
    var day: Date
    var hasTime: Bool
    var time: Date
    /// The repeat in the user's words ("every morning"). On a draft it is read again by Swift when it was changed; on a saved task it is
    /// kept as the user's words and does not make a routine.
    var repeatWords: String
    let originalRepeat: String
    let mode: TaskFormMode
    private let originalDay: Date?
    private let originalMinutes: Int?
    /// The item as it was opened: what the user changes by hand is marked "added by you" against it.
    let original: DraftItem

    init(draft base: DraftItem, mode: TaskFormMode = .draft) {
        item = base
        original = base
        self.mode = mode
        hasDay = base.due != nil
        day = base.due ?? Date()
        hasTime = base.timeMinutes != nil
        let minutes = base.timeMinutes ?? 9 * 60
        time = Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date()) ?? Date()
        let words = base.unparsed["repeat"] ?? (base.kind == .routine ? (base.schedule ?? base.recurrence?.scheduleText ?? "") : (base.schedule ?? ""))
        repeatWords = words
        originalRepeat = words
        originalDay = base.due
        originalMinutes = base.timeMinutes
    }

    var canSave: Bool { TaskMeaning.isMeaningful(title: item.title) }
    /// A title is typed but says nothing a task could be ("create", "new task"): Save stays off and this says why.
    var titleSaysNothing: Bool { !item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !canSave }

    private var dayChanged: Bool {
        guard hasDay == (originalDay != nil) else { return true }
        guard hasDay, let originalDay else { return false }
        return !Calendar.current.isDate(day, inSameDayAs: originalDay)
    }

    private var minutesNow: Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: time)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    private var timeChanged: Bool {
        guard hasTime == (originalMinutes != nil) else { return true }
        return hasTime && minutesNow != originalMinutes
    }

    /// The item as the form leaves it.
    func commit() -> DraftItem {
        var out = item
        let words = TaskDraftMapper.clean(repeatWords)
        if words != TaskDraftMapper.clean(originalRepeat) {
            if mode.isSaved {
                out.schedule = words
            } else if let words, let probe = TaskDraftMapper.item(from: ExtractionTaskValue(title: "x", schedule: words)) {
                // A repeat changed on a draft is read by the same reader as a spoken one.
                BulkDraftManager.apply(DraftPatch(sets: ["repeat"], probe: probe), to: &out)
            } else {
                BulkDraftManager.apply(DraftPatch(sets: ["repeat"], probe: DraftItem(title: "x")), to: &out)
            }
        }
        out.title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        out.listName = TaskDraftMapper.clean(item.listName)
        out.reason = TaskDraftMapper.clean(item.reason)
        out.instructions = TaskDraftMapper.clean(item.instructions)
        out.softDue = hasDay ? nil : TaskDraftMapper.clean(item.softDue)
        if out.kind == .task {
            if dayChanged { out.due = hasDay ? Calendar.current.startOfDay(for: day) : nil }
            if hasDay { out.unparsed["date"] = nil }
            if timeChanged {
                if hasTime {
                    out.timeMinutes = minutesNow
                    out.slot = nil
                    out.unparsed["time"] = nil
                } else {
                    out.timeMinutes = nil
                }
            }
        }
        EvidenceGate.markHandEdits(&out, from: original)
        return out
    }
}

/// A saved task as a draft item, and back. The saved task is the one that is changed: everything the form does not edit is kept.
enum TaskFormBridge {
    static func draft(from t: TaskItem) -> DraftItem {
        var d = DraftItem(title: t.title)
        d.due = t.dueDate
        d.timeMinutes = t.timeMinutes
        d.slot = t.slot
        d.assignee = t.assignee
        d.priority = t.priority
        d.categoryName = t.categoryName
        d.reason = t.reason
        d.instructions = t.instructions
        d.listName = t.listName
        d.softDue = t.softDue
        d.schedule = t.schedule
        d.notes = t.notes
        d.evidence = t.evidence ?? [:]
        return d
    }

    /// Writes the form's fields onto the task. Kept as they are: id, done state, routine, list (the sheet resolves the list), category,
    /// labels, utterance, created and completed times, said, and notes. A routine's copy keeps its repeat.
    static func apply(_ draft: DraftItem, to task: TaskItem) -> TaskItem {
        var out = task
        out.title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        out.reason = draft.reason
        out.instructions = draft.instructions
        if task.routineID == nil { out.schedule = draft.schedule }
        out.softDue = draft.softDue
        out.dueDate = draft.due
        out.timeMinutes = draft.timeMinutes
        out.slot = draft.slot
        out.assignee = draft.assignee
        out.priority = draft.priority
        out.evidence = draft.evidence.isEmpty ? nil : draft.evidence
        return out
    }
}

/// The Form sections for one task. `afterDetails` is for what only one sheet has between "Details" and "When" (the draft's evidence).
struct TaskFieldsForm<AfterDetails: View>: View {
    @Binding var form: TaskFormState
    let people: [String]
    /// The first choice of the person picker: "No one", or what the task falls back to.
    var noPersonLabel = "No one"
    @ViewBuilder var afterDetails: () -> AfterDetails

    private var mode: TaskFormMode { form.mode }

    private func text(_ get: @escaping (DraftItem) -> String?, _ set: @escaping (inout DraftItem, String?) -> Void) -> Binding<String> {
        Binding(get: { get(form.item) ?? "" }, set: { new in set(&form.item, new.isEmpty ? nil : new) })
    }

    var body: some View {
        Section {
            TextField("What needs to be done", text: $form.item.title, axis: .vertical)
        } header: { Text("Task") } footer: {
            if form.titleSaysNothing { Text("Say what the task is, for example “Call mom”.").foregroundStyle(.red) }
            else if mode.partOfBigger { Text("This changes only this task, not the routine or playbook it came from.") }
        }
        // What the stored values were backed by when the sheet opened: the user's words, or "added by you". Nothing for a task saved
        // before this was kept, and nothing is shown for a value that was not stored.
        if let words = EvidenceGate.caption(evidence: form.original.evidence, assignee: form.original.assignee, due: form.original.due,
                                            timeMinutes: form.original.timeMinutes, slot: form.original.slot, softDue: form.original.softDue,
                                            category: form.original.categoryName,
                                            repeatText: form.original.kind == .routine ? form.original.recurrence?.scheduleText : nil) {
            Section { Text(words).font(.caption).foregroundStyle(.secondary) } header: { Text("Your words") }
        }
        Section {
            TextField("List (optional)", text: text({ $0.listName }, { $0.listName = $1 }))
        } header: { Text("List") } footer: {
            Text(mode.isSaved ? "A list that does not exist yet is made when you save." : "Tasks with the same list name are saved together on that list.")
        }
        Section("Details") {
            TextField("Why (optional)", text: text({ $0.reason }, { $0.reason = $1 }), axis: .vertical)
            TextField("How: amount, dose, method (optional)", text: text({ $0.instructions }, { $0.instructions = $1 }), axis: .vertical)
            if mode.isSaved, let notes = form.item.notes, !notes.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Notes").font(.caption).foregroundStyle(.secondary)
                    Text(notes).font(.callout)
                }
            }
        }
        afterDetails()
        if form.item.kind == .task {
            Section {
                Toggle("Due day", isOn: $form.hasDay)
                if form.hasDay { DatePicker("Day", selection: $form.day, displayedComponents: .date) }
                Toggle("Time", isOn: $form.hasTime)
                if form.hasTime { DatePicker("Time", selection: $form.time, displayedComponents: .hourAndMinute) }
                if !form.hasTime {
                    Picker("Part of the day", selection: Binding(get: { form.item.slot?.rawValue ?? "" }, set: { form.item.slot = DaySlot(rawValue: $0) })) {
                        Text("None").tag("")
                        ForEach(DaySlot.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                }
                TextField("Timeframe, like next week (optional)", text: text({ $0.softDue }, { $0.softDue = $1 }))
                    .disabled(form.hasDay)
                ForEach(form.item.unparsed.sorted(by: { $0.key < $1.key }).filter { $0.key == "date" || $0.key == "time" }, id: \.key) { field, raw in
                    Label("I couldn't read the \(field == "date" ? "day" : "time"): “\(raw)”. Pick one above or leave it.", systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote).foregroundStyle(.orange)
                }
            } header: { Text("When") } footer: { if form.hasDay { Text("A timeframe is used when there is no due day.") } }
        }
        Section {
            TextField("Repeat, like every morning (optional)", text: $form.repeatWords)
                .disabled(mode.routineCopy)
            if let r = form.item.recurrence, form.item.kind == .routine, form.repeatWords == form.originalRepeat {
                Text("Repeats " + r.scheduleText.lowercased()).font(.footnote).foregroundStyle(.secondary)
            }
            if let raw = form.item.unparsed["repeat"], form.repeatWords == form.originalRepeat {
                Label("I couldn't read the repeat: “\(raw)”. Say it another way or leave it empty.", systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote).foregroundStyle(.orange)
            }
        } header: { Text("Repeat") } footer: {
            if mode.routineCopy { Text("This is today's copy of a routine. Change the repeat on the routine itself.") }
            else if mode.isSaved { Text("Saved as your words. It doesn't turn this into a repeating routine.") }
        }
        Section("Priority") {
            Picker("Priority", selection: Binding(get: { form.item.priority ?? "" }, set: { form.item.priority = $0.isEmpty ? nil : $0 })) {
                Text("None").tag("")
                Text("Low").tag("low")
                Text("Medium").tag("medium")
                Text("High").tag("high")
            }
            .pickerStyle(.segmented)
        }
        Section("Person") {
            Picker("For", selection: Binding(get: { form.item.assignee.map { mode.isSaved ? Assignee.normalize($0) : $0 } ?? "" },
                                             set: { form.item.assignee = $0.isEmpty ? nil : $0 })) {
                Text(noPersonLabel).tag("")
                ForEach(people, id: \.self) { Text($0).tag($0) }
            }
        }
    }
}

extension TaskFieldsForm where AfterDetails == EmptyView {
    init(form: Binding<TaskFormState>, people: [String], noPersonLabel: String = "No one") {
        self.init(form: form, people: people, noPersonLabel: noPersonLabel, afterDetails: { EmptyView() })
    }
}
