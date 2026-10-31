import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - The trace: one turn, step by step, in the Xcode console

/// A complete, ordered account of what happened to one spoken turn: what was heard, what Swift did, what was sent to the model,
/// what the model said, what Swift checked afterwards, and what the user was shown.
///
/// Every line starts with `KITTY [turn]`, so typing `KITTY` in the filter box of the Xcode debug console shows only the trace,
/// including the body of a long prompt (each of its lines carries the prefix too).
///
/// By default it shows only what matters: `HEARD` and `CLEANED` (what you said), `SWIFT` (what Swift did, before the model and
/// after it), `TO MODEL`, `FROM MODEL` and `RESULT`. Set `kitty.traceDetail` to see the rest as well (`GATES`, `STRIP`, `CHECKS`,
/// `RULES`, `ROUTE`, `SAVED`).
///
/// Debug builds only: the prompt carries the household's names and tasks, so nothing prints in a release build. Off under
/// XCTest unless a test turns it on, and the app can switch it off with `kitty.traceModel`.
nonisolated enum Trace {
    static let key = "kitty.traceModel"
    static let detailKey = "kitty.traceDetail"

    /// The stages shown without asking: the story of a turn. Every other stage is detail.
    static let defaultStages: Set<String> = ["HEARD", "CLEANED", "SWIFT", "TO MODEL", "FROM MODEL", "BUDGET", "LINE", "RESULT", "WARNING", "CLARIFY", "TURN", "TIME"]

    /// Set by tests to force one behaviour.
    nonisolated(unsafe) static var override: Bool?
    /// Set by tests to force the detail level on or off.
    nonisolated(unsafe) static var detailOverride: Bool?

    /// Whether the detail stages print too.
    static var detail: Bool {
        if let detailOverride { return detailOverride }
        return (UserDefaults.standard.object(forKey: detailKey) as? Bool) ?? false
    }

    static func shows(_ stage: String) -> Bool { defaultStages.contains(stage) || detail }

    // MARK: Recording for "See details"

    /// The settings switch: keep every stage of a turn as data, so a task can show how it was made. Off by default, because the
    /// prompt carries the household's names and tasks. Separate from the console trace, so it works in a release build too.
    static let recordingKey = "kitty.taskDetails"
    /// Set by tests to force recording on or off.
    nonisolated(unsafe) static var recordingOverride: Bool?
    static var recording: Bool {
        if let recordingOverride { return recordingOverride }
        return (UserDefaults.standard.object(forKey: recordingKey) as? Bool) ?? false
    }
    /// Every stage of the turn being worked on, in order, whatever the console shows. Empty unless recording.
    nonisolated(unsafe) private(set) static var stages: [TraceStage] = []
    /// Notes made before the next turn begins (the brand repair in the recogniser).
    nonisolated(unsafe) private static var pendingStages: [TraceStage] = []
    /// When set, every line is also appended here, so a test can read what would have been printed.
    nonisolated(unsafe) static var capture: [String]?
    nonisolated(unsafe) private(set) static var turn = 0
    /// The lines of the turn being worked on.
    nonisolated(unsafe) private(set) static var steps: [String] = []

    private static let underTest = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    static var enabled: Bool {
        #if DEBUG
        if let override { return override }
        if underTest { return false }
        return (UserDefaults.standard.object(forKey: key) as? Bool) ?? true
        #else
        return false
        #endif
    }

    /// Starts a new numbered turn.
    static func begin() {
        let recording = recording
        TurnCapture.shared.begin()
        LiveFeed.shared.begin()
        guard enabled || recording else { stages = []; return }
        turn += 1
        steps = []
        stages = recording ? pendingStages : []
        pendingStages = []
    }

    /// One step of the current turn. `text` may span lines: the first goes beside the stage name, the rest follow.
    /// It is only built when the trace is on.
    static func step(_ stage: String, _ text: @autoclosure () -> String) {
        let console = enabled && shows(stage)
        let recording = recording
        let live = LiveFeed.enabled && LiveFeed.shows(stage)
        let capturing = TurnCapture.enabled
        guard console || recording || live || capturing else { return }
        let body = text()
        if live { LiveFeed.shared.add(stage: stage, text: body) }
        if capturing { TurnCapture.shared.note(stage: stage, text: body) }
        // The full instructions and schema live with each model call; the saved steps would only repeat them.
        if recording, !TurnCapture.bulkyStages.contains(stage) { stages.append(TraceStage(stage: stage, text: body)) }
        if console { emit(format(marker: "\(turn)", stage: stage, text: body), keep: true) }
    }

    /// Something that happens before a turn starts (the brand repair in the recogniser): it belongs to the next turn.
    static func note(_ stage: String, _ text: @autoclosure () -> String) {
        let console = enabled && shows(stage)
        let recording = recording
        let live = LiveFeed.enabled && LiveFeed.shows(stage)
        let capturing = TurnCapture.enabled
        guard console || recording || live || capturing else { return }
        let body = text()
        if live { LiveFeed.shared.addBeforeTurn(stage: stage, text: body) }
        if capturing { TurnCapture.shared.noteBeforeTurn(stage: stage, text: body) }
        if recording { pendingStages.append(TraceStage(stage: stage, text: body)) }
        if console { emit(format(marker: "\(turn + 1)", stage: stage, text: body), keep: false) }
    }

    private static func emit(_ block: String, keep: Bool) {
        if keep { steps.append(block) }
        capture?.append(block)
        print(block)
    }

    /// `KITTY [7] STAGE      first line` and then `KITTY [7] |         the rest`, so a console filter keeps every line.
    static func format(marker: String, stage: String, text: String) -> String {
        let name = stage.padding(toLength: 10, withPad: " ", startingAt: 0)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var out = ["KITTY [\(marker)] \(name) \(lines.first ?? "")"]
        for line in lines.dropFirst() { out.append("KITTY [\(marker)] |          \(line)") }
        return out.joined(separator: "\n")
    }

    /// "key: value" for each non-empty field, on one line.
    static func fields(_ pairs: [(String, String)]) -> String {
        pairs.filter { !$0.1.isEmpty }.map { "\($0.0) \($0.1)" }.joined(separator: " | ")
    }

    /// What Swift made of one task the model proposed: each field as the model gave it, and as Swift kept it.
    static func describe(task t: ValidatedTask, raw: String, category: String, assignee: String, reason: String = "") -> String {
        func shown(_ s: String?) -> String { s.map { $0.isEmpty ? "none" : "\"\($0)\"" } ?? "none" }
        var lines = ["task kept: title \(shown(raw)) -> \(shown(t.title))" + (raw == t.title ? " (unchanged)" : "")]
        lines.append("  category \(shown(category)) -> \(shown(t.categoryName))")
        lines.append("  assignee \(shown(assignee)) -> \(shown(t.assignee)); day \(t.due.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "none")"
                     + "; priority \(shown(t.priority)); time \(t.timeMinutes.map { "\($0 / 60):" + String(format: "%02d", $0 % 60) } ?? "none")")
        if !reason.isEmpty || t.reason != nil { lines.append("  reason \(shown(reason)) -> \(shown(t.reason))") }
        return lines.joined(separator: "\n")
    }

    /// "Order food" [Food, for Me]: a task as it is handed to the store.
    static func describe(planned p: PlannedTask) -> String {
        var parts = [p.categoryName ?? p.category?.label ?? "no category"]
        if let r = p.reason, !r.isEmpty { parts.append("because \(r)") }
        if let a = p.assignee { parts.append("for \(a)") }
        if let d = p.due { parts.append("due " + d.formatted(date: .abbreviated, time: .omitted)) }
        if p.recurrence != nil { parts.append("repeats") }
        return "\"\(p.title)\" [" + parts.joined(separator: ", ") + "]"
    }

    /// About 3.5 characters to a token for English: an estimate, labelled as one wherever it is shown.
    static func estimatedTokens(_ characters: Int) -> Int { Int((Double(characters) / 3.5).rounded(.up)) }

    /// "1,412 chars (~404 tokens)".
    static func size(_ text: String) -> String { size(characters: text.count) }
    static func size(characters n: Int) -> String { "\(n.formatted()) chars (~\(estimatedTokens(n).formatted()) tokens)" }
}

