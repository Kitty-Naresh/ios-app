import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - The flat extraction (`PathProfile.flat`)
//
// The model reads a request and returns only what the user said: a title for each task, and, when they said them, a repeat, a person,
// a day, a time, a reason and instructions. It does not return IDs, status, timestamps, categories, recurrence rules or a playbook.
// Swift owns everything else: the list that is made, the date that "tomorrow" is, the time that "evening" is, the repeat that
// "every morning" is, the defaults, the validation and the save. Nothing is saved without the user's approval.
//
// This path sits beside the production one (`.full`) and is selected only by a flag. See REAL_MODEL_FLAT_EXTRACTION.md for what it
// was measured against, and the README for what it does not support.

/// One task as the model wrote it, in plain Swift (so the validator and the tests do not depend on iOS 26). Every optional field is
/// nil when the user did not say it: an empty string is never kept for "absent".
struct ExtractionTaskValue: Equatable {
    var title = ""
    var schedule: String? = nil
    var assignee: String? = nil
    var dueDate: String? = nil        // as said ("tomorrow", "2026-11-02"); Swift resolves it
    var dueTime: String? = nil        // as said ("5 pm", "17:30", "evening"); Swift resolves it
    var purpose: String? = nil
    var instructions: String? = nil
    /// The list this task belongs to. The model names one list per response; the engine copies it here so that answers merged from
    /// several calls keep their own list.
    var listName: String? = nil
    /// Fields a draft's scope filled ("assignee", "day", "time"). Their evidence is the header words, not the task's own.
    var fromScope: Set<String> = []
}

/// What one extraction call returned (or several, merged).
struct ExtractionValue: Equatable {
    var outcome = "create"            // create, clarify or wait
    var listName: String? = nil
    var question: String? = nil
    /// The person, day and time the user said once for several tasks ("house help tasks for tomorrow"), as said. Swift checks them
    /// (`ScopeReader`) before any task takes them over; they are never trusted as they come.
    var scopeAssignee: String? = nil
    var scopeDay: String? = nil
    var scopeTime: String? = nil
    /// The new tasks are not for the scope the draft already carries (a different person, or no one in particular).
    var leavesScope = false
    var tasks: [ExtractionTaskValue] = []
    /// A call came back with the most it may write (12 tasks): there may be more in the words than it returned.
    var mayHaveMore = false
}

/// The session instructions, as the brief gives them.
enum TaskExtractionInstructions {
    /// The base text plus the lines behind `FlatExperiments`. Those lines were not measured on the real model, and a rule written in prose
    /// can backfire (a small model may copy the wording or over-apply it): switch one off there if the phone shows a regression.
    static var text: String {
        var parts = [base]
        if FlatExperiments.correctionLine { parts.append(FlatExperiments.correctionText) }
        if FlatExperiments.separateTargets { parts.append(FlatExperiments.separateTargetsText) }
        if FlatExperiments.scopeLine { parts.append(FlatExperiments.scopeText) }
        if FlatExperiments.draftLine { parts.append(FlatExperiments.draftText) }
        return parts.joined(separator: "\n\n")
    }

    private static let base = """
    Extract tasks from the user request. A task is one independently
    completable action or target.

    Return only context the user provided. Never invent values, tasks,
    substeps, dates, times, people, places, vendors, quantities, or metadata.

    Use title for a concise action plus specific target.

    Use schedule only when repetition is requested. Preserve the complete
    stated recurrence, including days, intervals, and exceptions. Do not
    convert a recurring request into multiple one-time tasks.

    Use purpose for a user-stated reason, event, or goal.
    Use instructions for user-stated quantity, dosage, variant, preference,
    method, or constraint.
    Do not duplicate the same user text in both fields.
    Leave optional fields empty when not provided.

    Use listName only when the user says the tasks go on, in or to a list,
    order or cart, or names one. Write the name the way the user said it.
    Leave it empty for standalone tasks. A list does not imply sequence.

    Fill a field only with words the user said for that task. If the user did
    not say it, leave the field out. Never guess a person, day, time, list,
    reason or quantity, and never use a word from these instructions as a value.

    Ask at most one focused question, and only when a missing detail prevents
    a usable task: unclear target, required dosage or quantity, or an
    unresolvable repetition rule.

    Do not ask for category, labels, purpose, location, vendor, or optional
    metadata. Do not ask for a time when only a date was given. Do not ask
    for a date when only a soft timeframe was given.

    Return create when drafts are usable.
    Return clarify when one essential question is needed.
    Return wait when no new task should be proposed.
    """
}

