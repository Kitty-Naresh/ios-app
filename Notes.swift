import Foundation

// MARK: - Notes: what you wrote to Kitty, kept until you delete it

/// One note: the words of a turn, exactly as you wrote or said them (line breaks kept). Notes are never changed by Kitty.
struct Note: Codable, Identifiable, Equatable {
    var id: UUID
    var text: String
    var createdAt: Date
    /// The tasks made from this note when its preview was saved. They may have been deleted since: only those that still exist count.
    var taskIDs: [UUID] = []
    /// When the text was last changed by hand, if it was. The bubble says "Edited".
    var editedAt: Date? = nil
    /// The chat this note belongs to. Notes saved before chats existed have none and are given a default chat when first loaded.
    var chatID: UUID? = nil
    /// Kitty found tasks in this note and the preview was never saved or discarded (the user left it, or the app closed). The note
    /// shows "Review tasks"; tapping it reads the note again and brings the preview back.
    var reviewPending = false
    /// Notes written one after another while the same preview waited (a heading, then its items) share a group: together they are one
    /// thing you wrote, and one status shows for them. Notes saved before groups existed have none and stand alone.
    var groupID: UUID? = nil

    init(id: UUID, text: String, createdAt: Date, taskIDs: [UUID] = [], editedAt: Date? = nil, chatID: UUID? = nil, reviewPending: Bool = false,
         groupID: UUID? = nil) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
        self.taskIDs = taskIDs
        self.editedAt = editedAt
        self.chatID = chatID
        self.reviewPending = reviewPending
        self.groupID = groupID
    }

    /// Notes saved before `taskIDs` existed have no such key: they decode with none.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        text = try c.decode(String.self, forKey: .text)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        taskIDs = try c.decodeIfPresent([UUID].self, forKey: .taskIDs) ?? []
        editedAt = try c.decodeIfPresent(Date.self, forKey: .editedAt)
        chatID = try c.decodeIfPresent(UUID.self, forKey: .chatID)
        reviewPending = try c.decodeIfPresent(Bool.self, forKey: .reviewPending) ?? false
        groupID = try c.decodeIfPresent(UUID.self, forKey: .groupID)
    }
}

/// Your notes, in one JSON file in Application Support (like the task details file: written atomically, protected while the phone
/// is locked, kept out of iCloud backups). Only notes are stored here: never Kitty's replies, previews or questions.
///
/// Loading never throws and never loses data: an entry that cannot be read is skipped and the rest load; a file that cannot be read
/// at all is moved aside (`notes.corrupt-<time>.json`) and the thread starts empty, so the file is never overwritten silently.
/// Note text is never logged: anything written to a log here is an id or a count.
@MainActor
final class NotesStore {
    static let shared = NotesStore(url: NotesStore.defaultURL)

    /// The file format. `version` leaves room for later milestones.
    private struct Payload: Codable {
        var version = 1
        var notes: [Lenient]
    }

    /// One entry that is read if it can be, and skipped if it cannot, so a single bad entry never hides the others.
    private struct Lenient: Codable {
        var note: Note?
        init(_ note: Note) { self.note = note }
        init(from decoder: Decoder) throws { note = try? Note(from: decoder) }
        func encode(to encoder: Encoder) throws { if let note { try note.encode(to: encoder) } }
    }

    private let url: URL?
    private var notes: [Note]

    /// Where an unreadable file was moved to by the last load, if it was (for the user or a test to find).
    private(set) var movedAside: URL?

    /// `url` nil keeps everything in memory (tests).
    init(url: URL?) {
        self.url = url
        notes = []
        notes = readFile()
    }

    nonisolated static var defaultURL: URL? {
        guard let dir = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        else { return nil }
        return dir.appendingPathComponent("notes.json")
    }

    // MARK: Reading

    /// The saved notes, oldest first.
    func load() -> [Note] { notes.sorted { $0.createdAt < $1.createdAt } }

    /// The notes of one chat, oldest first.
    func load(chat chatID: UUID?) -> [Note] { notes.filter { $0.chatID == chatID }.sorted { $0.createdAt < $1.createdAt } }