// MARK: - How the model's answers read in the trace

/// A model answer written as a few readable lines instead of a struct dump.
protocol TraceDescribable {
    var traceText: String { get }
}

extension TaskDraftValue: TraceDescribable {
    var traceText: String {
        Trace.fields([("title", "\"\(title)\""), ("category", category), ("day", dueDate), ("time", dueTime), ("priority", priority),
                      ("assignee", assignee), ("notes", notes)])
    }
}

extension ExtractionTaskValue: TraceDescribable {
    var traceText: String {
        Trace.fields([("title", "\"\(title)\""), ("schedule", schedule ?? ""), ("assignee", assignee ?? ""), ("date", dueDate ?? ""), ("time", dueTime ?? ""),
                      ("purpose", purpose ?? ""), ("instructions", instructions ?? ""), ("list", listName ?? "")])
    }
}

extension BulkDecisionValue: TraceDescribable {
    var traceText: String {
        var lines = ["action: \(action)"]
        if let e = extraction {
            lines = ["outcome: \(e.outcome)" + (e.listName.map { "  list: \($0)" } ?? "") + (e.mayHaveMore ? "  (12 tasks: there may be more)" : "")]
            for (i, t) in e.tasks.enumerated() { lines.append("task \(i + 1): \(t.traceText)") }
            if let q = e.question, !q.isEmpty { lines.append("question: \(q)") }
            return lines.joined(separator: "\n")
        }
        for (i, t) in tasks.enumerated() { lines.append("task \(i + 1): \(t.traceText)") }
        for (i, r) in routines.enumerated() {
            lines.append("routine \(i + 1): " + Trace.fields([("title", "\"\(r.title)\""), ("category", r.category), ("frequency", r.frequency),
                                                              ("schedule", r.schedule), ("weekdays", r.weekdays.isEmpty ? "" : r.weekdays.map(String.init).joined(separator: ",")),
                                                              ("assignee", r.assignee), ("notes", r.notes)]))
        }
        if let p = playbook {
            lines.append("playbook: \"\(p.name)\" steps: " + p.steps.map(\.title).joined(separator: " > "))
        }
        for (i, o) in operations.enumerated() { lines.append("operation \(i + 1): \(o.op) \(o.taskID)" + (o.changes.map { " " + $0.traceText } ?? "")) }
        if !answer.isEmpty { lines.append("answer: \(answer)") }
        if let q = query, !q.isEmpty { lines.append("lookup: \(q.described)") }
        if !clarifyingQuestion.isEmpty { lines.append("question: \(clarifyingQuestion)") }
        return lines.joined(separator: "\n")
    }
}

