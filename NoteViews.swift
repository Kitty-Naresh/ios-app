import SwiftUI

// MARK: - What a note shows about Kitty's work on it

/// The one small thing shown in the corner of a note's bubble: Kitty is reading it, a preview of its tasks is waiting, or tasks were made.
enum NoteStatus: Equatable {
    case working
    case ready
    /// Tasks were found earlier and never saved: tapping reads the note again.
    case review
    case created(Int)

    /// Working beats everything; a waiting preview beats one left from before; tasks already made come last; nothing shows when there
    /// is nothing to say.
    static func of(working: Bool, previewForThisNote: Bool, reviewPending: Bool = false, createdCount: Int) -> NoteStatus? {
        if working { return .working }
        if previewForThisNote { return .ready }
        if reviewPending { return .review }
        return createdCount > 0 ? .created(createdCount) : nil
    }

    var text: String? {
        switch self {
        case .working: return nil
        case .ready: return "Tasks ready"
        case .review: return "Review tasks"
        case .created(let n): return n == 1 ? "1 task created" : "\(n) tasks created"
        }
    }

    var symbol: String {
        switch self {
        case .working: return "sparkles"
        case .ready, .review: return "checklist"
        case .created: return "checkmark.circle.fill"
        }
    }

    var spoken: String {
        switch self {
        case .working: return "Kitty is reading this note"
        case .ready: return "Tasks are ready to review"
        case .review: return "Tasks were found in this note. Tap to review them"
        case .created(let n): return n == 1 ? "1 task created" : "\(n) tasks created"
        }
    }
}

/// The status in the bubble's bottom-right corner, small and quiet like the ticks in a messaging app. Working pulses (or sits still
/// when Reduce Motion is on); the other two are tappable.
struct NoteStatusChip: View {
    let status: NoteStatus
    var onTap: (() -> Void)? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var tint: Color { status == .working ? Color.secondary : Color.accentColor }