/// What the flat path sends: the words, what was asked and answered so far when a question is open, and, while a draft waits, the
/// state Swift has accepted (the draft by ref and the scope). Never the earlier transcript, never a date, never vocabulary: the
/// model does not work out a calendar date. A change to the draft goes through the review call; the state here is context for
/// reading the new words, so a later sentence ("Soak, washclothes") is read with the person and day already said.
enum FlatPrompt {
    static func build(words: String, dossier: String = "", state: String = "") -> String {
        var lines: [String] = []
        if !dossier.isEmpty { lines.append("Clarification so far:\n" + dossier) }
        if !state.isEmpty { lines.append(state) }
        lines.append("Request:\n" + words.trimmingCharacters(in: .whitespacesAndNewlines))
        return lines.joined(separator: "\n")
    }
}

extension FlatPrompt {
    /// How much of the draft the STATE block carries. The window decides: the item detail gives way first (full, compact, titles),
    /// then the DRAFT block, and the scope and the new words are never cut.
    enum StateDetail: Int, CaseIterable { case full, compact, titles, scopeOnly
        var name: String {
            switch self {
            case .full: return "full item detail"
            case .compact: return "title and category only"
            case .titles: return "titles only"
            case .scopeOnly: return "scope only, no draft items"
            }
        }
    }

    /// What Swift has accepted and holds: the scope said once for the draft, and the draft by ref. Empty (no block at all) when
    /// there is neither, so a first request is exactly what it was before. It is what is on the card, never the earlier words.
    static func state(items: [DraftItem], scope: DraftScope?, detail: StateDetail, now: Date, calendar: Calendar = .current) -> String {
        let scopeLines = scope?.lines ?? []
        guard !items.isEmpty || !scopeLines.isEmpty else { return "" }
        var lines = ["STATE"]
        lines.append(scopeLines.isEmpty ? "Scope: none" : "Scope (said once for the draft): " + scopeLines.joined(separator: ", "))
        if !items.isEmpty, detail != .scopeOnly {
            lines.append("DRAFT (refs as listed)")
            for item in items {
                switch detail {
                case .full: lines.append("\(item.ref). " + DraftReviewPrompt.describe(item, now: now, calendar: calendar, dayInWords: true))
                case .compact:
                    var row = "\(item.ref). \"\(item.title)\""
                    if let c = item.categoryName, !c.isEmpty { row += " | category \(c)" }
                    lines.append(row)
                case .titles, .scopeOnly: lines.append("\(item.ref). \"\(item.title)\"")
                }
            }
        }
        return lines.joined(separator: "\n")
    }
}

#if canImport(FoundationModels)
@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
@Generable
enum ExtractionOutcome: String, Codable {
    case create
    case clarify
    case wait
}

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
@Generable
struct TaskDraft {
    @Guide(description: "Concise action and specific target")
    var title: String

    @Guide(description: "Only a repeat the user asked for, in their words, such as every morning. Omit for a one-time task")
    var schedule: String?
    @Guide(description: "Person the user named for this task. Omit if none")
    var assignee: String?
    @Guide(description: "Day the user said, in their words, such as tomorrow or Saturday. Omit if none")
    var dueDate: String?
    @Guide(description: "Time or part of the day the user said, such as 5 pm or evening. Omit if none")
    var dueTime: String?
    @Guide(description: "A reason the user stated, in their words. Omit if they gave none")
    var purpose: String?
    @Guide(description: "A quantity, dosage or preference the user stated. Omit if they gave none")
    var instructions: String?
}

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
@Generable
struct TaskExtraction {
    @Guide(description: "create, clarify, or wait")
    var outcome: ExtractionOutcome