    /// The newest note of a chat (for the chat list).
    func latest(in chatID: UUID) -> Note? { notes.filter { $0.chatID == chatID }.max { $0.createdAt < $1.createdAt } }

    var hasOrphans: Bool { notes.contains { $0.chatID == nil } }

    /// Gives every note saved before chats existed to one chat. Returns whether anything changed.
    @discardableResult
    func assignOrphans(to chatID: UUID) -> Bool {
        var changed = false
        for i in notes.indices where notes[i].chatID == nil { notes[i].chatID = chatID; changed = true }
        if changed { write() }
        return changed
    }

    func deleteAll(in chatID: UUID) {
        notes.removeAll { $0.chatID == chatID }
        write()
    }

    func note(_ id: UUID) -> Note? { notes.first { $0.id == id } }

    /// The notes written together with this one (itself included), oldest first. A note with no group is its own group.
    func group(of id: UUID) -> [Note] {
        guard let one = note(id) else { return [] }
        guard let gid = one.groupID else { return [one] }
        return notes.filter { $0.groupID == gid }.sorted { $0.createdAt < $1.createdAt }
    }

    /// The text of a group by its id (what a question was about).
    func text(ofGroup gid: UUID) -> String {
        notes.filter { $0.groupID == gid }.sorted { $0.createdAt < $1.createdAt }.map(\.text).joined(separator: "\n")
    }

    /// What was written in the group, one note per line: what Kitty reads again for "Review tasks".
    func groupText(of id: UUID) -> String { group(of: id).map(\.text).joined(separator: "\n") }

    var count: Int { notes.count }

    private func readFile() -> [Note] {
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return [] }
        guard let data = try? Data(contentsOf: url) else { return [] }            // unreadable right now (locked): leave the file alone
        if let saved = try? JSONDecoder().decode(Payload.self, from: data) {
            return saved.notes.compactMap(\.note)
        }
        // Not a notes file we can read: keep it, so nothing is lost, and start empty.
        let stamp = Int(Date().timeIntervalSince1970)
        let aside = url.deletingLastPathComponent().appendingPathComponent("notes.corrupt-\(stamp).json")
        if (try? FileManager.default.moveItem(at: url, to: aside)) != nil { movedAside = aside }
        return []
    }

    // MARK: Writing

    /// Adds the note, or changes its text if the id is already there (you spoke on). Empty text is never stored.
    /// Returns whether anything was stored.
    @discardableResult
    func upsert(id: UUID, text: String, at date: Date = .now, chatID: UUID? = nil) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        if let i = notes.firstIndex(where: { $0.id == id }) {
            guard notes[i].text != text else { return true }
            notes[i].text = text
        } else {
            notes.append(Note(id: id, text: text, createdAt: date, chatID: chatID))
        }
        write()
        return true
    }

    /// Adds a note that belongs to a group. Empty text is never stored. Returns whether anything was stored.
    @discardableResult
    func insert(id: UUID, text: String, groupID: UUID, at date: Date = .now, chatID: UUID? = nil) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        notes.append(Note(id: id, text: text, createdAt: date, chatID: chatID, groupID: groupID))
        write()
        return true
    }

    /// The user changed the text by hand. Empty text is never stored. Returns whether the text changed.
    @discardableResult
    func updateText(id: UUID, text: String, at date: Date = .now) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let i = notes.firstIndex(where: { $0.id == id }), notes[i].text != text else { return false }
        notes[i].text = text
        notes[i].editedAt = date
        write()
        return true
    }

    func setReviewPending(_ id: UUID, _ pending: Bool) {
        guard let i = notes.firstIndex(where: { $0.id == id }), notes[i].reviewPending != pending else { return }
        notes[i].reviewPending = pending
        write()
    }

    /// The same for every note written together with this one.
    func setReviewPending(groupOf id: UUID, _ pending: Bool) {
        for note in group(of: id) { setReviewPending(note.id, pending) }
    }

    /// Remembers the tasks on every note of the group, so deleting one bubble never loses the link to them.
    func attach(groupOf id: UUID, taskIDs ids: [UUID]) {
        for note in group(of: id) { attach(id: note.id, taskIDs: ids) }
    }

    /// Remembers that these tasks were made from this note (its preview was saved). Adds to the ones already remembered.
    func attach(id: UUID, taskIDs ids: [UUID]) {
        guard !ids.isEmpty, let i = notes.firstIndex(where: { $0.id == id }) else { return }
        let merged = notes[i].taskIDs + ids.filter { !notes[i].taskIDs.contains($0) }
        guard merged != notes[i].taskIDs else { return }
        notes[i].taskIDs = merged
        write()
    }

    func delete(id: UUID) {
        guard notes.contains(where: { $0.id == id }) else { return }
        notes.removeAll { $0.id == id }
        write()
    }

    func deleteAll() {
        notes = []
        write()
    }

    private func write() {
        guard let url else { return }
        guard let data = try? JSONEncoder().encode(Payload(notes: notes.map(Lenient.init))) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtection])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var target = url
        try? target.setResourceValues(values)
    }
}