extension AgentDecisionValue: TraceDescribable {
    var traceText: String {
        var lines = ["action: \(action)\(wait ? "  (wait)" : "")"]
        let main = Trace.fields([("title", title.isEmpty ? "" : "\"\(title)\""), ("category", category), ("day", dueDate), ("time", dueTime),
                                 ("priority", priority), ("assignee", assignee), ("frequency", frequency), ("notes", notes)])
        if !main.isEmpty { lines.append(main) }
        if !moreTasks.isEmpty { lines.append("more tasks: " + moreTasks.joined(separator: " ; ")) }
        if !playbookName.isEmpty { lines.append("playbook: \"\(playbookName)\" steps: " + playbookSteps.joined(separator: " > ")) }
        if !clarifyingQuestion.isEmpty { lines.append("question: \(clarifyingQuestion)") }
        if !spokenResponse.isEmpty { lines.append("says: \(spokenResponse)") }
        return lines.joined(separator: "\n")
    }
}

// MARK: - One turn as data, for "See details"

/// One step of a turn: the stage name (`HEARD`, `TO MODEL`, `SWIFT`...), what it said, and when.
nonisolated struct TraceStage: Codable, Equatable, Sendable {
    var stage: String
    var text: String
    var at = Date()
}

extension TraceStage {
    /// Details saved before steps had a time still load: they sort first, in their saved order.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        stage = try c.decode(String.self, forKey: .stage)
        text = try c.decode(String.self, forKey: .text)
        at = try c.decodeIfPresent(Date.self, forKey: .at) ?? .distantPast
    }
}