    @Guide(description: "Name of the list, order or cart the user said these tasks go on, as they said it. Omit unless the user said a list, order or cart")
    var listName: String?

    // No response-level person, day or time. Each task carries only what the user said for that task (see `TaskDraft`). The earlier
    // schema with `assignee`, `dueDate`, `dueTime` and `leavesScope` here was taken out with the scope paragraph of the instructions:
    // together they led the model to name a person nobody said (REAL_MODEL_PROMPT_ARMS.md).

    @Guide(description: "One essential clarification question, or omit")
    var question: String?

    @Guide(.maximumCount(12))
    var tasks: [TaskDraft]

    var value: ExtractionValue {
        let name = listName
        let made = tasks.map {
            ExtractionTaskValue(title: $0.title, schedule: $0.schedule, assignee: $0.assignee, dueDate: $0.dueDate, dueTime: $0.dueTime,
                                purpose: $0.purpose, instructions: $0.instructions, listName: name)
        }
        let word: String
        switch outcome {
        case .create: word = "create"
        case .clarify: word = "clarify"
        case .wait: word = "wait"
        }
        return ExtractionValue(outcome: word, listName: name, question: question, tasks: made, mayHaveMore: tasks.count >= 12)
    }
}

/// The on-device model, asked with the flat schema and the brief's instructions. A fresh session for every call, the same output
/// guard and clock as the other engines. Changes to a draft that waits go through the usual review call (`base`), so the review gate,
/// the version check and the recovery card are the same code on both paths.
@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
@MainActor
final class FlatExtractionEngine: DecisionProviding {
    private(set) var lastCallOverflowed = false
    private(set) var lastCallTimedOut = false
    private(set) var lastFailure: String?

    private let base: DecisionEngine
    private let createTimeout: TimeInterval = 45
    private var budgetKnown: ContextBudget?

    init(base: DecisionEngine? = nil) { self.base = base ?? DecisionEngine() }

    func extract(prompt: String, fresh: Bool) async -> BulkDecisionValue? {
        guard let e = await extraction(prompt: prompt) else { return nil }
        return BulkDecisionValue(wait: e.outcome == "wait", action: e.outcome, clarifyingQuestion: e.question ?? "", extraction: e)
    }