// MARK: - What Kitty says that stays in the thread

/// One thing Kitty said that stays in the chat: a question she asked (so you find it again when you come back), or the short summary
/// of what she did after you saved. Everything else she says (answers about your tasks, "okay") is shown once and not kept.
struct KittyMessage: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case question, summary }
    var id: UUID
    var text: String
    var kind: Kind
    var createdAt: Date
    var chatID: UUID?
    /// The notes this is about (the group they were written in).
    var groupID: UUID?
}

/// Kitty's kept messages, in one small JSON file next to the notes. Same care as the notes: written atomically, protected while the
/// phone is locked, kept out of backups, never logged, and a bad file never stops the app.
@MainActor
final class KittyMessagesStore {
    static let shared = KittyMessagesStore(url: KittyMessagesStore.defaultURL)

    private let url: URL?
    private var messages: [KittyMessage] = []

    init(url: URL?) {
        self.url = url
        if let url, let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode([KittyMessage].self, from: data) { messages = saved }
    }

    nonisolated static var defaultURL: URL? {
        guard let dir = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        else { return nil }
        return dir.appendingPathComponent("kitty_messages.json")
    }

    func load(chat chatID: UUID?) -> [KittyMessage] { messages.filter { $0.chatID == chatID }.sorted { $0.createdAt < $1.createdAt } }

    @discardableResult
    func add(_ text: String, kind: KittyMessage.Kind, chatID: UUID?, groupID: UUID?, at date: Date = .now) -> KittyMessage? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let message = KittyMessage(id: UUID(), text: text, kind: kind, createdAt: date, chatID: chatID, groupID: groupID)
        messages.append(message)
        write()
        return message
    }

    func deleteAll(in chatID: UUID) {
        let before = messages.count
        messages.removeAll { $0.chatID == chatID }
        if messages.count != before { write() }
    }

    private func write() {
        guard let url, let data = try? JSONEncoder().encode(messages) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtection])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var target = url
        try? target.setResourceValues(values)
    }
}


// MARK: - Which words of a turn are a note

/// What the user sends is always kept: every message, typed or spoken, is saved as a note the moment Kitty starts working on it, whether
/// or not a preview is open. Notes sent while the same preview waits belong to one group (a heading, then its items) that ends when the
/// preview is saved or discarded. Only a spoken or typed "yes" or "cancel" to a waiting preview is not a note.
///
/// A spoken note can grow: if the model says "wait" the user is still talking, so the next words replace the same note instead of
/// starting another. Any other answer settles it.
@MainActor
struct NoteCapture {
    /// The newest note of the turn.
    private(set) var id: UUID?
    /// The group of this turn's notes, or of the edited note that is being read again.
    private(set) var groupID: UUID?
    /// The turn is a note that already exists being read again (the user edited it, or tapped "Review tasks"): nothing new is saved.
    private(set) var adopted = false
    private var growing: (id: UUID, base: Int)?

    /// The word count the newest note started at, while it may still grow.
    var growingBase: Int? { growing?.base }