/// Everything that happened to one spoken (or typed) turn, kept with the tasks it made.
nonisolated struct TaskTurnRecord: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var date = Date()
    var utterance = ""          // the cleaned words the turn worked on
    var route = ""              // which path decided it
    var result = ""             // what the user was shown
    var stages: [TraceStage] = []
    var calls: [ModelCallRecord] = []      // every model call of the turn, exactly as sent and received
}

extension TaskTurnRecord {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        date = try c.decode(Date.self, forKey: .date)
        utterance = try c.decode(String.self, forKey: .utterance)
        route = try c.decode(String.self, forKey: .route)
        result = try c.decode(String.self, forKey: .result)
        stages = try c.decode([TraceStage].self, forKey: .stages)
        calls = try c.decodeIfPresent([ModelCallRecord].self, forKey: .calls) ?? []
    }
}

// MARK: - Every model call, exactly

/// One call to the on-device model: what the session already held, what was sent, and what came back, word for word.
nonisolated struct ModelCallRecord: Codable, Equatable, Identifiable, Sendable {
    struct Entry: Codable, Equatable, Sendable {
        var role: String            // "prompt", "reply", "tool"...
        var text: String
    }

    var id = UUID()
    var kind = ""                   // "single task", "bulk", "question wording", "time of day"...
    var mode = ""                   // "new session" or "shared session, turn 3"
    var instructions = ""           // the session's instructions (the store keeps one copy of each text, see instructionsKey)
    var instructionsKey: String?
    var history: [Entry] = []       // what the session already held before this call: earlier prompts and replies
    var prompt = ""
    var schema = ""                 // the shape the model was asked to fill
    var rawReply = ""               // the reply as the model produced it
    var started = Date()
    var seconds = 0.0
    var error: String?              // failed, cancelled, timed out, or never sent
    var detail: CallDetail?         // the real schema, tools, token counts, the writing log, the partial reply and the outcome
}

/// What a call carried and how it went, beyond the prompt: kept for every call of the turn (see `TurnCapture`).
nonisolated struct CallDetail: Codable, Equatable, Sendable {
    struct Tool: Codable, Equatable, Sendable {
        var name: String
        var description: String
        var parameters: String      // the tool's argument schema as JSON
    }
    /// Tokens of each part of the call. `nil` until counted. `exact` is true when the model counted them, false for 3.5 characters a token.
    struct Tokens: Codable, Equatable, Sendable {
        var instructions: Int?
        var schema: Int?
        var tools: Int?
        var prompt: Int?
        var reply: Int?
        var exact = false
        var window = 0
        /// Whether `reply` was counted by the model (true) or estimated from the characters written (nil or false).
        var replyExact: Bool? = nil

        var sent: Int { (instructions ?? 0) + (schema ?? 0) + (tools ?? 0) + (prompt ?? 0) }
        var left: Int { window - sent - (reply ?? 0) }
    }
    /// One streamed snapshot of the answer.
    struct Point: Codable, Equatable, Sendable {
        var at: Double              // seconds since the call began
        var characters: Int
        var tokens: Int             // estimated
        var items: Int              // elements of the longest list in the answer so far
    }

    var schemaJSON = ""
    var tools: [Tool] = []
    var tokens = Tokens()
    var writing: [Point] = []
    var partialReply = ""           // the answer as far as it was written, kept on cancel, timeout and failure
    var outcome = "in progress"
    var limit = ""                  // the output cap this call ran under
    /// What the call was really given to generate with, and what it ended as. Optional so records saved earlier still load.
    var settings: String?           // maximum response tokens, sampling, the guard's limits
    var schemaVersion: String?      // the schema's type name and a short hash of the JSON the model was held to
    var completion: String?         // finished, stopped by the output guard, cancelled, stopped by the clock or failed
    var cancelledBy: String?        // who or what ended an unfinished call, when that is known
}