    private var content: some View {
        HStack(spacing: 4) {
            Image(systemName: status.symbol)
                .symbolEffect(.pulse, options: .repeating, isActive: status == .working && !reduceMotion)
            if let text = status.text { Text(text) }
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(tint)
        .contentShape(Rectangle())
    }

    var body: some View {
        Group {
            if let onTap {
                Button(action: onTap) { content }.buttonStyle(.plain)
            } else {
                content
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(status.spoken)
        .accessibilityAddTraits(onTap == nil ? [] : .isButton)
    }
}

// MARK: - The sheets a note opens

enum NoteSheet: Identifiable {
    /// What Kitty did for a note; nil means the words being worked on right now.
    case details(UUID?)
    /// The tasks made from a note.
    case tasks(UUID)
    /// A long note, in full.
    case read(UUID)

    var id: String {
        switch self {
        case .read(let id): return "read-\(id.uuidString)"
        case .details(let id): return "details-\(id?.uuidString ?? "now")"
        case .tasks(let id): return "tasks-\(id.uuidString)"
        }
    }
}

/// "See details" for a note: the steps of the work on it while it is the latest, or the details kept with a task made from it.
struct NoteDetailsSheet: View {
    let task: TaskItem?
    let showLive: Bool
    let working: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let task {
            TaskDetailsView(task: task)
        } else {
            NavigationStack {
                ScrollView {
                    if showLive {
                        LiveModelPanel(feed: LiveFeed.shared, working: working, startsOpen: true).padding()
                    } else {
                        VStack(spacing: 8) {
                            Image(systemName: "doc.text.magnifyingglass").font(.largeTitle).foregroundStyle(.secondary)
                            Text("No details were kept for this note.").font(.headline)
                            Text("Details are kept for the latest note, and with the tasks it made.")
                                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                        .padding(.horizontal, 24)
                    }
                }
                .navigationTitle("What Kitty did")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            }
            .presentationDetents([.medium, .large])
        }
    }
}

/// "View tasks": the tasks made from one note.
struct NoteTasksSheet: View {
    let ids: [UUID]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                if ids.isEmpty {
                    Text("These tasks are gone.").foregroundStyle(.secondary).padding(.top, 60)
                } else {
                    CreatedTasks(ids: ids).padding()
                }
            }
            .navigationTitle("Tasks from this note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Editing a note

struct NoteEditTarget: Identifiable {
    let id: UUID
    let text: String
}

/// The note on a full screen, to read and change. Return adds a line. Done hands the new words to Kitty, who looks for tasks in them
/// again; Cancel leaves the note as it was (and asks first if there are changes).
struct NoteEditorView: View {
    let original: String
    let onDone: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var askDiscard = false
    @FocusState private var focused: Bool

    init(original: String, onDone: @escaping (String) -> Void) {
        self.original = original
        self.onDone = onDone
        _text = State(initialValue: original)
    }

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var changed: Bool { trimmed != original.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                .font(.body)
                .focused($focused)
                .padding(.horizontal, 12)
                .navigationTitle("Edit note")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { if changed { askDiscard = true } else { dismiss() } }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { onDone(text); dismiss() }
                            .fontWeight(.semibold)
                            .disabled(!changed || trimmed.isEmpty)
                    }
                }
                .safeAreaInset(edge: .bottom) {
                    Text("When you tap Done, Kitty looks for tasks in this note again.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.bar)
                }
                .confirmationDialog("Discard your changes?", isPresented: $askDiscard, titleVisibility: .visible) {
                    Button("Discard changes", role: .destructive) { dismiss() }
                    Button("Keep editing", role: .cancel) {}
                }
        }
        .interactiveDismissDisabled(changed)
        .onAppear { focused = true }
    }
}

// MARK: - The chat list (the home screen)

/// Your chats, newest activity first: the title, the latest note and when. Tap to open. Press and hold to rename or delete. With no chat
/// yet it is one clear invitation to start one.
struct ChatListSection: View {
    @ObservedObject var chats: ChatsStore
    let open: (UUID) -> Void
    let startFirst: () -> Void
    @State private var renaming: Chat?
    @State private var renameText = ""
    @State private var deleting: Chat?

    var body: some View {
        Group {
            if chats.sorted.isEmpty { emptyState } else { list }
        }
        .alert("Rename chat", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Save") { if let chat = renaming { chats.rename(chat.id, to: renameText) }; renaming = nil }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .confirmationDialog("Delete this chat?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("Delete chat and its notes", role: .destructive) { if let chat = deleting { chats.delete(chat.id) }; deleting = nil }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: {
            Text("Tasks already made from these notes stay.")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "bubble.left.and.text.bubble.right.fill")
                .font(.system(size: 44))
                .foregroundStyle(Color.accentColor)
            Text("Chat with Kitty").font(.system(.title2, design: .rounded).weight(.bold))
            Text("Write or say what's on your mind. Kitty keeps your notes and finds the tasks in them.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(action: startFirst) {
                Text("Start a chat").font(.headline).padding(.horizontal, 22).padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .padding(.top, 4)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(chats.sorted) { chat in
                    row(chat)
                    Divider().padding(.leading, 56)
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    private func row(_ chat: Chat) -> some View {
        let latest = NotesStore.shared.latest(in: chat.id)
        let alive = Dictionary(uniqueKeysWithValues: TaskStore.shared.tasks.map { ($0.id, $0) })
        let open = Set(NotesStore.shared.load(chat: chat.id).flatMap(\.taskIDs)).filter { alive[$0]?.isDone == false }.count
        return Button { self.open(chat.id) } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(Color.accentColor.opacity(0.15))
                    Image(systemName: "text.bubble.fill").foregroundStyle(Color.accentColor)
                }
                .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(chat.title).font(.headline).lineLimit(1)
                        Spacer(minLength: 8)
                        Text(Self.stamp(latest?.createdAt ?? chat.updatedAt)).font(.caption).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 8) {
                        Text(latest.map { $0.text.replacingOccurrences(of: "\n", with: " ") } ?? "No notes yet")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        if open > 0 { Text("\(open) open").font(.caption.weight(.semibold)).foregroundStyle(Color.accentColor) }
                    }
                }
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Rename", systemImage: "pencil") { renameText = chat.title; renaming = chat }
            Button("Delete", systemImage: "trash", role: .destructive) { deleting = chat }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens this chat")
    }

    /// Today shows the time, yesterday says so, older shows the date.
    static func stamp(_ date: Date, now: Date = .now) -> String {
        let cal = Calendar.current
        if cal.isDate(date, inSameDayAs: now) { return date.formatted(date: .omitted, time: .shortened) }
        if let y = cal.date(byAdding: .day, value: -1, to: now), cal.isDate(date, inSameDayAs: y) { return "Yesterday" }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }
}

// MARK: - The update sheet

/// What an edit of a note would change in its tasks. Changes and new tasks start ticked; tasks whose words are gone start unticked and
/// are deleted only if ticked. It closes when applied or cancelled, and nothing in it is kept.
struct NoteUpdateSheet: View {
    let plan: NoteUpdatePlan
    let onApply: (NoteUpdateChoice) -> Void
    let onCancel: () -> Void
    @State private var choice: NoteUpdateChoice

    init(plan: NoteUpdatePlan, onApply: @escaping (NoteUpdateChoice) -> Void, onCancel: @escaping () -> Void) {
        self.plan = plan
        self.onApply = onApply
        self.onCancel = onCancel
        _choice = State(initialValue: NoteUpdateChoice(for: plan))
    }

    private func toggle(_ id: UUID, in keyPath: WritableKeyPath<NoteUpdateChoice, Set<UUID>>) -> Binding<Bool> {
        Binding(get: { choice[keyPath: keyPath].contains(id) },
                set: { on in if on { choice[keyPath: keyPath].insert(id) } else { choice[keyPath: keyPath].remove(id) } })
    }

    var body: some View {
        NavigationStack {
            List {
                if !plan.changes.isEmpty {
                    Section("Changed") {
                        ForEach(plan.changes) { change in
                            Toggle(isOn: toggle(change.id, in: \.changes)) {
                                VStack(alignment: .leading, spacing: 3) {
                                    ForEach(change.lines, id: \.self) { Text($0).font(.subheadline) }
                                }
                            }
                        }
                    }
                }
                if !plan.additions.isEmpty {
                    Section("New") {
                        ForEach(plan.additions) { draft in
                            Toggle(isOn: toggle(draft.id, in: \.additions)) { Text(draft.title).font(.subheadline) }
                        }
                    }
                }
                if !plan.removals.isEmpty {
                    Section {
                        ForEach(plan.removals) { task in
                            Toggle(isOn: toggle(task.id, in: \.removals)) { Text(task.title).font(.subheadline) }
                        }
                    } header: {
                        Text("No longer in the note")
                    } footer: {
                        Text("Ticked tasks are deleted. They stay unless you tick them.")
                    }
                }
                if plan.unchanged > 0 {
                    Section {
                        Text(plan.unchanged == 1 ? "1 task stays as it is." : "\(plan.unchanged) tasks stay as they are.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Update tasks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onCancel) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Update") { onApply(choice) }.fontWeight(.semibold).disabled(choice.isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// A long note in full, to read and select. Editing is in the editor.
struct NoteReadSheet: View {
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(text).font(.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding()
            }
            .navigationTitle("Note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

// MARK: - A day in the thread

/// "Today", "Yesterday" or the date, in the middle of the thread where a new day begins.
struct DaySeparator: View {
    let date: Date

    private var label: String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }

    var body: some View {
        Text(label)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color.primary.opacity(0.06), in: Capsule())
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Searching your notes

/// Every note in every chat that holds the words typed. Tapping one opens its chat.
struct NotesSearchSheet: View {
    @ObservedObject var chats: ChatsStore
    let open: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var results: [Note] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2 else { return [] }
        return Array(NotesStore.shared.load().filter { $0.text.localizedCaseInsensitiveContains(q) }.sorted { $0.createdAt > $1.createdAt }.prefix(50))
    }

    private func chatTitle(_ note: Note) -> String? { note.chatID.flatMap { id in chats.chats.first { $0.id == id }?.title } }

    var body: some View {
        NavigationStack {
            List(results) { note in
                Button {
                    if let id = note.chatID { dismiss(); open(id) }
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(note.text.replacingOccurrences(of: "\n", with: " ")).font(.subheadline).lineLimit(2)
                        Text([chatTitle(note), note.createdAt.formatted(.dateTime.day().month(.abbreviated))].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
            .overlay {
                if query.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2, results.isEmpty { ContentUnavailableView.search(text: query) }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search your notes")
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

// MARK: - The chat's task tray: tasks and nothing else

/// What the tray can narrow this chat's tasks to. Only these five, and only the ones that have tasks are offered.
enum ChatTaskFilter: String, CaseIterable, Identifiable {
    case open, today, overdue, done, all
    var id: String { rawValue }

    var title: String {
        switch self {
        case .open: return "Open"
        case .today: return "Today"
        case .overdue: return "Overdue"
        case .done: return "Done"
        case .all: return "All"
        }
    }

    func matchesAny(in tasks: [TaskItem]) -> Bool { tasks.contains(where: matches) }

    func matches(_ task: TaskItem) -> Bool {
        switch self {
        case .all: return true
        case .open: return !task.isDone
        case .done: return task.isDone
        case .overdue: return !task.isDone && task.isOverdue
        case .today: return !task.isDone && !task.isListItem && Calendar.current.isDateInToday(task.effectiveDue)
        }
    }

    /// Open tasks first: what is late, then by day, then the ones with no day in the order they were made; finished ones last.
    static func sorted(_ tasks: [TaskItem]) -> [TaskItem] {
        tasks.sorted { a, b in
            if a.isDone != b.isDone { return !a.isDone }
            if a.effectiveDue != b.effectiveDue { return a.effectiveDue < b.effectiveDue }
            return (a.createdAt ?? .distantPast) < (b.createdAt ?? .distantPast)
        }
    }
}

/// One task in the tray: a tick, the title and one quiet line (when, who, which list). A tap opens the full form.
struct ChatTaskRow: View {
    let task: TaskItem
    let lists: [TaskProfile]
    @State private var editing = false

    private var meta: String? {
        var parts: [String] = []
        let cal = Calendar.current
        if !task.isDone, task.isOverdue {
            parts.append(task.daysOverdue == 1 ? "1 day late" : "\(task.daysOverdue) days late")
        } else if let due = task.dueDate {
            if cal.isDateInToday(due) { parts.append("Today") }
            else if cal.isDateInTomorrow(due) { parts.append("Tomorrow") }
            else { parts.append(due.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))) }
        } else if let soft = task.softDue {
            parts.append(soft)
        }
        if let m = task.timeMinutes { parts.append(String(format: "%d:%02d", m / 60, m % 60)) }
        if let repeats = task.schedule, task.routineID != nil || !repeats.isEmpty { parts.append(repeats) }
        let who = task.effectiveAssignee
        if !who.isEmpty, who.lowercased() != Assignee.me.lowercased() { parts.append(who) }
        if let list = lists.first(where: { $0.id == task.profileID })?.name { parts.append(list) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 12) {
            Button { withAnimation { TaskStore.shared.toggle(task.id) } } label: {
                Image(systemName: task.isDone ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundStyle(task.isDone ? Color.green : (task.isOverdue ? Color.red : Color.secondary.opacity(0.7)))
            }
            .buttonStyle(.borderless)
            VStack(alignment: .leading, spacing: 1) {
                Text(task.title)
                    .font(.body)
                    .strikethrough(task.isDone)
                    .foregroundStyle(task.isDone ? Color.secondary : Color.primary)
                if let meta {
                    Text(meta).font(.caption).foregroundStyle(!task.isDone && task.isOverdue ? Color.red : Color.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture { editing = true }
        .accessibilityAction(named: "Edit") { editing = true }
        .contextMenu { TaskActions(task: task, onEdit: { editing = true }) }
        .sheet(isPresented: $editing) { TaskEditSheet(task: task) }
    }
}

// MARK: - One task tray, used on the home screen and in every chat

extension ChatTaskFilter {
    /// The views that have tasks in them, with their counts, in the order they are offered. One kind only means nothing to choose.
    static func available(in tasks: [TaskItem]) -> [(filter: ChatTaskFilter, count: Int)] {
        let all: [ChatTaskFilter] = [.open, .today, .overdue, .done, .all]
        let found = all.map { (filter: $0, count: tasks.filter($0.matches).count) }.filter { $0.count > 0 }
        return found.count == 1 ? [] : found
    }
}

/// The tasks and nothing else: a line that says what is shown (and a small menu for the other views when there are any), an optional
/// search box, then slim rows, in one list or grouped by list. The same view serves the home screen (every task, grouped, searchable)
/// and a chat (only that chat's tasks).
struct TaskTrayList: View {
    let tasks: [TaskItem]
    let lists: [TaskProfile]
    @Binding var filter: ChatTaskFilter
    var grouped = false
    var searchable = false
    /// A list's name when the tray shows one list.
    var heading: String? = nil
    @State private var query = ""

    private var shown: [TaskItem] {
        let narrowed = tasks.filter(filter.matches)
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ChatTaskFilter.sorted(q.isEmpty ? narrowed : narrowed.filter { $0.title.lowercased().contains(q) })
    }

    private var summary: String {
        let what = filter == .all ? "tasks" : filter.title.lowercased()
        return "\(shown.count) \(what)"
    }

    var body: some View {
        let kinds = ChatTaskFilter.available(in: tasks)
        VStack(spacing: 0) {
            HStack {
                if let heading { Text(heading).font(.headline).lineLimit(1) }
                Text(summary).font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                if kinds.count > 1 {
                    Menu {
                        ForEach(kinds, id: \.filter) { kind in
                            Button { filter = kind.filter } label: {
                                Label("\(kind.filter.title) · \(kind.count)", systemImage: kind.filter == filter ? "checkmark" : "")
                            }
                        }
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease.circle" + (filter == .open ? "" : ".fill")).font(.title3)
                    }
                    .accessibilityLabel("Show other tasks")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            if searchable {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search tasks", text: $query).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                .padding(.horizontal, 12)
                .frame(height: 36)
                .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .padding(.horizontal, 16)
                .padding(.bottom, 4)
            }
            if shown.isEmpty {
                Text(tasks.isEmpty ? "No tasks yet." : "Nothing here.").foregroundStyle(.secondary).padding(.top, 50)
                Spacer()
            } else if grouped {
                List {
                    ForEach(groups, id: \.name) { group in
                        Section {
                            ForEach(group.tasks) { row($0) }
                        } header: {
                            Text("\(group.name) · \(group.tasks.count)").font(.footnote.weight(.semibold)).textCase(nil)
                        }
                    }
                }
                .listStyle(.plain)
            } else {
                List { ForEach(shown) { row($0) } }.listStyle(.plain)
            }
        }
    }

    /// The tasks of each list, newest list first, then the tasks that are on no list.
    private var groups: [(name: String, tasks: [TaskItem])] {
        var byList: [UUID: [TaskItem]] = [:]
        var loose: [TaskItem] = []
        for task in shown { if let id = task.profileID { byList[id, default: []].append(task) } else { loose.append(task) } }
        let named = byList.compactMap { id, items -> (name: String, tasks: [TaskItem], newest: Date)? in
            guard let list = lists.first(where: { $0.id == id }) else { loose += items; return nil }
            return (list.name, items, items.compactMap(\.createdAt).max() ?? list.createdAt)
        }
        var out = named.sorted { $0.newest > $1.newest }.map { (name: $0.name, tasks: $0.tasks) }
        if !loose.isEmpty { out.append((name: "No list", tasks: ChatTaskFilter.sorted(loose))) }
        return out
    }

    private func row(_ task: TaskItem) -> some View {
        ChatTaskRow(task: task, lists: lists)
            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
            .swipeActions(edge: .trailing) {
                Button(role: .destructive) { withAnimation { TaskStore.shared.remove(task.id) } } label: { Label("Delete", systemImage: "trash") }
            }
            .swipeActions(edge: .leading) {
                Button { withAnimation { TaskStore.shared.toggle(task.id) } } label: {
                    Label(task.isDone ? "Reopen" : "Done", systemImage: task.isDone ? "arrow.uturn.backward" : "checkmark")
                }
                .tint(.green)
            }
    }
}

/// A chip in the peek bar.
struct PeekChip: Identifiable {
    let id: String
    let title: String
    var icon: String? = nil
    let count: Int
    var late = false
}

/// The way in to tasks, on the home screen and in every chat: a small grip and, under it, a row of chips for what is in the tray. Tap a
/// chip to open the tray on that view; tap the grip or swipe up on the bar to open it on the default view.
struct TaskPeekBar: View {
    let chips: [PeekChip]
    var onOpen: (String?) -> Void

    var body: some View {
        VStack(spacing: 2) {
            Capsule()
                .fill(Color.secondary.opacity(0.45))
                .frame(width: 40, height: 5)
                .frame(maxWidth: .infinity, minHeight: 18)
                .contentShape(Rectangle())
                .onTapGesture { onOpen(nil) }
                .accessibilityElement()
                .accessibilityLabel("Your tasks")
                .accessibilityHint("Opens the list of tasks")
                .accessibilityAddTraits(.isButton)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(chips) { chip in
                        Button { onOpen(chip.id) } label: {
                            HStack(spacing: 6) {
                                if let icon = chip.icon { Image(systemName: icon).font(.caption).foregroundStyle(chip.late ? Color.red : Color.secondary) }
                                Text(chip.title)
                                Text("\(chip.count)").opacity(0.65)
                            }
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 14)
                            .frame(minHeight: 40)
                            .foregroundStyle(chip.late ? Color.red : Color.primary)
                            .background(Color.cardBackground, in: Capsule())
                            .shadow(color: .black.opacity(0.05), radius: 3, y: 1)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(chip.title), \(chip.count)")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
            }
        }
        .simultaneousGesture(DragGesture(minimumDistance: 14).onEnded { drag in
            if drag.translation.height < -24, abs(drag.translation.height) > abs(drag.translation.width) { onOpen(nil) }
        })
    }
}

/// What the home screen's tray opens on: a view of every task, or one list.
struct HomeTrayChoice: Identifiable {
    let id = UUID()
    var filter: ChatTaskFilter
    var listID: UUID? = nil
}

/// The home screen's tray: every task, grouped by list and searchable; or just one list.
struct TaskTraySheet: View {
    @ObservedObject private var store = TaskStore.shared
    @Environment(\.dismiss) private var dismiss
    @State var filter: ChatTaskFilter
    let listID: UUID?

    private var scoped: [TaskItem] { listID == nil ? store.tasks : store.tasks.filter { $0.profileID == listID } }
    private var heading: String? { listID.flatMap { id in store.profiles.first { $0.id == id }?.name } }

    var body: some View {
        NavigationStack {
            TaskTrayList(tasks: scoped, lists: store.profiles, filter: $filter, grouped: listID == nil, searchable: true, heading: heading)
                .background(Color.screenBackground)
                .navigationTitle(listID == nil ? "All tasks" : "List")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}