    /// Saves `text` as a new note of this turn's group, or replaces the text of the newest note while it may still grow.
    /// `base` is how many words of the turn came before this note. Returns the stored note, or nil when the text is empty.
    mutating func save(_ text: String, from base: Int, in store: NotesStore, chatID: UUID? = nil) -> Note? {
        if let open = growing {
            guard store.upsert(id: open.id, text: text, chatID: chatID) else { return nil }
            id = open.id
            return store.note(open.id)
        }
        let gid = groupID ?? UUID()
        let noteID = UUID()
        guard store.insert(id: noteID, text: text, groupID: gid, chatID: chatID), let saved = store.note(noteID) else { return nil }
        groupID = gid
        id = noteID
        growing = (noteID, base)
        return saved
    }

    /// The next notes join a group that already exists (the user answers a question about it).
    mutating func continueGroup(_ gid: UUID) { groupID = gid }

    /// The newest note is final: the next words are another note.
    mutating func settle() { growing = nil }

    /// The reply was only an answer about saved tasks (nothing created): the words were a question, not a note, so none is kept.
    /// Only when the turn was that one note alone: a question asked while a preview waits is part of what the user wrote.
    mutating func dropIfQuestion(created: Bool, answeredFromTasks: Bool, in store: NotesStore) {
        guard let id, !adopted, answeredFromTasks, !created, store.group(of: id).count == 1 else { return }
        store.delete(id: id)
        self.id = nil
    }

    /// The turn is a new reading of a note that already exists: it is that note, it has its bubble already, and nothing new is saved.
    mutating func adopt(_ note: Note) {
        self = NoteCapture()
        id = note.id
        groupID = note.groupID
        adopted = true
    }

    /// The turn is over.
    mutating func reset() { self = NoteCapture() }
}


// MARK: - Chats: where notes are kept apart

/// One chat: a place for notes. Tasks and reminders are not in chats; they stay in one list for the whole app.
struct Chat: Codable, Identifiable, Equatable {
    var id: UUID
    var title: String
    var createdAt: Date
    var updatedAt: Date
}

/// Your chats, in one JSON file next to the notes. A new chat is not listed until it has its first note, so backing out of a new chat
/// leaves nothing behind. The title is the first line of the first note until you rename it.
@MainActor
final class ChatsStore: ObservableObject {
    static let shared = ChatsStore(url: ChatsStore.defaultURL, notes: NotesStore.shared)
    static let newTitle = "New chat"
    static let defaultTitle = "Notes"

    @Published private(set) var chats: [Chat] = []
    private var pending: Chat?
    private let url: URL?
    private let notes: NotesStore

    private struct Payload: Codable {
        var version = 1
        var chats: [Chat]
    }

    init(url: URL?, notes: NotesStore) {
        self.url = url
        self.notes = notes
        chats = read()
        migrate()
    }

    nonisolated static var defaultURL: URL? {
        guard let dir = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        else { return nil }
        return dir.appendingPathComponent("chats.json")
    }

    /// Newest activity first.
    var sorted: [Chat] { chats.sorted { $0.updatedAt > $1.updatedAt } }
    var lastUsed: Chat? { sorted.first }

    /// A new, empty chat to open. It is listed only once its first note is written.
    func startNew() -> UUID {
        let now = Date()
        let chat = Chat(id: UUID(), title: Self.newTitle, createdAt: now, updatedAt: now)
        pending = chat
        return chat.id
    }

    /// A note was written in this chat: it is listed (if new), moves to the top, and gets its title from the first line.
    func touch(_ id: UUID, firstLine text: String?, at date: Date = .now) {
        if let p = pending, p.id == id {
            chats.append(p)
            pending = nil
        }
        guard let i = chats.firstIndex(where: { $0.id == id }) else { return }
        chats[i].updatedAt = date
        if chats[i].title == Self.newTitle, let text, !Self.title(from: text).isEmpty { chats[i].title = Self.title(from: text) }
        write()
    }

    func rename(_ id: UUID, to title: String) {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let i = chats.firstIndex(where: { $0.id == id }) else { return }
        chats[i].title = String(clean.prefix(60))
        write()
    }