/// The model calls made since they were last taken, in order. Every call goes through `ModelTape.respond` (Agent.swift), so none
/// can be missed. Nothing is kept unless the "Save task details" switch is on.
nonisolated enum ModelTape {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var buffer: [ModelCallRecord] = []

    static func record(_ call: ModelCallRecord) {
        TurnCapture.shared.upsert(call)
        guard Trace.recording else { return }
        lock.lock(); defer { lock.unlock() }
        buffer.append(call)
    }

    /// A call that was never made (the model is unavailable): the trace still says so.
    static func skipped(kind: String, prompt: String, reason: String) {
        var detail = CallDetail()
        detail.outcome = "not sent: \(reason)"
        record(ModelCallRecord(kind: kind, mode: "not sent", prompt: prompt, error: reason, detail: detail))
    }

    /// Everything recorded so far, once.
    static func drain() -> [ModelCallRecord] {
        lock.lock(); defer { lock.unlock() }
        let calls = buffer
        buffer = []
        return calls
    }
}


// MARK: - The live feed: what Kitty is doing, on screen, while it happens

/// One line of the live view.
nonisolated struct LiveStep: Identifiable, Equatable, Sendable {
    let id: Int
    var stage: String
    var text: String
    /// Seconds since the turn started.
    var at: TimeInterval
    /// A line that is still being written (the model's answer as it streams): the next update replaces it.
    var writing = false
}