    /// One call with the flat schema. Nil means no answer (the reason is in `lastFailure`).
    func extraction(prompt: String) async -> ExtractionValue? {
        lastFailure = nil
        lastCallOverflowed = false
        lastCallTimedOut = false
        guard TaskPlanner.onDeviceModelAllowed, case .available = SystemLanguageModel.default.availability else {
            lastFailure = "the model is unavailable: \(TaskPlanner.fallbackReason())"
            ModelTape.skipped(kind: "extract", prompt: prompt, reason: "model unavailable")
            return nil
        }
        let instructions = TaskExtractionInstructions.text
        Trace.step("TO MODEL", "flat path, extract, fresh session; prompt \(Trace.size(prompt)), instructions \(Trace.size(instructions))\n\(prompt)")
        let session = LanguageModelSession(instructions: instructions)
        var failure: String?
        let work = Task { @MainActor () -> ExtractionValue? in
            do {
                return try await ModelTape.respond(session, kind: "extract", prompt: prompt, generating: TaskExtraction.self, limits: .extract).content.value
            } catch { failure = String(describing: error); return nil }
        }
        var timedOut = false
        let timer = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(createTimeout * 1_000_000_000))
            if !Task.isCancelled { timedOut = true; work.cancel() }
        }
        let value = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
        timer.cancel()
        if value == nil {
            let text = failure ?? ""
            let overflow = text.lowercased().contains("context") && text.lowercased().contains("exceed")
            lastCallOverflowed = overflow
            lastCallTimedOut = timedOut
            if timedOut { lastFailure = "the model took longer than \(Int(createTimeout)) s, so it was stopped" }
            else if text.contains("runaway") { lastFailure = "the output guard stopped the model: it was writing far more than this needs. Nothing it wrote was used" }
            else if overflow { lastFailure = "the request filled the model's window" }
            else if !text.isEmpty { lastFailure = "the model failed: \(text.prefix(120))" }
        }
        return value
    }

    var usesFlatEdit: Bool { true }
    private let editTimeout: TimeInterval = 30

    /// One call with the flat edit schema, for a draft that waits (or, later, the recent saved tasks). Nil means no answer (the
    /// reason is in `lastFailure`). A fresh session, the same output guard and clock as the extraction call.
    func edit(prompt: String, draftWaits: Bool, recentShown: Bool) async -> FlatEditValue? {
        lastFailure = nil
        lastCallOverflowed = false
        lastCallTimedOut = false
        guard TaskPlanner.onDeviceModelAllowed, case .available = SystemLanguageModel.default.availability else {
            lastFailure = "the model is unavailable: \(TaskPlanner.fallbackReason())"
            ModelTape.skipped(kind: "edit", prompt: prompt, reason: "model unavailable")
            return nil
        }
        let instructions = FlatEditInstructions.text(draftWaits: draftWaits, recentShown: recentShown)
        Trace.step("TO MODEL", "flat path, edit, fresh session; prompt \(Trace.size(prompt)), instructions \(Trace.size(instructions))\n\(prompt)")
        let session = LanguageModelSession(instructions: instructions)
        var failure: String?
        let work = Task { @MainActor () -> FlatEditValue? in
            do {
                return try await ModelTape.respond(session, kind: "edit", prompt: prompt, generating: TaskEditing.self, limits: .review).content.value
            } catch { failure = String(describing: error); return nil }
        }
        var timedOut = false
        let timer = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(editTimeout * 1_000_000_000))
            if !Task.isCancelled { timedOut = true; work.cancel() }
        }
        let value = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
        timer.cancel()
        if value == nil {
            let text = failure ?? ""
            let overflow = text.lowercased().contains("context") && text.lowercased().contains("exceed")
            lastCallOverflowed = overflow
            lastCallTimedOut = timedOut
            if timedOut { lastFailure = "the model took longer than \(Int(editTimeout)) s, so it was stopped" }
            else if text.contains("runaway") { lastFailure = "the output guard stopped the model: it was writing far more than an edit needs. Nothing it wrote was used" }
            else if overflow { lastFailure = "the request filled the model's window" }
            else if !text.isEmpty { lastFailure = "the model failed: \(text.prefix(120))" }
        }
        Trace.step("FROM MODEL", "flat edit: " + (value.map { String(describing: $0) } ?? "nothing (\(lastFailure ?? "cancelled"))"))
        return value
    }

    private let intentTimeout: TimeInterval = 15

    /// What the words are for. A tiny call: the words and one line of state, no task. Nil means no answer (see `lastFailure`).
    func intent(prompt: String) async -> FlatIntentValue? {
        lastFailure = nil
        lastCallOverflowed = false
        lastCallTimedOut = false
        guard TaskPlanner.onDeviceModelAllowed, case .available = SystemLanguageModel.default.availability else {
            lastFailure = "the model is unavailable: \(TaskPlanner.fallbackReason())"
            ModelTape.skipped(kind: "intent", prompt: prompt, reason: "model unavailable")
            return nil
        }
        let instructions = FlatIntentInstructions.text
        Trace.step("TO MODEL", "flat path, intent, fresh session; prompt \(Trace.size(prompt)), instructions \(Trace.size(instructions))\n\(prompt)")
        let session = LanguageModelSession(instructions: instructions)
        var failure: String?
        let work = Task { @MainActor () -> FlatIntentValue? in
            do {
                return try await ModelTape.respond(session, kind: "intent", prompt: prompt, generating: TaskIntent.self, limits: .intent).content.value
            } catch { failure = String(describing: error); return nil }
        }
        var timedOut = false
        let timer = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(intentTimeout * 1_000_000_000))
            if !Task.isCancelled { timedOut = true; work.cancel() }
        }
        let value = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
        timer.cancel()
        if value == nil {
            let text = failure ?? ""
            lastCallTimedOut = timedOut
            if timedOut { lastFailure = "the model took longer than \(Int(intentTimeout)) s, so it was stopped" }
            else if text.contains("runaway") { lastFailure = "the output guard stopped the model: it was writing far more than an intent needs" }
            else if !text.isEmpty { lastFailure = "the model failed: \(text.prefix(120))" }
        }
        Trace.step("FROM MODEL", "flat intent: " + (value.map { String(describing: $0) } ?? "nothing (\(lastFailure ?? "cancelled"))"))
        return value
    }

    private let questionTimeout: TimeInterval = 15

    /// One question asking what to add, for words that hold no task. Own session, own short instructions. Nil means no question (see `lastFailure`).
    func contentQuestion(prompt: String) async -> String? {
        lastFailure = nil
        lastCallOverflowed = false
        lastCallTimedOut = false
        guard TaskPlanner.onDeviceModelAllowed, case .available = SystemLanguageModel.default.availability else {
            lastFailure = "the model is unavailable: \(TaskPlanner.fallbackReason())"
            ModelTape.skipped(kind: "question", prompt: prompt, reason: "model unavailable")
            return nil
        }
        let instructions = ContentQuestionInstructions.text
        Trace.step("TO MODEL", "flat path, content question, fresh session; prompt \(Trace.size(prompt)), instructions \(Trace.size(instructions))\n\(prompt)")
        let session = LanguageModelSession(instructions: instructions)
        var failure: String?
        let work = Task { @MainActor () -> String? in
            do {
                return try await ModelTape.respond(session, kind: "question", prompt: prompt, generating: ContentQuestion.self, limits: .question).content.question
            } catch { failure = String(describing: error); return nil }
        }
        var timedOut = false
        let timer = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(questionTimeout * 1_000_000_000))
            if !Task.isCancelled { timedOut = true; work.cancel() }
        }
        let value = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
        timer.cancel()
        if value == nil {
            let text = failure ?? ""
            lastCallTimedOut = timedOut
            if timedOut { lastFailure = "the model took longer than \(Int(questionTimeout)) s, so it was stopped" }
            else if text.contains("runaway") { lastFailure = "the output guard stopped the model: it was writing far more than a question needs" }
            else if !text.isEmpty { lastFailure = "the model failed: \(text.prefix(120))" }
        }
        Trace.step("FROM MODEL", "flat content question: " + (value ?? "nothing (\(lastFailure ?? "cancelled"))"))
        return value
    }

    func review(prompt: String) async -> DraftEditValue? {
        let answer = await base.review(prompt: prompt)
        lastCallOverflowed = base.lastCallOverflowed
        lastCallTimedOut = base.lastCallTimedOut
        lastFailure = base.lastFailure
        return answer
    }

    func budget(_ kind: CallKind) async -> ContextBudget {
        guard kind == .extract else { return await base.budget(kind) }
        if let known = budgetKnown { return known }
        let service = await TokenBudgetService.measure(contextSize: SystemLanguageModel.default.contextSize)
        budgetKnown = service.contextBudget
        Trace.step("BUDGET", "flat extract call: " + service.fixedLine)
        return service.contextBudget
    }

    func tokens(of text: String) async -> (tokens: Int, exact: Bool) { await base.tokens(of: text) }
}
#endif