    /// Deletes the chat and its notes. Tasks made from them stay.
    func delete(_ id: UUID) {
        notes.deleteAll(in: id)
        KittyMessagesStore.shared.deleteAll(in: id)
        chats.removeAll { $0.id == id }
        write()
    }

    /// The first non-empty line, short.
    static func title(from text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
        return line.count > 40 ? String(line.prefix(40)).trimmingCharacters(in: .whitespaces) + "…" : line
    }

    // MARK: File

    /// Notes saved before chats existed go into one chat, so nothing is lost or reordered.
    private func migrate() {
        guard notes.hasOrphans else { return }
        let first = notes.load(chat: nil).first?.createdAt ?? Date()
        let last = notes.load(chat: nil).last?.createdAt ?? first
        let chat = Chat(id: UUID(), title: Self.defaultTitle, createdAt: first, updatedAt: last)
        chats.append(chat)
        notes.assignOrphans(to: chat.id)
        write()
    }

    private func read() -> [Chat] {
        guard let url, let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode(Payload.self, from: data) else { return [] }
        return saved.chats
    }

    private func write() {
        guard let url, let data = try? JSONEncoder().encode(Payload(chats: chats)) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtection])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var target = url
        try? target.setResourceValues(values)
    }
}


// MARK: - Asking Kitty about your notes

/// Finds notes by their words, and tells a question about notes from a note. Plain Swift on the phone: no model reads your notes to answer.
enum NoteSearch {
    private static let phrases = ["my notes", "my note", "did i write", "did i note", "did i save", "did i say", "what did i write",
                                  "find my note", "search my notes", "search notes", "look in my notes", "in my notes", "i wrote about",
                                  "what was my note", "show my notes", "show me my notes"]

    /// Only questions that clearly ask about notes. Everything else goes to Kitty as before.
    static func looksLikeNotesQuestion(_ text: String) -> Bool {
        let low = text.lowercased()
        return phrases.contains { low.contains($0) }
    }

    private static let stop: Set<String> = [
        "what", "did", "i", "write", "wrote", "note", "notes", "my", "about", "the", "a", "an", "find", "search", "for", "where", "say",
        "said", "in", "on", "of", "to", "me", "show", "any", "have", "had", "do", "does", "is", "are", "was", "were", "look", "save",
        "saved", "anything", "something", "all", "that", "this", "it", "and", "or", "with", "from", "you", "can", "please", "kitty"]

    static func words(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init).filter { $0.count >= 3 && !stop.contains($0) }
    }

    /// Notes that hold the question's own words, best match first, then newest. A word counts when a word of the note starts with it
    /// (or the other way round), so "shopping" finds "shop".
    static func matches(query: String, in notes: [Note], limit: Int = 3) -> [Note] {
        let q = words(query)
        guard !q.isEmpty else { return [] }
        let need = q.count <= 2 ? q.count : (q.count + 1) / 2
        let scored: [(note: Note, score: Int)] = notes.compactMap { note in
            let heard = words(note.text)
            let score = q.filter { w in heard.contains { $0.hasPrefix(String(w.prefix(4))) || w.hasPrefix(String($0.prefix(4))) } }.count
            return score >= need ? (note, score) : nil
        }
        return scored.sorted { ($0.score, $0.note.createdAt) > ($1.score, $1.note.createdAt) }.prefix(limit).map(\.note)
    }

    /// The answer, as plain text: each note's first line, and where and when it was written.
    @MainActor
    static func answer(for found: [Note], chats: ChatsStore = .shared) -> String {
        guard !found.isEmpty else { return "I couldn't find that in your notes." }
        let rows = found.map { note -> String in
            let line = note.text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? note.text
            let short = line.count > 90 ? String(line.prefix(90)) + "…" : line
            let chat = note.chatID.flatMap { id in chats.chats.first { $0.id == id }?.title }
            let when = note.createdAt.formatted(.dateTime.day().month(.abbreviated))
            return "• \(short) (\([chat, when].compactMap { $0 }.joined(separator: ", ")))"
        }
        return "From your notes:\n" + rows.joined(separator: "\n")
    }
}