/// The steps of the turn being worked on, in order, for the "What Kitty is doing" panel. Fed by `Trace.step` (so every step the
/// console shows is here too) and by the streamed model answer. Thread-safe: tools and the model call it off the main thread; the
/// published copy is updated on the main thread, in order. Kept apart from "See details", which is saved with the task.
nonisolated final class LiveFeed: ObservableObject, @unchecked Sendable {
    static let shared = LiveFeed()
    static let key = "kitty.liveModelView"

    /// Set by tests to force the switch.
    nonisolated(unsafe) static var override: Bool?
    private static let underTest = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    /// On in a debug build and off in a release build, unless the Settings switch says otherwise. Never on under XCTest unless forced.
    static var enabled: Bool {
        if let override { return override }
        if underTest { return false }
        if let stored = UserDefaults.standard.object(forKey: key) as? Bool { return stored }
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    /// Every stage the console shows, plus the model's streamed answer.
    static func shows(_ stage: String) -> Bool { Trace.defaultStages.contains(stage) || stage == "MODEL WRITING" || TurnCapture.bulkyStages.contains(stage) }

    /// The steps, for the view. Updated on the main thread.
    @Published private(set) var steps: [LiveStep] = []
    /// When the turn began; nil before the first turn.
    @Published private(set) var started: Date?
    /// The model's window, for the size line.
    static let windowTokens = 8_192
    /// The streamed answer is shown at most this often (seconds). Faster only repaints the screen and fights the user's scrolling.
    static let writingInterval: TimeInterval = 0.5

    private let lock = NSLock()
    private var store: [LiveStep] = []
    private var before: [LiveStep] = []
    private var next = 0
    private var startedAt: Date?

    func begin() {
        guard Self.enabled else { return }
        lock.lock()
        startedAt = Date()
        store = before.map { var s = $0; s.at = 0; return s }
        before = []
        let snapshot = store, start = startedAt
        lock.unlock()
        publish(snapshot, started: start)
    }

    func add(stage: String, text: String) {
        lock.lock()
        let at = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        if stage == "MODEL WRITING" {
            // One growing line: each snapshot of the model's answer replaces the last.
            if let i = store.lastIndex(where: { $0.writing }) {
                store[i].text = text; store[i].at = at
            } else {
                next += 1
                store.append(LiveStep(id: next, stage: stage, text: text, at: at, writing: true))
            }
        } else {
            // The finished answer replaces its own streamed line.
            if stage == "FROM MODEL", let i = store.lastIndex(where: { $0.writing }) { store[i].writing = false }
            next += 1
            store.append(LiveStep(id: next, stage: stage, text: text, at: at))
        }
        let snapshot = store
        lock.unlock()
        publish(snapshot, started: nil)
    }

    /// Something that happens before the turn starts (the brand repair): it opens the next turn.
    func addBeforeTurn(stage: String, text: String) {
        lock.lock()
        next += 1
        before.append(LiveStep(id: next, stage: stage, text: text, at: 0))
        lock.unlock()
    }

    func reset() {
        lock.lock(); store = []; before = []; startedAt = nil; lock.unlock()
        publish([], started: nil, clearStart: true)
    }

    /// What has been collected, without waiting for the main thread (tests read this).
    var current: [LiveStep] { lock.lock(); defer { lock.unlock() }; return store }

    private func publish(_ snapshot: [LiveStep], started: Date?, clearStart: Bool = false) {
        let apply = { [self] in
            steps = snapshot
            if let started { self.started = started }
            if clearStart { self.started = nil }
        }
        DispatchQueue.main.async(execute: apply)     // always queued, so the copies arrive in the order they were made
    }
}

// MARK: - The turn, always: what the model was really sent and what it wrote

/// An in-memory record of the current turn and the last one: every step and every model call, with the full instructions, the real
/// schema, the tools, the token counts, the writing log and the partial reply. It is on whether or not "Save task details" is, because
/// a turn that hangs is the one nobody saved. It is cleared when the next turn starts (`Trace.begin`) and is never written to disk.
nonisolated final class TurnCapture: @unchecked Sendable {
    static let shared = TurnCapture()

    /// Set by tests to force the capture on or off.
    nonisolated(unsafe) static var override: Bool?
    static var enabled: Bool { override ?? true }

    /// Steps whose full text belongs to a call, not to the timeline (the instructions and the schema are sent on every call).
    static let bulkyStages: Set<String> = ["INSTRUCTIONS", "SCHEMA"]
    private static let maxStages = 800

    private let lock = NSLock()
    private var stages: [TraceStage] = []
    private var pending: [TraceStage] = []
    private var calls: [ModelCallRecord] = []
    private var began: Date?
    private var turnsBegun = 0
    private var writingOpen = false      // a call is writing: its first snapshot is on the timeline, later ones replace the latest line

    struct Snapshot: Sendable {
        var stages: [TraceStage]
        var calls: [ModelCallRecord]
        var began: Date?
        var turn: Int
    }

    /// A new turn: what was captured is dropped, except the notes made just before it.
    func begin() {
        lock.lock(); defer { lock.unlock() }
        stages = pending; pending = []
        calls = []
        writingOpen = false
        began = Date()
        turnsBegun += 1
    }

    /// Drops everything (tests).
    func reset() {
        lock.lock(); defer { lock.unlock() }
        stages = []; pending = []; calls = []; began = nil; turnsBegun = 0; writingOpen = false
    }

    private func shortened(_ stage: String, _ text: String) -> String {
        guard stage == "MODEL WRITING" || Self.bulkyStages.contains(stage) else { return text }
        let first = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        return first + (text.contains("\n") ? "\n(the full text is under the model call below)" : "")
    }

    func note(stage: String, text: String) {
        let kept = shortened(stage, text)
        lock.lock(); defer { lock.unlock() }
        // The model's writing is two lines, each stamped with its own time: when it began (the first snapshot, never changed) and
        // the latest snapshot (replaced by each one, restamped when it is). One growing line stamped when it began would carry a
        // size that was only reached much later.
        if stage == "MODEL WRITING" {
            if writingOpen {
                if let i = stages.lastIndex(where: { $0.stage == "MODEL WRITING (latest)" }),
                   let s = stages.lastIndex(where: { $0.stage == "MODEL WRITING" }), i > s {
                    stages[i].text = kept; stages[i].at = Date(); return
                }
                guard stages.count < Self.maxStages else { return }
                stages.append(TraceStage(stage: "MODEL WRITING (latest)", text: kept)); return
            }
            writingOpen = true
        } else if stage == "FROM MODEL" || stage == "WARNING" {
            writingOpen = false
        }
        guard stages.count < Self.maxStages else { return }
        stages.append(TraceStage(stage: stage, text: kept))
    }

    func noteBeforeTurn(stage: String, text: String) {
        let kept = shortened(stage, text)
        lock.lock(); defer { lock.unlock() }
        pending.append(TraceStage(stage: stage, text: kept))
    }

    /// Adds a call, or replaces the one with the same id (a call is written to as it goes).
    func upsert(_ call: ModelCallRecord) {
        guard Self.enabled else { return }
        lock.lock(); defer { lock.unlock() }
        if let i = calls.firstIndex(where: { $0.id == call.id }) { calls[i] = call } else { calls.append(call) }
    }

    func update(_ id: UUID, _ change: (inout ModelCallRecord) -> Void) {
        lock.lock(); defer { lock.unlock() }
        if let i = calls.firstIndex(where: { $0.id == id }) { change(&calls[i]) }
    }

    /// Says why the most recent call ended, when only the caller knows (the clock stopped it, the user did).
    func setOutcomeOfLatest(_ outcome: String, completion: String? = nil, cancelledBy: String? = nil) {
        lock.lock(); defer { lock.unlock() }
        guard let i = calls.indices.last else { return }
        var detail = calls[i].detail ?? CallDetail()
        detail.outcome = outcome
        if let completion { detail.completion = completion }
        if let cancelledBy { detail.cancelledBy = cancelledBy }
        calls[i].detail = detail
    }

    var snapshot: Snapshot {
        lock.lock(); defer { lock.unlock() }
        return Snapshot(stages: stages, calls: calls, began: began, turn: turnsBegun)
    }

    var callCount: Int { lock.lock(); defer { lock.unlock() }; return calls.count }
}

// MARK: - How much a call may write

/// The most one kind of call may write. The model is given `maxTokens` as its own cap; `RunawayGuard` stops reading earlier when the
/// answer's shape goes wrong (too long, too many items, the same item again and again), keeping the complete items. Starting values:
/// they are tuned from the first real trace, which shows how long a good answer really is.
nonisolated struct CallLimits: Equatable, Sendable {
    var maxTokens: Int
    var guardTokens: Int
    var maxItems: Int
    var repeatRun = 3
    var name = ""

    static let extract = CallLimits(maxTokens: 1_800, guardTokens: 1_500, maxItems: 40, name: "extract")
    static let review = CallLimits(maxTokens: 1_200, guardTokens: 1_000, maxItems: 30, name: "review")
    static let intent = CallLimits(maxTokens: 60, guardTokens: 50, maxItems: 4, name: "intent")
    static let question = CallLimits(maxTokens: 80, guardTokens: 65, maxItems: 4, name: "question")

    var label: String { "\(name.isEmpty ? "answer" : name): the model's cap \(maxTokens.formatted()) tokens; guard at ~\(guardTokens.formatted()) tokens, \(maxItems) items, or \(repeatRun) identical items in a row" }
}

// MARK: - The header of a shared trace

/// What a person reading a shared trace needs to know about the build, the device, the model and the limits that applied.
nonisolated enum TurnEnvironment {
    static func lines() -> [String] {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        var machine = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? ""
        if machine.isEmpty {
            var system = utsname()
            uname(&system)
            machine = withUnsafePointer(to: &system.machine) { $0.withMemoryRebound(to: CChar.self, capacity: Int(_SYS_NAMELEN)) { String(cString: $0) } }
        }
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        var out = ["App: Kitty \(version) (\(build))",
                   "Device: \(machine) | \(os)\(ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] == nil ? "" : " (simulator)")"]
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) {
            out.append("Model: \(String(describing: SystemLanguageModel.default.availability)) | window \(SystemLanguageModel.default.contextSize.formatted()) tokens")
        }
        #endif
        out.append("Locale: \(Locale.current.identifier) | time zone: \(TimeZone.current.identifier)")
        var clock = "Call clock: first output \(Int(CallClock.firstOutput)) s, idle \(Int(CallClock.idle)) s, ceiling \(Int(CallClock.ceiling)) s"
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) {
            clock += " | draft review \(Int(DecisionEngine.reviewTimeout)) s"
        }
        #endif
        out.append(clock)
        out.append("Caps: extract \(CallLimits.extract.label) | review \(CallLimits.review.label)")
        out.append("Switches: live model view \(LiveFeed.enabled ? "on" : "off") | save task details \(Trace.recording ? "on" : "off") | console trace \(Trace.enabled ? "on" : "off") | detail stages \(Trace.detail ? "on" : "off")")
        return out
    }
}
