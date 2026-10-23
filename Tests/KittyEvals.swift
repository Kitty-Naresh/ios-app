// Add this file to the UNIT TEST target only. The app module is Kitty.
//
// The evaluation harness for the voice to-do agent (v30): 60 numbered cases (A-G), conversation-quality grading (H),
// regression cases (I) and the 13 metrics. Every case is a recorded utterance sequence. The on-device model is replaced
// by recorded answers (`Script`), so a run is deterministic, needs no iOS 26 and never touches the user's real tasks.
// What is under test is everything around the model: the gate, the validators, the state machine, the draft editing,
// the one-shot confirmation and the wording of what Kitty says.
//
// Every run stores, per turn: the utterance, the new words, the route taken, the prompt sent to the model, the model's
// answer, the validation result, what Kitty said and the state it ended in. Per case it stores the saved objects.
// The JSON report is written to $KITTY_EVAL_REPORT, or /tmp/kitty-eval-report.json.
import XCTest
#if canImport(FoundationModels)
import FoundationModels
#endif
@testable import Kitty

// MARK: - Recorded model answers

/// What the model returns for one turn. `.none` means it is never asked (or it answers nothing).
enum Script {
    case none
    case single(AgentDecisionValue)
    case bulk(BulkDecisionValue)
    /// One answer per model call, in order (a long turn is read a few tasks at a time). After the last one: no answer.
    indirect case sequence([Script])
}

@MainActor
final class EvalEngine: DecisionProviding {
    var script: Script = .none {
        didSet {
            queue = []
            if case .sequence(let all) = script { queue = all }
        }
    }
    private var queue: [Script] = []
    private(set) var calls = 0

    /// What this call gets: the script itself, or the next answer of a sequence.
    private func next() -> Script {
        if case .sequence = script { return queue.isEmpty ? .none : queue.removeFirst() }
        return script
    }

    func decide(prompt: String) async -> AgentDecisionValue? {
        calls += 1
        if case .single(let d) = next() { return d }
        return nil
    }

    func decideBulk(prompt: String) async -> BulkDecisionValue? {
        if case .bulk(let b) = next() { calls += 1; return b }
        return nil
    }
}

// MARK: - Fixtures

enum Tag: String { case wait, clarify, bulk, metadata, task, routine, playbook, regression, quality, messy, long }

struct TaskExpect {
    var title: String
    var category: String? = nil           // nil: not checked
    var noCategory = false                // the category must be empty (an invalid one was refused)
    var dueDays: Int? = nil               // days after the fixed "today"; nil: there must be no due date
    var timeMinutes: Int? = nil           // nil: there must be no time
    var priority: String? = nil           // nil: there must be no priority
    var assignee: String? = nil           // nil: there must be no assignee
    var schedule: String? = nil           // routines: the schedule text
    var notes: String? = nil              // nil: not checked ("For in-laws" from the occasion of a long turn)
}

struct PlaybookExpect {
    var name: String
    var steps: Int
    var firstStep: String? = nil
    var dueDays: Int? = nil
}

struct SavedExpect {
    var tasks: [TaskExpect] = []
    var routines: [TaskExpect] = []
    var playbooks: [PlaybookExpect] = []
    var isEmpty: Bool { tasks.isEmpty && routines.isEmpty && playbooks.isEmpty }
    static let nothing = SavedExpect()
}

enum Outcome: String {
    case held           // the local gate kept it (or the user was still talking): no model call
    case modelWait      // the model said wait
    case ask            // one question
    case preview        // something is waiting for a yes (or the countdown)
    case saved          // saved during this turn
    case reply          // an answer with nothing to save
    case silent         // nothing said, nothing shown
}

struct TurnExpect {
    var outcome: Outcome
    var phase: ConversationPhase? = nil
    var visited: [ConversationPhase] = []        // states the machine must have passed through during this turn
    var says: [String] = []                      // lower-case fragments Kitty's words must contain
    var draft: [String]? = nil                   // the pending draft after this turn (exact titles)
    var model: Bool? = nil                       // whether the model was called in this turn
    var sees: String? = nil                      // the words the turn was worked out from (after cleaning), ignoring case and punctuation

    static func held() -> TurnExpect { TurnExpect(outcome: .held, phase: .listening, model: false) }
    static func ask(_ says: String..., model: Bool? = nil) -> TurnExpect {
        TurnExpect(outcome: .ask, phase: .awaitingClarification, says: says, model: model)
    }
    static func task(draft: [String]? = nil, says: [String] = []) -> TurnExpect {
        TurnExpect(outcome: .preview, phase: .pendingTask, says: says, draft: draft)
    }
    static func routine(draft: [String]? = nil) -> TurnExpect {
        TurnExpect(outcome: .preview, phase: .pendingRoutine, draft: draft)
    }
    static func draft(_ titles: [String], says: [String] = []) -> TurnExpect {
        TurnExpect(outcome: .preview, phase: .awaitingConfirmation, visited: [.pendingBulkDraft], says: says, draft: titles)
    }
    static func playbook(_ steps: [String], says: [String] = []) -> TurnExpect {
        TurnExpect(outcome: .preview, phase: .awaitingConfirmation, visited: [.pendingPlaybook], says: says, draft: steps)
    }
    static func saved(says: [String] = [], model: Bool? = nil) -> TurnExpect {
        TurnExpect(outcome: .saved, phase: .listening, says: says, model: model)
    }
    static func reply(_ says: String..., model: Bool? = nil) -> TurnExpect {
        TurnExpect(outcome: .reply, phase: .listening, says: says, model: model)
    }
}

struct EvalTurn {
    var say: String
    var script: Script = .none
    var silence: TimeInterval = 4.0              // quiet seconds after the words (10 or more is a long silence)
    var settle = false                           // the two-second countdown runs out after this turn (the last turn always settles)
    var expect: TurnExpect
}

struct EvalCase {
    var id: Int
    var category: String
    var name: String
    var tags: Set<Tag> = []
    var turns: [EvalTurn]
    var saved: SavedExpect = .nothing
    var finalDraft: [String]? = nil              // what is still pending when the conversation ends
    var chatter: [String] = []                   // lower-case fragments that must never end up in a task title
    var ruleFallback = false                     // on: the local rules answer when the model gives nothing usable
}

// MARK: - Script helpers

private func S(_ action: String, _ title: String = "", category: String = "", due: String = "", time: String = "",
                priority: String = "", assignee: String = "", freq: String = "", more: [String] = [], name: String = "", steps: [String] = [],
                q: String = "", spoken: String = "", wait: Bool = false) -> Script {
    .single(AgentDecisionValue(wait: wait, action: action, title: title, category: category, dueDate: due, dueTime: time,
                               priority: priority, assignee: assignee, frequency: freq, playbookName: name, playbookSteps: steps,
                               clarifyingQuestion: q, spokenResponse: spoken, moreTasks: more))
}

private func BT(_ titles: [String]) -> Script {
    .bulk(BulkDecisionValue(action: "create_tasks", tasks: titles.map { TaskDraftValue(title: $0) }))
}

private func BR(_ titles: [String], freq: String = "daily", schedule: String = "every day") -> Script {
    .bulk(BulkDecisionValue(action: "create_routines",
                            routines: titles.map { RoutineDraftValue(title: $0, frequency: freq, schedule: schedule) }))
}

private func BP(_ name: String, _ steps: [String]) -> Script {
    .bulk(BulkDecisionValue(action: "create_playbook",
                            playbook: PlaybookDraftValue(name: name, steps: steps.map { TaskDraftValue(title: $0) })))
}

private func turn(_ say: String, _ script: Script = .none, silence: TimeInterval = 4.0, _ expect: TurnExpect) -> EvalTurn {
    EvalTurn(say: say, script: script, silence: silence, expect: expect)
}

private func yes(_ say: String = "Yes", _ expect: TurnExpect = .saved(model: false)) -> EvalTurn {
    turn(say, .none, expect)
}

// MARK: - The 60 cases (A-G), the regression cases (I) and a few extras

enum EvalSuite {
    static let biryani = ["Chop onions", "Marinate the chicken", "Cook the rice", "Layer and steam"]

    static let all: [EvalCase] = a + b + c + d + e + f + g + i + j + k

    // MARK: A. Turn completeness

    static let a: [EvalCase] = [
        EvalCase(id: 1, category: "A", name: "“Add a task to…” waits", tags: [.wait],
                 turns: [turn("Add a task to…", .none, .held())]),
        EvalCase(id: 2, category: "A", name: "“Add a task to clean the…” waits", tags: [.wait],
                 turns: [turn("Add a task to clean the…", .none, .held())]),
        EvalCase(id: 3, category: "A", name: "“Um, I need to…” waits", tags: [.wait],
                 turns: [turn("Um, I need to…", .none, .held())]),
        EvalCase(id: 4, category: "A", name: "A complete task is evaluated and saved", tags: [.task],
                 turns: [turn("Add a task to clean the bathroom", S("create_task", "Clean the bathroom", category: "Bathroom"),
                              .saved(model: true))],
                 saved: SavedExpect(tasks: [TaskExpect(title: "Clean the bathroom", category: "Bathroom")])),
        EvalCase(id: 5, category: "A", name: "A trailing “and…” waits", tags: [.wait],
                 turns: [turn("Clean bathroom, buy milk, and…", .none, .held())]),
        EvalCase(id: 6, category: "A", name: "Three finished items are evaluated as a bulk draft", tags: [.bulk, .task],
                 turns: [turn("Clean bathroom, buy milk, and water plants", BT(["Clean bathroom", "Buy milk", "Water plants"]),
                              .draft(["Clean bathroom", "Buy milk", "Water plants"], says: ["3 tasks", "should i save these?"]))],
                 finalDraft: ["Clean bathroom", "Buy milk", "Water plants"]),
        EvalCase(id: 7, category: "A", name: "“Actually, make it high priority” updates the pending task", tags: [.task],
                 turns: [turn("Add a task to clean the bathroom", S("create_task", "Clean the bathroom"), .task(draft: ["Clean the bathroom"])),
                         turn("Actually, make it high priority", S("update_task", priority: "high"), .saved(model: true))],
                 saved: SavedExpect(tasks: [TaskExpect(title: "Clean the bathroom", priority: "high")])),
        EvalCase(id: 8, category: "A", name: "“Done” saves the pending task", tags: [.task],
                 turns: [turn("Add a task to clean the bathroom", S("create_task", "Clean the bathroom"), .task(draft: ["Clean the bathroom"])),
                         turn("done", .none, .saved(model: false))],
                 saved: SavedExpect(tasks: [TaskExpect(title: "Clean the bathroom")])),
    ]

    // MARK: B. Task validation

    static let b: [EvalCase] = [
        EvalCase(id: 9, category: "B", name: "“Add a task for the project” asks what should be done", tags: [.clarify],
                 turns: [turn("Add a task for the project", S("clarify", q: "What should be done for the project?"),
                              .ask("what should be done", model: true))]),
        EvalCase(id: 10, category: "B", name: "“Add a task to clean” asks what to clean after a long silence", tags: [.clarify],
                 turns: [turn("Add a task to clean", .none, silence: 11, .ask("what should i clean?", model: false))]),
        EvalCase(id: 11, category: "B", name: "A lone “Buy” asks what to buy after a long silence", tags: [.clarify, .wait],
                 turns: [turn("Buy", .none, silence: 11, .ask("what should i buy?", model: false))]),
        EvalCase(id: 12, category: "B", name: "“The bathroom” creates nothing", tags: [.wait],
                 turns: [turn("The bathroom", .none, .held())]),
        EvalCase(id: 13, category: "B", name: "“Add a task to clean the bathroom” creates a task", tags: [.task],
                 turns: [turn("Add a task to clean the bathroom", S("create_task", "Clean the bathroom"), .saved(model: true))],
                 saved: SavedExpect(tasks: [TaskExpect(title: "Clean the bathroom")])),
        EvalCase(id: 14, category: "B", name: "“Buy milk tomorrow” creates a task due tomorrow", tags: [.task, .metadata],
                 turns: [turn("Buy milk tomorrow", S("create_task", "Buy milk", due: "2026-10-22"), .saved())],
                 saved: SavedExpect(tasks: [TaskExpect(title: "Buy milk", dueDays: 1)])),
        EvalCase(id: 15, category: "B", name: "“Call the plumber about the leaking tap” creates a task", tags: [.task],
                 turns: [turn("Call the plumber about the leaking tap", S("create_task", "Call the plumber about the leaking tap"), .saved())],
                 saved: SavedExpect(tasks: [TaskExpect(title: "Call the plumber about the leaking tap")])),
        EvalCase(id: 16, category: "B", name: "“Add a task called bathroom” has no action, so it asks", tags: [.clarify],
                 turns: [turn("Add a task called bathroom", S("create_task", "Bathroom"), .ask("bathroom", model: true))]),
    ]

    // MARK: C. Routines

    static let c: [EvalCase] = [
        EvalCase(id: 17, category: "C", name: "Every morning is a daily routine", tags: [.routine],
                 turns: [turn("Water the plants every morning", S("create_routine", "Water the plants", category: "Plants", freq: "daily"), .saved())],
                 saved: SavedExpect(routines: [TaskExpect(title: "Water the plants", category: "Plants", schedule: "every day")])),
        EvalCase(id: 18, category: "C", name: "Every Monday is a weekly routine", tags: [.routine],
                 turns: [turn("Clean the bathroom every Monday", S("create_routine", "Clean the bathroom", freq: "weekly"), .saved())],
                 saved: SavedExpect(routines: [TaskExpect(title: "Clean the bathroom", schedule: "every Monday")])),
        EvalCase(id: 19, category: "C", name: "Every day is a daily routine", tags: [.routine],
                 turns: [turn("Take out trash every day", S("create_routine", "Take out trash", freq: "daily"), .saved())],
                 saved: SavedExpect(routines: [TaskExpect(title: "Take out trash", schedule: "every day")])),
        EvalCase(id: 20, category: "C", name: "“Buy milk tomorrow” is a one-time task, not a routine", tags: [.task],
                 turns: [turn("Buy milk tomorrow", S("create_task", "Buy milk", due: "2026-10-22"), .saved())],
                 saved: SavedExpect(tasks: [TaskExpect(title: "Buy milk", dueDays: 1)])),
        EvalCase(id: 21, category: "C", name: "“Add watering plants” asks one-time or routine", tags: [.clarify],
                 turns: [turn("Add watering plants", S("clarify", q: "Should this be a one-time task or a repeating routine?"),
                              .ask("one-time", "routine"))]),
        EvalCase(id: 22, category: "C", name: "A routine with an assignee", tags: [.routine, .metadata],
                 turns: [turn("Clean bathroom every Monday for househelp",
                              S("create_routine", "Clean bathroom", assignee: "Househelp", freq: "weekly"), .saved())],
                 saved: SavedExpect(routines: [TaskExpect(title: "Clean bathroom", assignee: "Househelp", schedule: "every Monday")])),
        EvalCase(id: 23, category: "C", name: "A daily list becomes three routines after one confirmation", tags: [.routine, .bulk],
                 turns: [turn("Every day: make beds, wash dishes, wipe counters", BR(["Make beds", "Wash dishes", "Wipe counters"]),
                              .draft(["Make beds", "Wash dishes", "Wipe counters"], says: ["3 daily routines"])),
                         yes("Yes", .saved(says: ["saved 3 routines"], model: false))],
                 saved: SavedExpect(routines: ["Make beds", "Wash dishes", "Wipe counters"].map { TaskExpect(title: $0, schedule: "every day") })),
    ]

    // MARK: D. Playbooks

    static let d: [EvalCase] = [
        EvalCase(id: 24, category: "D", name: "A playbook proposes steps and confirms once", tags: [.playbook],
                 turns: [turn("Create a playbook to cook biryani", BP("Cook biryani", biryani),
                              .playbook(biryani, says: ["should i include these steps"])),
                         yes("Yes", .saved(says: ["cook biryani playbook", "four steps"], model: false))],
                 saved: SavedExpect(playbooks: [PlaybookExpect(name: "Cook biryani", steps: 4)])),
        EvalCase(id: 25, category: "D", name: "A playbook with a due date", tags: [.playbook, .metadata],
                 turns: [turn("Prepare the home for guests this Saturday",
                              S("create_playbook", name: "Prepare home for guests", steps: ["Clean the living room", "Make the beds", "Stock the fridge"]),
                              .playbook(["Clean the living room", "Make the beds", "Stock the fridge"])),
                         yes()],
                 saved: SavedExpect(playbooks: [PlaybookExpect(name: "Prepare home for guests", steps: 3, dueDays: 3)])),
        EvalCase(id: 26, category: "D", name: "“Weekly deep clean” proposes steps", tags: [.playbook],
                 turns: [turn("Weekly deep clean", S("create_playbook", name: "Weekly deep clean", steps: ["Dust the shelves", "Mop the floors", "Scrub the bathrooms"]),
                              .playbook(["Dust the shelves", "Mop the floors", "Scrub the bathrooms"])),
                         yes()],
                 saved: SavedExpect(playbooks: [PlaybookExpect(name: "Weekly deep clean", steps: 3)])),
        EvalCase(id: 27, category: "D", name: "“Move-in cleaning” proposes steps", tags: [.playbook],
                 turns: [turn("Move-in cleaning", S("create_playbook", name: "Move-in cleaning", steps: ["Wipe the cabinets", "Clean the windows", "Mop the floors"]),
                              .playbook(["Wipe the cabinets", "Clean the windows", "Mop the floors"])),
                         yes()],
                 saved: SavedExpect(playbooks: [PlaybookExpect(name: "Move-in cleaning", steps: 3)])),
        EvalCase(id: 28, category: "D", name: "“Cook pasta” is ambiguous between a task and a playbook", tags: [.clarify],
                 turns: [turn("Cook pasta", S("clarify", q: "Is this a one-time task, or steps you want me to remember as a playbook?"),
                              .ask("playbook"))]),
        EvalCase(id: 29, category: "D", name: "A playbook step is added to the pending playbook", tags: [.playbook],
                 turns: [turn("Create a playbook to cook biryani", BP("Cook biryani", biryani), .playbook(biryani)),
                         turn("Add a playbook step: buy groceries", .none, .playbook(biryani + ["Buy groceries"], says: ["added step 5"])),
                         yes()],
                 saved: SavedExpect(playbooks: [PlaybookExpect(name: "Cook biryani", steps: 5)])),
        EvalCase(id: 30, category: "D", name: "Changing a step edits it in place, with no duplicate", tags: [.playbook],
                 turns: [turn("Create a playbook to cook biryani", BP("Cook biryani", biryani), .playbook(biryani)),
                         turn("Change the first step to buy vegetables", .none,
                              .playbook(["Buy vegetables", "Marinate the chicken", "Cook the rice", "Layer and steam"], says: ["changed step 1"])),
                         yes()],
                 saved: SavedExpect(playbooks: [PlaybookExpect(name: "Cook biryani", steps: 4, firstStep: "Buy vegetables")])),
    ]

    // MARK: E. Bulk creation

    static let three = ["Clean the bathroom", "Buy milk", "Water the plants"]

    static let e: [EvalCase] = [
        EvalCase(id: 31, category: "E", name: "Three actions make three task drafts", tags: [.bulk, .task],
                 turns: [turn("Clean the bathroom, buy milk, and water the plants", BT(three),
                              .draft(three, says: ["3 tasks", "clean the bathroom, buy milk, and water the plants", "should i save these?"]))],
                 finalDraft: three),
        EvalCase(id: 32, category: "E", name: "“Add these tasks: …” makes three drafts", tags: [.bulk, .task],
                 turns: [turn("Add these tasks: dishes, laundry, trash", BT(["Wash dishes", "Do laundry", "Take out trash"]),
                              .draft(["Wash dishes", "Do laundry", "Take out trash"]))],
                 finalDraft: ["Wash dishes", "Do laundry", "Take out trash"]),
        EvalCase(id: 33, category: "E", name: "A daily list makes three routine drafts", tags: [.bulk, .routine],
                 turns: [turn("Daily househelp tasks: make beds, wash dishes, wipe counters", BR(["Make beds", "Wash dishes", "Wipe counters"]),
                              .draft(["Make beds", "Wash dishes", "Wipe counters"], says: ["3 daily routines"])),
                         yes()],
                 saved: SavedExpect(routines: ["Make beds", "Wash dishes", "Wipe counters"].map { TaskExpect(title: $0, schedule: "every day") })),
        EvalCase(id: 34, category: "E", name: "“Buy milk and bread” is one grocery task", tags: [.bulk, .task],
                 turns: [turn("Buy milk and bread", S("create_task", "Buy milk and bread", category: "Groceries"), .saved())],
                 saved: SavedExpect(tasks: [TaskExpect(title: "Buy milk and bread", category: "Groceries")])),
        EvalCase(id: 35, category: "E", name: "“Clean the bathroom and buy milk” is two tasks", tags: [.bulk, .task],
                 turns: [turn("Clean the bathroom and buy milk", BT(["Clean the bathroom", "Buy milk"]),
                              .draft(["Clean the bathroom", "Buy milk"], says: ["2 tasks"])),
                         yes()],
                 saved: SavedExpect(tasks: [TaskExpect(title: "Clean the bathroom"), TaskExpect(title: "Buy milk")])),
        EvalCase(id: 36, category: "E", name: "Five tasks wait for one confirmation", tags: [.bulk, .task],
                 turns: [turn("Add five tasks: dishes, laundry, trash, beds, floors",
                              BT(["Wash dishes", "Do laundry", "Take out trash", "Make beds", "Mop floors"]),
                              .draft(["Wash dishes", "Do laundry", "Take out trash", "Make beds", "Mop floors"], says: ["5 tasks"])),
                         yes()],
                 saved: SavedExpect(tasks: ["Wash dishes", "Do laundry", "Take out trash", "Make beds", "Mop floors"].map { TaskExpect(title: $0) })),
        EvalCase(id: 37, category: "E", name: "“Actually change milk to bread” changes only the milk item", tags: [.bulk, .task],
                 turns: [turn("Clean the bathroom, buy milk, and water the plants", BT(three), .draft(three)),
                         turn("Actually change milk to bread", .none,
                              .draft(["Clean the bathroom", "Buy bread", "Water the plants"], says: ["changed it to buy bread"]).with(model: false)),
                         yes()],
                 saved: SavedExpect(tasks: ["Clean the bathroom", "Buy bread", "Water the plants"].map { TaskExpect(title: $0) })),
        EvalCase(id: 38, category: "E", name: "“Also add water plants” extends the pending draft", tags: [.bulk, .task],
                 turns: [turn("Clean the bathroom and buy milk", BT(["Clean the bathroom", "Buy milk"]), .draft(["Clean the bathroom", "Buy milk"])),
                         turn("Also add water plants", .none,
                              .draft(["Clean the bathroom", "Buy milk", "Water plants"], says: ["added water plants", "should i save these?"]).with(model: false)),
                         yes()],
                 saved: SavedExpect(tasks: ["Clean the bathroom", "Buy milk", "Water plants"].map { TaskExpect(title: $0) })),
        EvalCase(id: 39, category: "E", name: "“Yes, save them” saves all, once", tags: [.bulk, .task],
                 turns: [turn("Clean the bathroom, buy milk, and water the plants", BT(three), .draft(three)),
                         yes("Yes, save them", .saved(says: ["saved 3 tasks"], model: false))],
                 saved: SavedExpect(tasks: three.map { TaskExpect(title: $0) })),
        EvalCase(id: 40, category: "E", name: "“No, remove the trash task” removes only that item", tags: [.bulk, .task],
                 turns: [turn("Add these tasks: dishes, laundry, trash", BT(["Wash dishes", "Do laundry", "Take out trash"]),
                              .draft(["Wash dishes", "Do laundry", "Take out trash"])),
                         turn("No, remove the trash task", .none, .draft(["Wash dishes", "Do laundry"], says: ["removed take out trash"]).with(model: false)),
                         yes()],
                 saved: SavedExpect(tasks: [TaskExpect(title: "Wash dishes"), TaskExpect(title: "Do laundry")])),
    ]

    // MARK: F. Clarification loops

    static let f: [EvalCase] = [
        EvalCase(id: 41, category: "F", name: "“Add a task for laundry” asks one question", tags: [.clarify],
                 turns: [turn("Add a task for laundry", S("clarify", q: "Do you want to wash it, fold it, or put it away?"), .ask("wash"))]),
        EvalCase(id: 42, category: "F", name: "“Wash and fold it” answers it: saved, no second confirmation", tags: [.clarify, .task],
                 turns: [turn("Add a task for laundry", S("clarify", q: "Do you want to wash it, fold it, or put it away?"), .ask("wash")),
                         turn("Wash and fold it", S("create_task", "Wash and fold laundry"), .saved(model: true))],
                 saved: SavedExpect(tasks: [TaskExpect(title: "Wash and fold laundry")])),
        EvalCase(id: 43, category: "F", name: "“Add a task for the project” asks what action", tags: [.clarify],
                 turns: [turn("Add a task for the project", S("clarify", q: "What do you want to do for the project?"), .ask("what do you want to do"))]),
        EvalCase(id: 44, category: "F", name: "“Clean the garage” answers it", tags: [.clarify, .task],
                 turns: [turn("Add a task for the project", S("clarify", q: "What do you want to do for the project?"), .ask()),
                         turn("Clean the garage", S("create_task", "Clean the garage"), .saved())],
                 saved: SavedExpect(tasks: [TaskExpect(title: "Clean the garage")])),
        EvalCase(id: 45, category: "F", name: "“Add watering plants” asks one-time or routine", tags: [.clarify],
                 turns: [turn("Add watering plants", S("clarify", q: "Should this be a one-time task or a repeating routine?"), .ask("one-time", "routine"))]),
        EvalCase(id: 46, category: "F", name: "“Every morning” makes the routine with no further question", tags: [.clarify, .routine],
                 turns: [turn("Add watering plants", S("clarify", q: "Should this be a one-time task or a repeating routine?"), .ask()),
                         turn("Every morning", S("create_routine", "Water plants", freq: "daily"), .saved(model: true))],
                 saved: SavedExpect(routines: [TaskExpect(title: "Water plants", schedule: "every day")])),
        EvalCase(id: 47, category: "F", name: "A playbook for guests: steps and one confirmation question", tags: [.playbook],
                 turns: [turn("Create a playbook for guests", BP("Guest prep", ["Clean the guest room", "Make the bed", "Stock the fridge"]),
                              .playbook(["Clean the guest room", "Make the bed", "Stock the fridge"], says: ["should i include these steps"]))],
                 finalDraft: nil),
        EvalCase(id: 48, category: "F", name: "“Yes” saves the playbook and nothing more is asked", tags: [.playbook],
                 turns: [turn("Create a playbook for guests", BP("Guest prep", ["Clean the guest room", "Make the bed", "Stock the fridge"]),
                              .playbook(["Clean the guest room", "Make the bed", "Stock the fridge"])),
                         yes("Yes", .saved(says: ["guest prep playbook"], model: false))],
                 saved: SavedExpect(playbooks: [PlaybookExpect(name: "Guest prep", steps: 3)])),
        EvalCase(id: 49, category: "F", name: "“Add a task” asks what task, after a long silence", tags: [.clarify, .wait],
                 turns: [turn("Add a task", .none, silence: 11, .ask("what would you like the task to be?", model: false))]),
        EvalCase(id: 50, category: "F", name: "“Buy milk” answers it: saved, no confirmation", tags: [.clarify, .task],
                 turns: [turn("Add a task", .none, silence: 11, .ask()),
                         turn("Buy milk", S("create_task", "Buy milk"), .saved(model: true))],
                 saved: SavedExpect(tasks: [TaskExpect(title: "Buy milk")])),
    ]

    // MARK: G. Metadata extraction

    static let g: [EvalCase] = [
        EvalCase(id: 51, category: "G", name: "Due date, time and priority", tags: [.metadata, .task],
                 turns: [turn("Buy milk tomorrow at 9am, high priority",
                              S("create_task", "Buy milk", category: "Groceries", time: "09:00", priority: "high"), .saved())],
                 saved: SavedExpect(tasks: [TaskExpect(title: "Buy milk", category: "Groceries", dueDays: 1, timeMinutes: 540, priority: "high")])),
        EvalCase(id: 52, category: "G", name: "Assignee and due date", tags: [.metadata, .task],
                 turns: [turn("Ask Priya to clean the bathroom on Friday",
                              S("create_task", "Clean the bathroom", assignee: "Priya"), .saved())],
                 saved: SavedExpect(tasks: [TaskExpect(title: "Clean the bathroom", dueDays: 2, assignee: "Priya")])),
        EvalCase(id: 53, category: "G", name: "Frequency and schedule", tags: [.metadata, .routine],
                 turns: [turn("Clean the bathroom every Monday", S("create_routine", "Clean the bathroom", freq: "weekly"), .saved())],
                 saved: SavedExpect(routines: [TaskExpect(title: "Clean the bathroom", schedule: "every Monday")])),
        EvalCase(id: 54, category: "G", name: "Category Admin and no invented due date", tags: [.metadata, .task],
                 turns: [turn("Add a task to pay the electricity bill", S("create_task", "Pay the electricity bill", category: "Admin", due: "2026-10-22"), .saved())],
                 saved: SavedExpect(tasks: [TaskExpect(title: "Pay the electricity bill", category: "Admin")])),
        EvalCase(id: 55, category: "G", name: "Category Plants and a daily routine", tags: [.metadata, .routine],
                 turns: [turn("Water the balcony plants every morning", S("create_routine", "Water the balcony plants", category: "Plants", freq: "daily"), .saved())],
                 saved: SavedExpect(routines: [TaskExpect(title: "Water the balcony plants", category: "Plants", schedule: "every day")])),
        EvalCase(id: 56, category: "G", name: "Category Home Maintenance, one-time", tags: [.metadata, .task],
                 turns: [turn("Fix the leaking kitchen tap", S("create_task", "Fix the leaking kitchen tap", category: "Home Maintenance"), .saved())],
                 saved: SavedExpect(tasks: [TaskExpect(title: "Fix the leaking kitchen tap", category: "Home Maintenance")])),
        EvalCase(id: 57, category: "G", name: "Groceries and cleaning supplies stay one errand", tags: [.metadata, .task],
                 turns: [turn("Buy groceries and cleaning supplies", S("create_task", "Buy groceries and cleaning supplies", category: "Groceries"), .saved())],
                 saved: SavedExpect(tasks: [TaskExpect(title: "Buy groceries and cleaning supplies", category: "Groceries")])),
        EvalCase(id: 58, category: "G", name: "“Remind me to call mom tomorrow”", tags: [.metadata, .task],
                 turns: [turn("Remind me to call mom tomorrow", S("create_task", "Call mom"), .saved())],
                 saved: SavedExpect(tasks: [TaskExpect(title: "Call mom", dueDays: 1)])),
        EvalCase(id: 59, category: "G", name: "A task with no details asks", tags: [.clarify],
                 turns: [turn("Add a task with no details", S("clarify", q: "What would you like the task to be?"), .ask("what would you like the task to be?"))]),
        EvalCase(id: 60, category: "G", name: "Email John about the invoice tomorrow morning", tags: [.metadata, .task],
                 turns: [turn("Add a task to email John about the invoice tomorrow morning",
                              S("create_task", "Email John about the invoice"), .saved())],
                 saved: SavedExpect(tasks: [TaskExpect(title: "Email John about the invoice", dueDays: 1)])),
    ]

    // MARK: I. Regression cases (one per production failure) and extras

    static let i: [EvalCase] = [
        EvalCase(id: 61, category: "I", name: "No task is created after “um”; the rest is merged", tags: [.regression, .wait, .task],
                 turns: [turn("Um, I need to…", .none, .held()),
                         turn("buy milk", S("create_task", "Buy milk"), .saved(model: true))],
                 saved: SavedExpect(tasks: [TaskExpect(title: "Buy milk")])),
        EvalCase(id: 62, category: "I", name: "A long silence never asks “Are you done?”", tags: [.regression, .clarify, .wait],
                 turns: [turn("Add a task to", .none, silence: 12, .ask("what would you like the task to be?", model: false))]),
        EvalCase(id: 63, category: "I", name: "A second “yes” after saving saves nothing more", tags: [.regression, .bulk, .task],
                 turns: [turn("Clean the bathroom, buy milk, and water the plants", BT(three), .draft(three)),
                         yes(),
                         turn("Yes", .none, .reply("all set", model: false))],
                 saved: SavedExpect(tasks: three.map { TaskExpect(title: $0) })),
        EvalCase(id: 64, category: "I", name: "The same task is not saved twice after a clarification", tags: [.regression, .clarify, .task],
                 turns: [turn("Add a task for laundry", S("clarify", q: "Do you want to wash it, fold it, or put it away?"), .ask()),
                         EvalTurn(say: "Wash and fold it", script: S("create_task", "Wash and fold laundry"), settle: true, expect: .saved()),
                         turn("Wash and fold laundry", S("create_task", "Wash and fold laundry"), .reply("already on your list"))],
                 saved: SavedExpect(tasks: [TaskExpect(title: "Wash and fold laundry")])),
        EvalCase(id: 65, category: "I", name: "The pending draft survives “No” and a question", tags: [.regression, .bulk, .task],
                 turns: [turn("Add these tasks: dishes, laundry, trash", BT(["Wash dishes", "Do laundry", "Take out trash"]),
                              .draft(["Wash dishes", "Do laundry", "Take out trash"])),
                         turn("No", .none, TurnExpect(outcome: .ask, phase: .awaitingClarification, says: ["what would you like to change?"],
                                                       draft: ["Wash dishes", "Do laundry", "Take out trash"], model: false)),
                         turn("Remove the trash task", .none, .draft(["Wash dishes", "Do laundry"]).with(model: false)),
                         yes()],
                 saved: SavedExpect(tasks: [TaskExpect(title: "Wash dishes"), TaskExpect(title: "Do laundry")])),
        EvalCase(id: 66, category: "I", name: "A playbook with stated steps is one playbook, not separate tasks", tags: [.regression, .playbook],
                 turns: [turn("Create a playbook to cook biryani, first chop onions, then marinate chicken, then cook rice",
                              BP("Cook biryani", ["Chop onions", "Marinate chicken", "Cook rice"]),
                              .playbook(["Chop onions", "Marinate chicken", "Cook rice"], says: ["should i save the cook biryani playbook"])),
                         yes()],
                 saved: SavedExpect(playbooks: [PlaybookExpect(name: "Cook biryani", steps: 3)])),
        EvalCase(id: 67, category: "I", name: "A routine is never saved as a one-time task", tags: [.regression, .routine],
                 turns: [turn("Water the plants every morning", S("create_routine", "Water the plants", freq: "daily"), .saved())],
                 saved: SavedExpect(routines: [TaskExpect(title: "Water the plants", schedule: "every day")])),
        EvalCase(id: 68, category: "I", name: "An invented due date and assignee are dropped", tags: [.regression, .metadata, .task],
                 turns: [turn("Clean the bathroom", S("create_task", "Clean the bathroom", due: "2026-10-22", priority: "high", assignee: "Priya"), .saved())],
                 saved: SavedExpect(tasks: [TaskExpect(title: "Clean the bathroom")])),
        EvalCase(id: 69, category: "I", name: "A question about optional metadata is never asked", tags: [.regression, .task],
                 turns: [turn("Add a task to clean the bathroom", S("clarify", q: "When should this be due?"), .saved())],
                 saved: SavedExpect(tasks: [TaskExpect(title: "clean the bathroom")])),
        EvalCase(id: 70, category: "I", name: "Two questions in one are cut to the first", tags: [.regression, .clarify],
                 turns: [turn("Add a task for the garage", S("clarify", q: "What should I do in the garage? And when?"), .ask("what should i do in the garage?"))]),
        EvalCase(id: 71, category: "I", name: "Invalid categories are refused", tags: [.regression, .metadata, .task],
                 turns: [turn("Fix the leaking tap", S("create_task", "Fix the leaking tap", category: "Miscellaneous household repair stuff"), .saved())],
                 saved: SavedExpect(tasks: [TaskExpect(title: "Fix the leaking tap", noCategory: true)])),
        EvalCase(id: 72, category: "I", name: "The model's date is ignored: Swift resolves “tomorrow”", tags: [.regression, .metadata, .task],
                 turns: [turn("Buy milk tomorrow", S("create_task", "Buy milk", due: "2019-01-01"), .saved())],
                 saved: SavedExpect(tasks: [TaskExpect(title: "Buy milk", dueDays: 1)])),
        EvalCase(id: 73, category: "I", name: "More than five items are summarised by category", tags: [.regression, .bulk, .task],
                 turns: [turn("Add these tasks: dishes, laundry, trash, beds, floors, windows, plants",
                              .bulk(BulkDecisionValue(action: "create_tasks", tasks: [
                                TaskDraftValue(title: "Wash dishes"), TaskDraftValue(title: "Do laundry"), TaskDraftValue(title: "Take out trash"),
                                TaskDraftValue(title: "Make beds"), TaskDraftValue(title: "Mop floors"), TaskDraftValue(title: "Clean windows"),
                                TaskDraftValue(title: "Water plants", category: "Plants")])),
                              .draft(["Wash dishes", "Do laundry", "Take out trash", "Make beds", "Mop floors", "Clean windows", "Water plants"],
                                     says: ["7 tasks", "should i save these?"])),
                         yes("Yes", .saved(says: ["saved 7 tasks"], model: false))],
                 saved: SavedExpect(tasks: ["Wash dishes", "Do laundry", "Take out trash", "Make beds", "Mop floors", "Clean windows", "Water plants"]
                    .map { TaskExpect(title: $0) })),
        EvalCase(id: 74, category: "I", name: "After three questions Kitty proposes its best reading", tags: [.regression, .clarify],
                 turns: [turn("Add a task for laundry", S("clarify", q: "Do you want to wash it, fold it, or put it away?"), .ask()),
                         turn("the usual", S("clarify", q: "What do you mean by the usual?"), .ask()),
                         turn("you know", S("clarify", q: "Could you say that another way?"), .ask()),
                         turn("just do it", S("clarify", q: "Is it for today?"),
                              TurnExpect(outcome: .preview, phase: .awaitingConfirmation,
                                         says: ["should i save it this way, or would you like to change something?"])),
                         yes("Yes", .saved(model: false))],
                 saved: SavedExpect(tasks: [TaskExpect(title: "laundry the usual you know just do it")])),
        EvalCase(id: 75, category: "I", name: "“Actually make the bathroom task high priority” changes only that item", tags: [.regression, .bulk, .task],
                 turns: [turn("Clean the bathroom, buy milk, and water the plants", BT(three), .draft(three)),
                         turn("Actually make the bathroom task high priority", .none, .draft(three, says: ["made clean the bathroom high priority"]).with(model: false)),
                         yes()],
                 saved: SavedExpect(tasks: [TaskExpect(title: "Clean the bathroom", priority: "high"), TaskExpect(title: "Buy milk"),
                                            TaskExpect(title: "Water the plants")])),
    ]


    // MARK: J. Messy speech (fillers, repeats, taking words back, run-ons)

    private static func one(_ id: Int, _ name: String, _ say: String, sees: String, _ model: Script,
                            tags: Set<Tag> = [.messy, .task], saved: SavedExpect) -> EvalCase {
        EvalCase(id: id, category: "J", name: name, tags: tags,
                 turns: [turn(say, model, TurnExpect.saved(model: true).seeing(sees))], saved: saved)
    }

    private static func list(_ id: Int, _ name: String, _ say: String, sees: String, _ items: [String]) -> EvalCase {
        EvalCase(id: id, category: "J", name: name, tags: [.messy, .bulk, .task],
                 turns: [turn(say, BT(items), TurnExpect.draft(items).seeing(sees)), yes()],
                 saved: SavedExpect(tasks: items.map { TaskExpect(title: $0) }))
    }

    static let j: [EvalCase] = [
        // Fillers
        one(76, "A leading “Um,” is dropped", "Um, add a task to clean the bathroom", sees: "add a task to clean the bathroom",
            S("create_task", "Clean the bathroom"), saved: SavedExpect(tasks: [TaskExpect(title: "Clean the bathroom")])),
        one(77, "A mid-sentence “uh” is dropped", "Add a task uh to clean the bathroom", sees: "add a task to clean the bathroom",
            S("create_task", "Clean the bathroom"), saved: SavedExpect(tasks: [TaskExpect(title: "Clean the bathroom")])),
        one(78, "“you know” set off by commas is dropped, and “tomorrow” still resolves", "Buy milk, you know, tomorrow", sees: "buy milk tomorrow",
            S("create_task", "Buy milk", due: "2026-10-22"), tags: [.messy, .task, .metadata],
            saved: SavedExpect(tasks: [TaskExpect(title: "Buy milk", dueDays: 1)])),
        one(79, "“Er” and a comma-set “like,” are dropped", "Er, so I need to, like, call the plumber", sees: "so I need to, call the plumber",
            S("create_task", "Call the plumber"), saved: SavedExpect(tasks: [TaskExpect(title: "Call the plumber")])),
        one(80, "A filler inside a routine request", "Water the plants um every morning", sees: "water the plants every morning",
            S("create_routine", "Water the plants", freq: "daily"), tags: [.messy, .routine],
            saved: SavedExpect(routines: [TaskExpect(title: "Water the plants", schedule: "every day")])),
        one(81, "A leading “Basically,” is dropped", "Basically, clean the garage", sees: "clean the garage",
            S("create_task", "Clean the garage"), saved: SavedExpect(tasks: [TaskExpect(title: "Clean the garage")])),

        // Repeats
        one(82, "“to to” collapses", "Add a task to to clean the bathroom", sees: "add a task to clean the bathroom",
            S("create_task", "Clean the bathroom"), saved: SavedExpect(tasks: [TaskExpect(title: "Clean the bathroom")])),
        one(83, "A two-word restart: “clean the clean the”", "Clean the clean the bathroom", sees: "clean the bathroom",
            S("create_task", "Clean the bathroom"), saved: SavedExpect(tasks: [TaskExpect(title: "Clean the bathroom")])),
        one(84, "“buy buy” collapses and it stays one grocery task", "Buy buy milk and bread", sees: "buy milk and bread",
            S("create_task", "Buy milk and bread", category: "Groceries"),
            saved: SavedExpect(tasks: [TaskExpect(title: "Buy milk and bread", category: "Groceries")])),
        one(85, "“the the” collapses", "Call the the plumber about the leaking tap", sees: "call the plumber about the leaking tap",
            S("create_task", "Call the plumber about the leaking tap"),
            saved: SavedExpect(tasks: [TaskExpect(title: "Call the plumber about the leaking tap")])),

        // Self-repairs
        one(86, "“no wait” replaces the clause with a new action", "Clean the... no wait, wash the car", sees: "wash the car",
            S("create_task", "Wash the car"), saved: SavedExpect(tasks: [TaskExpect(title: "Wash the car")])),
        one(87, "The “add a task to” frame survives a repair", "Add a task to clean the bathroom, no wait, wash the car",
            sees: "add a task to wash the car", S("create_task", "Wash the car"),
            saved: SavedExpect(tasks: [TaskExpect(title: "Wash the car")])),
        one(88, "“I mean” replaces the last noun phrase", "Buy milk, I mean bread", sees: "buy bread",
            S("create_task", "Buy bread"), saved: SavedExpect(tasks: [TaskExpect(title: "Buy bread")])),
        one(89, "“no wait, Friday” replaces the day", "Call mom tomorrow, no wait, Friday", sees: "call mom Friday",
            S("create_task", "Call mom", due: "2026-10-23"), tags: [.messy, .task, .metadata],
            saved: SavedExpect(tasks: [TaskExpect(title: "Call mom", dueDays: 2)])),
        one(90, "“scratch that” drops the previous clause", "Buy milk, scratch that, call the plumber", sees: "call the plumber",
            S("create_task", "Call the plumber"), saved: SavedExpect(tasks: [TaskExpect(title: "Call the plumber")])),
        one(91, "“sorry,” replaces the action and keeps “remind me to”", "Remind me to pay rent, sorry, pay the electricity bill",
            sees: "remind me to pay the electricity bill", S("create_task", "Pay the electricity bill"),
            saved: SavedExpect(tasks: [TaskExpect(title: "Pay the electricity bill")])),
        one(92, "“or rather” swaps one place for another", "Clean the bathroom or rather the kitchen", sees: "clean the kitchen",
            S("create_task", "Clean the kitchen"), saved: SavedExpect(tasks: [TaskExpect(title: "Clean the kitchen")])),
        one(93, "A repair changes a routine's day", "Water the plants every Monday, no wait, every Tuesday",
            sees: "water the plants every Tuesday", S("create_routine", "Water the plants", freq: "weekly"), tags: [.messy, .routine],
            saved: SavedExpect(routines: [TaskExpect(title: "Water the plants", schedule: "every Tuesday")])),

        // Run-ons with no commas
        list(94, "A comma-free run-on of three actions", "clean the bathroom buy milk water the plants",
             sees: "clean the bathroom buy milk water the plants", three),
        list(95, "A run-on of two actions", "wash the car fold laundry", sees: "wash the car fold laundry", ["Wash the car", "Fold laundry"]),
        list(96, "A run-on whose second action contains “to buy”", "call mom ask her to buy milk", sees: "call mom ask her to buy milk",
             ["Call mom", "Ask her to buy milk"]),
        list(97, "A run-on of three short actions", "clean bathroom buy milk wash the car", sees: "clean bathroom buy milk wash the car",
             ["Clean bathroom", "Buy milk", "Wash the car"]),
        list(98, "A run-on starting with a phrasal verb", "take out the trash mop the floor", sees: "take out the trash mop the floor",
             ["Take out the trash", "Mop the floor"]),

        // Repairs in the middle of a list
        list(99, "“no wait” inside a list only replaces its own item", "Clean the bathroom, buy milk, no wait, buy bread, and water the plants",
             sees: "Clean the bathroom, buy bread, and water the plants", ["Clean the bathroom", "Buy bread", "Water the plants"]),
        list(100, "“scratch that” inside a list drops only its item", "Clean the bathroom, buy milk, scratch that, water the plants",
             sees: "Clean the bathroom, water the plants", ["Clean the bathroom", "Water the plants"]),
        list(101, "“I mean” inside a list swaps only its noun", "Wash the car, buy milk, I mean bread, call mom",
             sees: "Wash the car, buy bread, call mom", ["Wash the car", "Buy bread", "Call mom"]),

        // Guards: ordinary speech is left exactly as said
        one(102, "“say sorry to mom” is not a repair", "Say sorry to mom", sees: "say sorry to mom",
            S("create_task", "Say sorry to mom"), saved: SavedExpect(tasks: [TaskExpect(title: "Say sorry to mom")])),
        one(103, "“wait for the plumber” is a task, not a correction", "Wait for the plumber", sees: "wait for the plumber",
            S("create_task", "Wait for the plumber"), saved: SavedExpect(tasks: [TaskExpect(title: "Wait for the plumber")])),
        one(104, "“I would like to” keeps its “like”", "I would like to buy milk", sees: "I would like to buy milk",
            S("create_task", "Buy milk"), saved: SavedExpect(tasks: [TaskExpect(title: "Buy milk")])),
        EvalCase(id: 105, category: "J", name: "“it looks like rain” keeps its “like” and is asked about", tags: [.messy, .clarify],
                 turns: [turn("It looks like rain", S("clarify", q: "What would you like me to do about the rain?"),
                              TurnExpect.ask("what would you like", model: true).seeing("it looks like rain"))]),
        // A long prompt over two sentences: the setup sentence is not answered, and the whole thought is understood together.
        EvalCase(id: 106, category: "J", name: "A project over two sentences: held, then only the project's name is asked", tags: [.messy, .clarify],
                 turns: [
                    EvalTurn(say: "I'm working on a project and I would like to create list of tasks for that project.", script: .none,
                             silence: 4.0, expect: TurnExpect.held()),
                    EvalTurn(say: "And the first task is, to write a strategy document.", script: .none, silence: 5.2,
                             expect: TurnExpect.ask("project called", model: false)),
                 ]),
        // A numbered list with a number missing: one specific question, no guessing, and no model call.
        EvalCase(id: 107, category: "J", name: "A numbered list skips a number: asks if there is a number three", tags: [.messy, .clarify],
                 turns: [
                    EvalTurn(say: "I want to make a list of tasks for the Garden project. Number one buy soil. Number two plant tomatoes. Number four water the plants.",
                             script: .none, silence: 5.0, expect: TurnExpect.ask("number three", model: false)),
                 ]),
    ]

    // MARK: K. Long and noisy: stories, asides, several asks and one shared day

    // Today is Wednesday 21 October 2026: tomorrow +1, Friday +2, Saturday +3, Sunday +4, Monday +5.
    private static let longSilence: TimeInterval = VoiceTurnManager.extendedCap + 0.1

    /// A long turn that ends in a preview of `titles`. `then` carries on from there (answering the due-day question, then saving).
    private static func long(_ id: Int, _ name: String, _ say: String, model: Script, preview titles: [String], says: [String] = [],
                             then: [EvalTurn] = [], saved: SavedExpect, chatter: [String] = [], fallback: Bool = false,
                             tags: Set<Tag> = [.long, .bulk, .task]) -> EvalCase {
        var turns = [EvalTurn(say: say, script: model, silence: longSilence, expect: .draft(titles, says: says))]
        turns += then
        return EvalCase(id: id, category: "K", name: name, tags: tags, turns: turns, saved: saved, chatter: chatter, ruleFallback: fallback)
    }

    /// "Yes" or "No" to the question about tagging the undated tasks, then "Yes" to save.
    private static func answer(_ word: String, draft titles: [String], says: [String]) -> [EvalTurn] {
        [EvalTurn(say: word, script: .none, silence: longSilence, expect: .draft(titles, says: says)),
         EvalTurn(say: "Yes", script: .none, silence: longSilence, expect: .saved(model: false))]
    }

    private static func save() -> [EvalTurn] {
        [EvalTurn(say: "Yes", script: .none, silence: longSilence, expect: .saved(model: false))]
    }

    private static let inLawsSaid = "Okay so we have my in-laws coming this Saturday and honestly the house is a mess, so I was thinking the maid should clean the bathrooms and mop the living room on Friday, oh and I need to buy flowers and snacks, also remind me to call the caterer."
    private static let inLawsTitles = ["Clean the bathrooms", "Mop the living room", "Buy flowers and snacks", "Call the caterer"]
    private static let inLawsAsk = ["saturday, for in-laws", "tag the ones without a date as due saturday"]

    /// The four in-laws tasks as saved: the two cleaning tasks keep Friday and the maid, the occasion is in the notes.
    private static func inLawsSaved(undated: Int?) -> SavedExpect {
        SavedExpect(tasks: [
            TaskExpect(title: "Clean the bathrooms", dueDays: 2, assignee: "Househelp", notes: "For in-laws"),
            TaskExpect(title: "Mop the living room", dueDays: 2, assignee: "Househelp", notes: "For in-laws"),
            TaskExpect(title: "Buy flowers and snacks", dueDays: undated, notes: "For in-laws"),
            TaskExpect(title: "Call the caterer", dueDays: undated, notes: "For in-laws")])
    }

    private static let noDue = answer("No", draft: inLawsTitles, says: ["no due date for those", "should i save these"])
    private static let yesDue = answer("Yes", draft: inLawsTitles, says: ["tagged 2 tasks as due saturday", "should i save these"])

    private static func bt(_ titles: [String], assignee: String = "", due: String = "") -> BulkDecisionValue {
        BulkDecisionValue(action: "create_tasks", tasks: titles.map { TaskDraftValue(title: $0, dueDate: due, assignee: assignee) })
    }

    static let k: [EvalCase] = [
        // The in-laws example, answered both ways, and with the model getting it wrong in several ways
        long(108, "In-laws: Friday and the maid stay with their tasks, the day is asked, “no” leaves the rest dateless", inLawsSaid,
             model: BT(inLawsTitles), preview: inLawsTitles, says: inLawsAsk, then: noDue,
             saved: inLawsSaved(undated: nil), chatter: ["mess"]),
        long(109, "In-laws: “yes” tags only the two tasks that had no day", inLawsSaid,
             model: BT(inLawsTitles), preview: inLawsTitles, says: inLawsAsk, then: yesDue,
             saved: inLawsSaved(undated: 3), chatter: ["mess"]),
        long(110, "In-laws, the model only says wait: the tasks come from the clauses", inLawsSaid,
             model: .bulk(BulkDecisionValue(action: "wait")), preview: inLawsTitles, says: inLawsAsk, then: noDue,
             saved: inLawsSaved(undated: nil), chatter: ["mess"]),
        long(111, "In-laws, the model drops the caterer: it is added back from what was said", inLawsSaid,
             model: BT(Array(inLawsTitles.prefix(3))), preview: inLawsTitles, says: inLawsAsk, then: noDue,
             saved: inLawsSaved(undated: nil), chatter: ["mess"]),
        long(112, "In-laws, the model invents a task and turns the chatter into one: both are dropped", inLawsSaid,
             model: BT(inLawsTitles + ["Walk the dog", "Tidy the house mess"]), preview: inLawsTitles, says: inLawsAsk, then: noDue,
             saved: inLawsSaved(undated: nil), chatter: ["mess", "dog"]),
        long(113, "In-laws, the model spreads Saturday and the maid to every task: each keeps only its own", inLawsSaid,
             model: .bulk(bt(inLawsTitles, assignee: "Househelp", due: "2026-10-24")), preview: inLawsTitles, says: inLawsAsk, then: noDue,
             saved: inLawsSaved(undated: nil), chatter: ["mess"]),
        long(114, "In-laws, the model repeats a task: one draft", inLawsSaid,
             model: BT(["Clean the bathrooms", "Clean the bathrooms"] + inLawsTitles.dropFirst()), preview: inLawsTitles, says: inLawsAsk, then: noDue,
             saved: inLawsSaved(undated: nil), chatter: ["mess"]),

        // One ask inside a story
        EvalCase(id: 115, category: "K", name: "The plumber story: one task out of a ramble", tags: [.long, .task],
                 turns: [EvalTurn(say: "So last week the plumber came and he said the tap was leaking and honestly I don't know if he fixed it, anyway call the plumber about the leaking tap tomorrow morning.",
                                  script: S("create_task", "Call the plumber about the leaking tap", due: "2026-10-22"), silence: longSilence,
                                  expect: .saved(model: true))],
                 saved: SavedExpect(tasks: [TaskExpect(title: "Call the plumber about the leaking tap", dueDays: 1)]), chatter: ["last week", "fixed"]),
        EvalCase(id: 116, category: "K", name: "A story and one ask, the model says wait: the local rules answer", tags: [.long, .task],
                 turns: [EvalTurn(say: "So last week the electrician came and he said the wiring was old and honestly I don't know if he fixed it, anyway renew the passport.",
                                  script: S("wait", wait: true), silence: longSilence, expect: .saved(model: true))],
                 saved: SavedExpect(tasks: [TaskExpect(title: "Renew the passport")]), chatter: ["last week", "fixed"],
                 ruleFallback: true),
        EvalCase(id: 117, category: "K", name: "A bad day, then one ask: “buy milk”", tags: [.long, .task],
                 turns: [EvalTurn(say: "Honestly the kids are driving me up the wall today but anyway buy milk.", script: S("create_task", "Buy milk"),
                                  silence: longSilence, expect: .saved(model: true))],
                 saved: SavedExpect(tasks: [TaskExpect(title: "Buy milk")]), chatter: ["kids", "wall"]),

        // A shopping order and a routine after chatter
        EvalCase(id: 118, category: "K", name: "Blinkit order and a daily routine after chatter", tags: [.long, .bulk, .routine, .task],
                 turns: [EvalTurn(say: "Um so it's been a crazy week you know but add milk eggs and bread to my Blinkit order and water the plants every morning.",
                                  script: .bulk(BulkDecisionValue(action: "create_tasks",
                                                                  tasks: [TaskDraftValue(title: "Add milk, eggs and bread to Blinkit order")],
                                                                  routines: [RoutineDraftValue(title: "Water the plants", frequency: "daily", schedule: "every morning")])),
                                  silence: longSilence,
                                  expect: .draft(["Add milk, eggs and bread to Blinkit order", "Water the plants"])),
                         EvalTurn(say: "Yes", script: .none, silence: longSilence, expect: .saved(model: false))],
                 saved: SavedExpect(tasks: [TaskExpect(title: "Add milk, eggs and bread to Blinkit order")],
                                    routines: [TaskExpect(title: "Water the plants", schedule: "every day")]), chatter: ["crazy"]),

        // Chatter around a few asks, with their own days
        long(119, "A tired day, then two asks: Friday for one, “next week” left alone for the other",
             "Honestly I am so tired today and the kids were up all night, anyway remind me to pay the electricity bill on Friday and book the dentist for next week.",
             model: BT(["Pay the electricity bill", "Book the dentist"]), preview: ["Pay the electricity bill", "Book the dentist"],
             then: save(), saved: SavedExpect(tasks: [TaskExpect(title: "Pay the electricity bill", dueDays: 2), TaskExpect(title: "Book the dentist")]),
             chatter: ["tired", "kids"]),
        long(120, "Two asks with their own days and no shared day: nothing is asked",
             "Okay so work has been crazy and I forgot to say, can you add a task to renew the car insurance by next Monday and also call mom on Sunday.",
             model: BT(["Renew the car insurance", "Call mom"]), preview: ["Renew the car insurance", "Call mom"],
             then: save(), saved: SavedExpect(tasks: [TaskExpect(title: "Renew the car insurance", dueDays: 5), TaskExpect(title: "Call mom", dueDays: 4)]),
             chatter: ["crazy", "forgot"]),
        long(121, "“add buy…, add pay…, add call…”: the word “add” is not part of the task and the maid is only paid, not asked",
             "Today was a long day and I keep forgetting things so please add buy detergent, add pay the maid, and add call the electrician.",
             model: BT(["Buy detergent", "Pay the maid", "Call the electrician"]), preview: ["Buy detergent", "Pay the maid", "Call the electrician"],
             then: save(), saved: SavedExpect(tasks: [TaskExpect(title: "Buy detergent"), TaskExpect(title: "Pay the maid"), TaskExpect(title: "Call the electrician")]),
             chatter: ["forgetting", "long day"]),
        long(122, "The technician and the maid: the person belongs to the second task only",
             "So the washing machine is making a weird noise and my husband thinks it is the drum but I am not sure, so call the technician tomorrow and ask the maid to clean the filter on Friday.",
             model: BT(["Call the technician", "Clean the filter"]), preview: ["Call the technician", "Clean the filter"],
             then: save(), saved: SavedExpect(tasks: [TaskExpect(title: "Call the technician", dueDays: 1), TaskExpect(title: "Clean the filter", dueDays: 2, assignee: "Househelp")]),
             chatter: ["noise", "drum"]),
        long(123, "The technician and the maid, the model gives both tasks to the maid: only the second keeps her",
             "So the washing machine is making a weird noise and my husband thinks it is the drum but I am not sure, so call the technician tomorrow and ask the maid to clean the filter on Friday.",
             model: .bulk(bt(["Call the technician", "Clean the filter"], assignee: "Househelp")), preview: ["Call the technician", "Clean the filter"],
             then: save(), saved: SavedExpect(tasks: [TaskExpect(title: "Call the technician", dueDays: 1), TaskExpect(title: "Clean the filter", dueDays: 2, assignee: "Househelp")]),
             chatter: ["noise", "drum"]),
        long(124, "The cook, the driver and one for me: three people, three tasks",
             "Okay so ask the cook to prepare dinner at seven and tell the driver to wash the car on Saturday and I need to pay the school fees.",
             model: BT(["Prepare dinner", "Wash the car", "Pay the school fees"]), preview: ["Prepare dinner", "Wash the car", "Pay the school fees"],
             then: save(), saved: SavedExpect(tasks: [TaskExpect(title: "Prepare dinner", assignee: "Cook"), TaskExpect(title: "Wash the car", dueDays: 3, assignee: "Driver"),
                                                       TaskExpect(title: "Pay the school fees")]),
             chatter: []),
        long(125, "“remind me to” three times after “tomorrow is going to be hectic”: the day is asked, “yes” tags all three",
             "So tomorrow is going to be hectic, remind me to submit the report, remind me to call the bank, and don't forget to pick up the laundry.",
             model: BT(["Submit the report", "Call the bank", "Pick up the laundry"]), preview: ["Submit the report", "Call the bank", "Pick up the laundry"],
             says: ["because of tomorrow", "due tomorrow"],
             then: answer("Yes", draft: ["Submit the report", "Call the bank", "Pick up the laundry"], says: ["tagged 3 tasks as due tomorrow"]),
             saved: SavedExpect(tasks: ["Submit the report", "Call the bank", "Pick up the laundry"].map { TaskExpect(title: $0, dueDays: 1) }), chatter: ["hectic"]),
        long(126, "A sister is visiting next Tuesday: the visit goes in the notes and the day is asked",
             "So my sister is visiting next Tuesday and I want the guest room ready, so make the bed in the guest room, dust the shelves, and buy fresh towels.",
             model: BT(["Make the bed in the guest room", "Dust the shelves", "Buy fresh towels"]),
             preview: ["Make the bed in the guest room", "Dust the shelves", "Buy fresh towels"], says: ["tuesday, for the visit"],
             then: answer("No", draft: ["Make the bed in the guest room", "Dust the shelves", "Buy fresh towels"], says: ["no due date for those"]),
             saved: SavedExpect(tasks: ["Make the bed in the guest room", "Dust the shelves", "Buy fresh towels"].map { TaskExpect(title: $0, notes: "For the visit") }),
             chatter: ["i want"]),
        long(127, "Parents on Sunday, the maid on Friday: her task keeps Friday, the others are asked about Sunday",
             "My parents are coming on Sunday and the place is a disaster, so the maid should wash the curtains on Friday and I will buy fruits and arrange the guest bed.",
             model: BT(["Wash the curtains", "Buy fruits", "Arrange the guest bed"]), preview: ["Wash the curtains", "Buy fruits", "Arrange the guest bed"],
             says: ["sunday, for your parents"],
             then: answer("Yes", draft: ["Wash the curtains", "Buy fruits", "Arrange the guest bed"], says: ["tagged 2 tasks as due sunday"]),
             saved: SavedExpect(tasks: [TaskExpect(title: "Wash the curtains", dueDays: 2, assignee: "Househelp", notes: "For your parents"),
                                        TaskExpect(title: "Buy fruits", dueDays: 4, notes: "For your parents"),
                                        TaskExpect(title: "Arrange the guest bed", dueDays: 4, notes: "For your parents")]),
             chatter: ["disaster"]),
        long(128, "Guests on Friday and a party on Saturday: two days, so none is picked and nothing is asked",
             "So the guests arrive on Friday and the party is on Saturday, so buy snacks and book the cake.",
             model: BT(["Buy snacks", "Book the cake"]), preview: ["Buy snacks", "Book the cake"], then: save(),
             saved: SavedExpect(tasks: [TaskExpect(title: "Buy snacks", notes: "For guests"), TaskExpect(title: "Book the cake", notes: "For guests")])),
        long(129, "Parents on Sunday, the model gives every task a day of its own: only the said one stays",
             "My parents are coming on Sunday and the place is a disaster, so the maid should wash the curtains on Friday and I will buy fruits and arrange the guest bed.",
             model: .bulk(bt(["Wash the curtains", "Buy fruits", "Arrange the guest bed"], due: "2026-10-25")),
             preview: ["Wash the curtains", "Buy fruits", "Arrange the guest bed"], says: ["sunday, for your parents"],
             then: answer("No", draft: ["Wash the curtains", "Buy fruits", "Arrange the guest bed"], says: ["no due date for those"]),
             saved: SavedExpect(tasks: [TaskExpect(title: "Wash the curtains", dueDays: 2, assignee: "Househelp", notes: "For your parents"),
                                        TaskExpect(title: "Buy fruits", notes: "For your parents"),
                                        TaskExpect(title: "Arrange the guest bed", notes: "For your parents")]),
             chatter: ["disaster"]),
        long(130, "The AC guy comes tomorrow: both tasks are the househelp's and “yes” makes them due tomorrow",
             "So the AC guy is coming tomorrow and the living room is full of boxes, so the househelp should clear the boxes and wipe the shelves.",
             model: BT(["Clear the boxes", "Wipe the shelves"]), preview: ["Clear the boxes", "Wipe the shelves"], says: ["because of tomorrow"],
             then: answer("Yes", draft: ["Clear the boxes", "Wipe the shelves"], says: ["tagged 2 tasks as due tomorrow"]),
             saved: SavedExpect(tasks: [TaskExpect(title: "Clear the boxes", dueDays: 1, assignee: "Househelp"), TaskExpect(title: "Wipe the shelves", dueDays: 1, assignee: "Househelp")]),
             chatter: ["full of boxes"]),
        long(131, "A trip on Monday: four tasks, the maid's one is hers, the day is asked",
             "Okay so I am traveling on Monday and I need to pack my bag, charge the power bank, book the cab, and tell the maid to water the plants.",
             model: BT(["Pack my bag", "Charge the power bank", "Book the cab", "Water the plants"]),
             preview: ["Pack my bag", "Charge the power bank", "Book the cab", "Water the plants"], says: ["because of monday", "due monday"],
             then: answer("Yes", draft: ["Pack my bag", "Charge the power bank", "Book the cab", "Water the plants"], says: ["tagged 4 tasks as due monday"]),
             saved: SavedExpect(tasks: [TaskExpect(title: "Pack my bag", dueDays: 5), TaskExpect(title: "Charge the power bank", dueDays: 5),
                                        TaskExpect(title: "Book the cab", dueDays: 5), TaskExpect(title: "Water the plants", dueDays: 5, assignee: "Househelp")]),
             chatter: ["traveling"]),
        long(132, "“first… then… and then… and also…” over a messy kitchen: four tasks, no “first” in a title",
             "Okay so the kitchen is a disaster, first empty the fridge, then wipe the shelves, and then restock the vegetables, and also throw away the expired sauces.",
             model: BT(["Empty the fridge", "Wipe the shelves", "Restock the vegetables", "Throw away the expired sauces"]),
             preview: ["Empty the fridge", "Wipe the shelves", "Restock the vegetables", "Throw away the expired sauces"], then: save(),
             saved: SavedExpect(tasks: ["Empty the fridge", "Wipe the shelves", "Restock the vegetables", "Throw away the expired sauces"].map { TaskExpect(title: $0) }),
             chatter: ["disaster", "first"]),

        // Many tasks: a few at a time, several model calls
        long(133, "Six party tasks over two model calls, the day is asked and “no” leaves them dateless",
             "Okay so the party is on Saturday and we need a lot done, clean the kitchen, wipe the windows, sweep the balcony, wash the curtains, buy balloons, and order the cake.",
             model: .sequence([.bulk(bt(["Clean the kitchen", "Wipe the windows", "Sweep the balcony", "Wash the curtains"])),
                               .bulk(bt(["Buy balloons", "Order the cake"]))]),
             preview: ["Clean the kitchen", "Wipe the windows", "Sweep the balcony", "Wash the curtains", "Buy balloons", "Order the cake"],
             says: ["saturday, for the party"],
             then: answer("No", draft: ["Clean the kitchen", "Wipe the windows", "Sweep the balcony", "Wash the curtains", "Buy balloons", "Order the cake"], says: ["no due date for those"]),
             saved: SavedExpect(tasks: ["Clean the kitchen", "Wipe the windows", "Sweep the balcony", "Wash the curtains", "Buy balloons", "Order the cake"]
                .map { TaskExpect(title: $0, notes: "For the party") }), chatter: ["a lot"]),
        long(134, "Six party tasks, the second call says wait: the last two come from what was said",
             "Okay so the party is on Saturday and we need a lot done, clean the kitchen, wipe the windows, sweep the balcony, wash the curtains, buy balloons, and order the cake.",
             model: .sequence([.bulk(bt(["Clean the kitchen", "Wipe the windows", "Sweep the balcony", "Wash the curtains"])),
                               .bulk(BulkDecisionValue(action: "wait"))]),
             preview: ["Clean the kitchen", "Wipe the windows", "Sweep the balcony", "Wash the curtains", "Buy balloons", "Order the cake"],
             says: ["saturday, for the party"],
             then: answer("Yes", draft: ["Clean the kitchen", "Wipe the windows", "Sweep the balcony", "Wash the curtains", "Buy balloons", "Order the cake"], says: ["tagged 6 tasks as due saturday"]),
             saved: SavedExpect(tasks: ["Clean the kitchen", "Wipe the windows", "Sweep the balcony", "Wash the curtains", "Buy balloons", "Order the cake"]
                .map { TaskExpect(title: $0, dueDays: 3, notes: "For the party") }), chatter: ["a lot"]),
        long(135, "Nine chores over three model calls (4, 4 and 1)",
             "Okay so it's a busy week, clean the car, buy vegetables, fill the water bottles, call the electrician, pay the milkman, book the tickets, take the dog to the vet, wash the curtains, and renew the passport.",
             model: .sequence([.bulk(bt(["Clean the car", "Buy vegetables", "Fill the water bottles", "Call the electrician"])),
                               .bulk(bt(["Pay the milkman", "Book the tickets", "Take the dog to the vet", "Wash the curtains"])),
                               .bulk(bt(["Renew the passport"]))]),
             preview: ["Clean the car", "Buy vegetables", "Fill the water bottles", "Call the electrician", "Pay the milkman", "Book the tickets",
                       "Take the dog to the vet", "Wash the curtains", "Renew the passport"],
             then: save(),
             saved: SavedExpect(tasks: ["Clean the car", "Buy vegetables", "Fill the water bottles", "Call the electrician", "Pay the milkman", "Book the tickets",
                                        "Take the dog to the vet", "Wash the curtains", "Renew the passport"].map { TaskExpect(title: $0) }),
             chatter: ["busy week"]),

        // Nothing to do in it
        EvalCase(id: 136, category: "K", name: "Only complaints: the model waits and nothing is created", tags: [.long, .wait],
                 turns: [EvalTurn(say: "Honestly I have been feeling so tired lately and the weather is terrible and I do not know what to do about anything today.",
                                  script: S("wait", wait: true), silence: longSilence, expect: TurnExpect(outcome: .modelWait, model: true))]),
        EvalCase(id: 137, category: "K", name: "A call from the mother-in-law and a wish to relax: nothing to add", tags: [.long, .wait],
                 turns: [EvalTurn(say: "So my mother in law called and she was talking about the neighbours again and honestly I just want to relax this weekend.",
                                  script: S("wait", wait: true), silence: longSilence, expect: TurnExpect(outcome: .modelWait, model: true))]),
    ]

    /// The twelve to start with.
    static let minimal12: [Int] = [1, 2, 4, 41, 42, 17, 45, 24, 48, 31, 39, 75]
}

private extension TurnExpect {
    func with(model: Bool) -> TurnExpect { var c = self; c.model = model; return c }
    func seeing(_ words: String) -> TurnExpect { var c = self; c.sees = words; return c }
}

// MARK: - Grading what Kitty says (category H)

enum Judge {
    static let robotic = ["are you done", "shall i go ahead", "please provide", "required field", "as an ai", "i have created",
                          "i have added", "anything else", "would you like me to proceed", "do you want to proceed", "in a meaningful way"]

    struct Grade { var score: Int; var issues: [String] }

    /// Five points: short, one question at most, natural wording, not a repeat, finished sentence.
    static func grade(_ line: String, earlier: [String]) -> Grade {
        let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()
        var issues: [String] = []
        let words = text.split(separator: " ").count
        if words == 0 || words > 32 { issues.append("length: \(words) words") }
        if text.filter({ $0 == "?" }).count > 1 { issues.append("more than one question") }
        if let r = robotic.first(where: { lower.contains($0) }) { issues.append("robotic: “\(r)”") }
        if earlier.contains(where: { VoiceTurnManager.norm($0) == VoiceTurnManager.norm(text) }), text.contains("?") {
            issues.append("repeated question")
        }
        if let last = text.last, !".?!”)".contains(last) { issues.append("unfinished sentence") }
        return Grade(score: max(0, 5 - issues.count), issues: issues)
    }
}

// MARK: - Running a case

struct TurnRecord {
    var utterance = ""
    var silence: TimeInterval = 0
    var gate = ""
    var route = ""
    var prompt: String?
    var modelOutput: String?
    var validation: String?
    var outcome = Outcome.silent
    var spoken: String?
    var phase = ConversationPhase.idle
    var transitions: [ConversationPhase] = []
    var modelCalled = false
    var sees = ""
    var draft: [String] = []
    var failures: [String] = []
}

struct CaseResult {
    var evalCase: EvalCase
    var turns: [TurnRecord] = []
    var failures: [String] = []
    var tasks: [PlannedTask] = []
    var routines: [PlannedTask] = []
    var playbooks: [(name: String, steps: [PlaybookStep], due: Date?)] = []
    var executions: [Int] = []
    var spoken: [String] = []
    var questions: [String] = []
    var quality: [Judge.Grade] = []
    var qualityIssues: [String] = []
    var fieldChecks: (passed: Int, total: Int) = (0, 0)
    var inventedObjects = 0
    var savedObjects = 0
    var duplicateObjects = 0
    var typeCorrect = true
    // Category K (long and noisy): what was asked for, what came out, and how much of the shared context was carried right.
    var kExpected = 0, kFound = 0, kSaved = 0, kMatched = 0, kChatter = 0
    var carryPassed = 0, carryTotal = 0
    var passed: Bool { failures.isEmpty }
}

@MainActor
final class EvalRunner {
    static let knownCategories = ["Bathroom", "Groceries", "Plants", "Admin", "Home Maintenance", "Errands", "Kitchen", "Laundry"]
    static let calendar = Calendar.current
    static var now: Date { DateComponents(calendar: calendar, year: 2026, month: 10, day: 21, hour: 9).date! }

    static func day(_ offset: Int) -> Date {
        calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now))!
    }

    // One conversation: what the screen would be holding between turns.
    private let engine = EvalEngine()
    private let sink = InMemorySaveSink()
    private let manager: VoiceTurnManager
    private var turnText = ""
    private var processed = ""
    private var proposal: Proposal?
    private var questionOpen = false
    private var holding = false
    private var lastActedRaw = ""          // the speech last acted on, as heard (the screen keeps the same)
    private var executions: [UUID: Int] = [:]

    init() {
        manager = VoiceTurnManager(engine: engine, sink: sink, knownCategories: { EvalRunner.knownCategories })
        manager.ruleFallbackEnabled = false
        manager.state.setListening(true)
    }

    // MARK: A whole case

    static func run(_ c: EvalCase) async -> CaseResult {
        let runner = EvalRunner()
        runner.manager.ruleFallbackEnabled = c.ruleFallback
        // The local rules read the user's list names from UserDefaults: another test's lists must not change what they make of a title.
        if c.ruleFallback { UserDefaults.standard.removeObject(forKey: KittyGuideStore.profileNamesKey) }
        var result = CaseResult(evalCase: c)
        for (index, t) in c.turns.enumerated() {
            let record = await runner.step(t, isLast: index == c.turns.count - 1)
            result.turns.append(record)
            for f in record.failures { result.failures.append("turn \(index + 1) “\(t.say)”: \(f)") }
            if let s = record.spoken {
                let g = Judge.grade(s, earlier: result.spoken)
                result.quality.append(g)
                for issue in g.issues { result.qualityIssues.append("turn \(index + 1): \(issue)") }
                result.spoken.append(s)
                if record.outcome == .ask { result.questions.append(s) }
            }
        }
        runner.finish(&result)
        return result
    }

    // MARK: One turn

    private func join(_ a: String, _ b: String) -> String {
        [a, b].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    private func newPart(of text: String, after done: String) -> String {
        let t = VoiceTurnManager.norm(text), p = VoiceTurnManager.norm(done)
        if !p.isEmpty, t.hasPrefix(p) { return String(t.dropFirst(p.count)).trimmingCharacters(in: .whitespaces) }
        return t
    }

    private func resetTurn() {
        manager.state.clearPending()
        turnText = ""; processed = ""; lastActedRaw = ""; proposal = nil; questionOpen = false; holding = false
    }

    /// The same one-shot guard the screen uses.
    private func confirm() async -> String? {
        guard let p = proposal, manager.state.confirmation.consume(p.id) else { return nil }
        executions[p.id, default: 0] += 1
        let reply = await p.apply()
        if p.pendingPlaybook == nil, reply.didAdd || reply.didChange {
            manager.state.noteCreated(p.rows.map { (title: $0.title, id: UUID()) }, now: Self.now)
        }
        resetTurn()
        return reply.message
    }

    private var draftTitles: [String] {
        if let pb = manager.state.drafts.playbook { return pb.steps.map(\.title) }
        if manager.state.drafts.hasContent { return manager.state.drafts.items.map(\.title) }
        return manager.state.pendingTitles
    }

    private func step(_ t: EvalTurn, isLast: Bool) async -> TurnRecord {
        var r = TurnRecord(utterance: t.say, silence: t.silence)
        let transitionsBefore = manager.state.transitions.count
        let callsBefore = manager.modelCalls
        engine.script = t.script
        turnText = (proposal != nil || questionOpen || holding) ? join(turnText, t.say) : t.say

        var outcome = Outcome.silent
        var spoken: String?

        let gate = VoiceTurnManager.gate(utterance: turnText, silence: t.silence, lastActed: lastActedRaw)
        switch gate {
        case .keepListening, .hold(_):
            r.gate = "\(gate)"
            holding = true
            outcome = .held

        case .nudge:
            r.gate = "nudge"
            if proposal != nil {
                outcome = .preview
            } else if let q = manager.nudgeQuestion(for: turnText) {
                processed = turnText
                manager.state.markProcessed(turnText)
                questionOpen = true; holding = false
                outcome = .ask; spoken = q
            } else {
                resetTurn()
                outcome = .silent
            }

        case .evaluate(let text), .forceEvaluate(let text):
            var isForce = false
            if case .forceEvaluate = gate { isForce = true }
            r.gate = isForce ? "forceEvaluate" : "evaluate"
            var handled = false

            if proposal != nil {
                if isForce, VoiceTurnManager.norm(text) == VoiceTurnManager.norm(processed) {
                    spoken = await confirm(); outcome = spoken == nil ? .silent : .saved; handled = true
                    r.route = "shortcut-done"
                } else {
                    var fresh = newPart(of: text, after: processed)
                    if fresh.isEmpty { fresh = newPart(of: turnText, after: lastActedRaw) }      // a repeated "yes" is collapsed by the cleaner
                    switch ConfirmationManager.interpret(fresh) {
                    case .yes where manager.state.pendingContextDue == nil:      // with a due-date question open, "yes" answers it
                        spoken = await confirm(); outcome = spoken == nil ? .silent : .saved; handled = true
                        r.route = "shortcut-yes"
                    case .cancel:
                        resetTurn(); outcome = .reply; spoken = "Okay, I didn't change anything."; handled = true
                        r.route = "shortcut-cancel"
                    case .yes, .no, .other:
                        break
                    }
                }
            }

            if !handled {
                processed = text
                lastActedRaw = turnText
                let result = await manager.decide(utterance: text, now: Self.now)
                let trace = manager.lastTrace
                r.route = trace.route
                r.sees = trace.utterance
                r.prompt = trace.prompt
                r.modelOutput = trace.modelOutput
                r.validation = trace.validation
                switch result {
                case .wait:
                    outcome = .modelWait; holding = true
                case .reply(let reply):
                    outcome = .reply; spoken = reply.message
                    turnText = ""; processed = ""; proposal = nil; questionOpen = false; holding = false
                case .question(let q):
                    outcome = .ask; spoken = q; questionOpen = true; holding = false; proposal = nil
                case .proposal(let p):
                    questionOpen = false; holding = false
                    proposal = p
                    if p.runImmediately || (p.autoConfirm && (isLast || t.settle)) {
                        spoken = await confirm(); outcome = spoken == nil ? .silent : .saved
                    } else {
                        outcome = .preview; spoken = p.prompt
                    }
                }
            }
        }

        r.outcome = outcome
        r.spoken = spoken
        r.phase = manager.state.phase
        r.transitions = Array(manager.state.transitions.dropFirst(transitionsBefore))
        r.modelCalled = manager.modelCalls > callsBefore
        r.draft = draftTitles
        r.failures = check(t.expect, r)
        return r
    }

    private func check(_ e: TurnExpect, _ r: TurnRecord) -> [String] {
        var f: [String] = []
        if r.outcome != e.outcome { f.append("outcome \(r.outcome.rawValue), expected \(e.outcome.rawValue)\(r.spoken.map { " (“\($0)”)" } ?? "")") }
        if let p = e.phase, r.phase != p { f.append("state \(r.phase.rawValue), expected \(p.rawValue)") }
        for v in e.visited where !r.transitions.contains(v) { f.append("never passed through \(v.rawValue)") }
        let said = (r.spoken ?? "").lowercased()
        for s in e.says where !said.contains(s) { f.append("Kitty should say “\(s)”, said “\(r.spoken ?? "")”") }
        if let want = e.draft {
            let a = r.draft.map(TaskValidator.key), b = want.map(TaskValidator.key)
            if a != b { f.append("pending draft \(r.draft), expected \(want)") }
        }
        if let m = e.model, r.modelCalled != m { f.append("model called: \(r.modelCalled), expected \(m)") }
        if let w = e.sees, VoiceTurnManager.norm(r.sees) != VoiceTurnManager.norm(w) { f.append("worked from “\(r.sees)”, expected “\(w)”") }
        return f
    }

    // MARK: What ended up saved

    private func finish(_ result: inout CaseResult) {
        let c = result.evalCase
        result.tasks = sink.tasks
        result.routines = sink.routines
        result.playbooks = sink.playbooks.map { (name: $0.name, steps: $0.steps, due: $0.due) }
        result.executions = Array(executions.values)

        if executions.values.contains(where: { $0 != 1 }) { result.failures.append("a confirmation ran more than once") }

        var passed = 0, total = 0
        func check(_ ok: Bool, _ what: @autoclosure () -> String) {
            total += 1
            if ok { passed += 1 } else { result.failures.append(what()) }
        }
        let cal = Self.calendar

        func match(_ expected: [TaskExpect], _ actual: [PlannedTask], kind: String) {
            check(actual.count == expected.count, "\(kind): saved \(actual.count), expected \(expected.count): \(actual.map(\.title))")
            if c.category == "K" {
                let want = Set(expected.map { TaskValidator.key($0.title) })
                result.kExpected += expected.count
                result.kFound += expected.filter { e in actual.contains { TaskValidator.key($0.title) == TaskValidator.key(e.title) } }.count
                result.kSaved += actual.count
                result.kMatched += actual.filter { want.contains(TaskValidator.key($0.title)) }.count
                result.kChatter += actual.filter { a in c.chatter.contains { a.title.lowercased().contains($0) } }.count
            }
            var seen = Set<String>()
            for p in actual where !seen.insert(TaskValidator.key(p.title)).inserted { result.duplicateObjects += 1 }
            result.savedObjects += actual.count
            for e in expected {
                guard let a = actual.first(where: { TaskValidator.key($0.title) == TaskValidator.key(e.title) }) else {
                    check(false, "\(kind) “\(e.title)” was not saved (saved: \(actual.map(\.title)))")
                    continue
                }
                var invented = false
                check(true, "")
                if c.category == "K" {
                    // Did the day, the person and the occasion land on the right tasks, and only on those?
                    func carry(_ ok: Bool) { result.carryTotal += 1; if ok { result.carryPassed += 1 } }
                    carry(e.dueDays.map { d in a.due.map { cal.isDate($0, inSameDayAs: Self.day(d)) } ?? false } ?? (a.due == nil))
                    carry((a.assignee ?? "").lowercased() == (e.assignee ?? "").lowercased())
                    if let n = e.notes { carry(a.notes == n) }
                }
                if let n = e.notes { check(a.notes == n, "“\(e.title)” notes \(a.notes ?? "nil"), expected \(n)") }
                if let cat = e.category {
                    check((a.categoryName ?? a.category.rawValue).lowercased().contains(cat.lowercased()) || a.category.rawValue.lowercased() == cat.lowercased(),
                          "“\(e.title)” category \(a.categoryName ?? "nil")/\(a.category.rawValue), expected \(cat)")
                }
                if e.noCategory { check(a.categoryName == nil, "“\(e.title)” saved the invalid category \(a.categoryName ?? "")") }

                let wantDue = e.dueDays.map { Self.day($0) }
                if let w = wantDue, let d = a.due { check(cal.isDate(d, inSameDayAs: w), "“\(e.title)” due \(d), expected \(w)") }
                else if wantDue == nil, a.recurrence == nil { check(a.due == nil, "“\(e.title)” has an invented due date \(String(describing: a.due))"); if a.due != nil { invented = true } }
                else if wantDue != nil { check(false, "“\(e.title)” has no due date, expected \(String(describing: wantDue))") }

                check(a.timeMinutes == e.timeMinutes, "“\(e.title)” time \(String(describing: a.timeMinutes)), expected \(String(describing: e.timeMinutes))")
                if a.timeMinutes != nil, e.timeMinutes == nil { invented = true }
                check(a.priority == e.priority, "“\(e.title)” priority \(a.priority ?? "nil"), expected \(e.priority ?? "nil")")
                if a.priority != nil, e.priority == nil { invented = true }
                check((a.assignee ?? "").lowercased() == (e.assignee ?? "").lowercased(), "“\(e.title)” assignee \(a.assignee ?? "nil"), expected \(e.assignee ?? "nil")")
                if a.assignee != nil, e.assignee == nil { invented = true }
                if let s = e.schedule {
                    check((a.recurrence?.scheduleText ?? "").lowercased() == s.lowercased(), "“\(e.title)” schedule \(a.recurrence?.scheduleText ?? "nil"), expected \(s)")
                } else if kind == "task" {
                    check(a.recurrence == nil, "“\(e.title)” was saved as a routine")
                    if a.recurrence != nil { invented = true }
                }
                if invented { result.inventedObjects += 1 }
            }
        }

        match(c.saved.tasks, result.tasks, kind: "task")
        match(c.saved.routines, result.routines, kind: "routine")

        check(result.playbooks.count == c.saved.playbooks.count, "playbooks saved \(result.playbooks.count), expected \(c.saved.playbooks.count)")
        result.savedObjects += result.playbooks.count
        for e in c.saved.playbooks {
            guard let a = result.playbooks.first(where: { TaskValidator.key($0.name) == TaskValidator.key(e.name) }) else {
                check(false, "playbook “\(e.name)” was not saved"); continue
            }
            check(a.steps.count == e.steps, "playbook “\(e.name)” has \(a.steps.count) steps, expected \(e.steps)")
            if let first = e.firstStep { check(TaskValidator.key(a.steps.first?.title ?? "") == TaskValidator.key(first), "first step \(a.steps.first?.title ?? "nil"), expected \(first)") }
            if let d = e.dueDays { check(a.due.map { cal.isDate($0, inSameDayAs: Self.day(d)) } ?? false, "playbook due \(String(describing: a.due)), expected +\(d) days")
            } else { check(a.due == nil, "playbook has an invented due date") }
            if Set(a.steps.map { TaskValidator.key($0.title) }).count != a.steps.count { result.duplicateObjects += 1 }
        }
        result.fieldChecks = (passed, total)

        result.typeCorrect = result.tasks.count == c.saved.tasks.count && result.routines.count == c.saved.routines.count
            && result.playbooks.count == c.saved.playbooks.count

        if let pending = c.finalDraft {
            let a = draftTitles.map(TaskValidator.key), b = pending.map(TaskValidator.key)
            if a != b { result.failures.append("still pending: \(draftTitles), expected \(pending)") }
            if !result.tasks.isEmpty || !result.routines.isEmpty { result.failures.append("saved something that was never confirmed") }
        }
        // Conversation quality (H): a fixed set of rules for every response.
        for issue in result.qualityIssues { result.failures.append("quality: \(issue)") }
        if result.questions.count > ClarificationStateManager.maxRounds { result.failures.append("more than three questions") }
        let normalized = result.questions.map { VoiceTurnManager.norm($0) }
        if Set(normalized).count != normalized.count { result.failures.append("a question was repeated") }
    }
}

// MARK: - The 13 metrics

struct EvalMetrics {
    var waitAccuracy = 1.0, clarifyPrecision = 1.0, clarifyRecall = 1.0, extractionAccuracy = 1.0, typeAccuracy = 1.0
    var bulkSplitAccuracy = 1.0, duplicateRate = 0.0, inventedFieldRate = 0.0, confirmationLoopRate = 0.0
    var clarificationLoopRate = 0.0, saveSuccessRate = 1.0, completionRate = 1.0, responseQuality = 1.0
    // Long and noisy turns (category K only)
    var taskRecall = 1.0, taskPrecision = 1.0, chatterAsTaskRate = 0.0, contextCarryAccuracy = 1.0

    @MainActor
    static func compute(_ results: [CaseResult]) -> EvalMetrics {
        func ratio(_ a: Int, _ b: Int, empty: Double = 1) -> Double { b == 0 ? empty : Double(a) / Double(b) }
        var m = EvalMetrics()

        // 1. Wait accuracy: turns that should be held, and were.
        var waitTotal = 0, waitOK = 0
        // 2-3. Clarify precision and recall.
        var asked = 0, askedExpected = 0, expectedAsks = 0
        for r in results {
            for (i, t) in r.evalCase.turns.enumerated() where i < r.turns.count {
                let rec = r.turns[i]
                if t.expect.outcome == .held { waitTotal += 1; if rec.outcome == .held && !rec.modelCalled { waitOK += 1 } }
                if rec.outcome == .ask { asked += 1; if t.expect.outcome == .ask { askedExpected += 1 } }
                if t.expect.outcome == .ask { expectedAsks += 1 }
            }
        }
        m.waitAccuracy = ratio(waitOK, waitTotal)
        m.clarifyPrecision = ratio(askedExpected, asked)
        m.clarifyRecall = ratio(askedExpected, expectedAsks)

        // 4. Extraction accuracy over every field checked.
        m.extractionAccuracy = ratio(results.map(\.fieldChecks.passed).reduce(0, +), results.map(\.fieldChecks.total).reduce(0, +))

        // 5. Task, routine or playbook: every case that saves something.
        let savers = results.filter { !$0.evalCase.saved.isEmpty }
        m.typeAccuracy = ratio(savers.filter(\.typeCorrect).count, savers.count)

        // 6. Bulk split: the number of drafts in every bulk case.
        let bulk = results.filter { $0.evalCase.tags.contains(.bulk) }
        m.bulkSplitAccuracy = ratio(bulk.filter(\.typeCorrect).count, bulk.count)

        // 7-8. Duplicates and invented fields, per saved object.
        let objects = results.map(\.savedObjects).reduce(0, +)
        m.duplicateRate = ratio(results.map(\.duplicateObjects).reduce(0, +), objects, empty: 0)
        m.inventedFieldRate = ratio(results.map(\.inventedObjects).reduce(0, +), objects, empty: 0)

        // 9. Confirmation loops: something asked or previewed again right after a "yes".
        var loops = 0, withYes = 0
        for r in results {
            var yesSeen = false, loop = false
            for (i, t) in r.evalCase.turns.enumerated() where i < r.turns.count {
                if yesSeen, r.turns[i].outcome == .ask || r.turns[i].outcome == .preview { loop = true }
                if ConfirmationManager.interpret(t.say) == .yes, r.turns[i].outcome == .saved || r.turns[i].outcome == .reply { yesSeen = true }
                if r.turns[i].outcome == .saved, ConfirmationManager.interpret(t.say) != .yes { yesSeen = false }
            }
            if r.executions.contains(where: { $0 > 1 }) { loop = true }
            if r.evalCase.turns.contains(where: { ConfirmationManager.interpret($0.say) == .yes }) { withYes += 1 }
            if loop { loops += 1 }
        }
        m.confirmationLoopRate = ratio(loops, withYes, empty: 0)

        // 10. Clarification loops: more than three questions, or one asked twice.
        let loopy = results.filter { r in
            let n = r.questions.map { VoiceTurnManager.norm($0) }
            return r.questions.count > ClarificationStateManager.maxRounds || Set(n).count != n.count
        }
        m.clarificationLoopRate = ratio(loopy.count, results.count, empty: 0)

        // 11. Save success: every valid draft that was confirmed ran exactly once and produced exactly the expected objects.
        m.saveSuccessRate = ratio(savers.filter { r in
            r.executions.allSatisfy { $0 == 1 } && r.typeCorrect && r.duplicateObjects == 0
        }.count, savers.count)

        // 12. Completion: the conversation ended with the intended objects saved and no failures.
        m.completionRate = ratio(results.filter(\.passed).count, results.count)

        // 13. Response quality: the mean of the per-response score out of five.
        let grades = results.flatMap(\.quality)
        m.responseQuality = ratio(grades.map(\.score).reduce(0, +), grades.count * 5)

        // K. Long and noisy: recall and precision of the tasks, chatter that became a task, and the context carried to the right tasks.
        let k = results.filter { $0.evalCase.category == "K" }
        m.taskRecall = ratio(k.map(\.kFound).reduce(0, +), k.map(\.kExpected).reduce(0, +))
        m.taskPrecision = ratio(k.map(\.kMatched).reduce(0, +), k.map(\.kSaved).reduce(0, +))
        m.chatterAsTaskRate = ratio(k.map(\.kChatter).reduce(0, +), k.map(\.kSaved).reduce(0, +), empty: 0)
        m.contextCarryAccuracy = ratio(k.map(\.carryPassed).reduce(0, +), k.map(\.carryTotal).reduce(0, +))
        return m
    }

    var lines: [String] {
        func pct(_ x: Double) -> String { String(format: "%.1f%%", x * 100) }
        return ["1. Wait accuracy              \(pct(waitAccuracy))",
                "2. Clarify precision          \(pct(clarifyPrecision))",
                "3. Clarify recall             \(pct(clarifyRecall))",
                "4. Task extraction accuracy   \(pct(extractionAccuracy))",
                "5. Task-type accuracy         \(pct(typeAccuracy))",
                "6. Bulk-split accuracy        \(pct(bulkSplitAccuracy))",
                "7. Duplicate rate             \(pct(duplicateRate))",
                "8. Invented-field rate        \(pct(inventedFieldRate))",
                "9. Confirmation-loop rate     \(pct(confirmationLoopRate))",
                "10. Clarification-loop rate   \(pct(clarificationLoopRate))",
                "11. Save success rate         \(pct(saveSuccessRate))",
                "12. Completion rate           \(pct(completionRate))",
                "13. Response quality (judge)  \(pct(responseQuality))",
                "K1. Task recall (long turns)        \(pct(taskRecall))",
                "K2. Task precision (long turns)     \(pct(taskPrecision))",
                "K3. Chatter-as-task rate            \(pct(chatterAsTaskRate))",
                "K4. Context-carry accuracy          \(pct(contextCarryAccuracy))"]
    }
}

// MARK: - The report

enum EvalReport {
    @MainActor
    static func json(_ results: [CaseResult], metrics: EvalMetrics) -> [String: Any] {
        func turnJSON(_ t: TurnRecord) -> [String: Any] {
            var d: [String: Any] = ["utterance": t.utterance, "silence": t.silence, "gate": t.gate, "route": t.route,
                                    "outcome": t.outcome.rawValue, "state": t.phase.rawValue,
                                    "transitions": t.transitions.map(\.rawValue), "modelCalled": t.modelCalled,
                                    "pending": t.draft, "failures": t.failures]
            if let p = t.prompt { d["modelInput"] = p }
            if let o = t.modelOutput { d["modelOutput"] = o }
            if let v = t.validation { d["validation"] = v }
            if let s = t.spoken { d["spoken"] = s }
            return d
        }
        func caseJSON(_ r: CaseResult) -> [String: Any] {
            ["id": r.evalCase.id, "category": r.evalCase.category, "name": r.evalCase.name, "passed": r.passed,
             "failures": r.failures, "turns": r.turns.map(turnJSON),
             "saved": ["tasks": r.tasks.map(\.title), "routines": r.routines.map { "\($0.title) (\($0.recurrence?.scheduleText ?? ""))" },
                       "playbooks": r.playbooks.map { "\($0.name): \($0.steps.map(\.title))" }]]
        }
        return ["metrics": metrics.lines, "cases": results.map(caseJSON),
                "passed": results.filter(\.passed).count, "total": results.count]
    }

    @MainActor
    static func write(_ results: [CaseResult], metrics: EvalMetrics) -> String {
        let path = ProcessInfo.processInfo.environment["KITTY_EVAL_REPORT"] ?? "/tmp/kitty-eval-report.json"
        if let data = try? JSONSerialization.data(withJSONObject: json(results, metrics: metrics), options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
        return path
    }
}


// MARK: - The catalogue (EVALS.md)

/// Writes EVALS.md from the cases themselves, so the document can't drift from what the tests check.
enum EvalCatalogue {
    static let titles: [(String, String)] = [
        ("A", "Turn completeness"), ("B", "Task validation"), ("C", "Routines"), ("D", "Playbooks"), ("E", "Bulk creation"),
        ("F", "Clarification loops"), ("G", "Metadata extraction"), ("I", "Regression cases (from production failures) and extras"),
        ("J", "Messy speech (fillers, repeats, taking words back, run-ons)"),
        ("K", "Long and noisy (stories, asides, several asks, one shared day)")
    ]

    private static func scriptText(_ s: Script) -> String {
        switch s {
        case .none: return "no model call"
        case .single(let d):
            if d.action == "clarify" { return "model: `clarify` “\(d.clarifyingQuestion)”" }
            return "model: `\(d.action)`" + (d.title.isEmpty ? "" : " “\(d.title)”")
        case .bulk(let b):
            let n = b.tasks.count + b.routines.count + (b.playbook?.steps.count ?? 0)
            return "bulk `\(b.action)` (\(n) \(b.playbook != nil ? "steps" : "items"))"
        case .sequence(let all):
            return "\(all.count) model calls: " + all.map(scriptText).joined(separator: " then ")
        }
    }

    private static func outcomeText(_ e: TurnExpect) -> String {
        var parts: [String]
        switch e.outcome {
        case .held: parts = ["wait: held locally, no model call"]
        case .modelWait: parts = ["wait: the model said wait"]
        case .ask: parts = ["asks one question"]
        case .preview: parts = ["preview" + (e.draft.map { ": " + $0.joined(separator: " / ") } ?? "")]
        case .saved: parts = ["saved"]
        case .reply: parts = ["replies"]
        case .silent: parts = ["nothing"]
        }
        if !e.says.isEmpty { parts.append("says “\(e.says.joined(separator: " … "))”") }
        if let w = e.sees { parts.append("worked from “\(w)”") }
        if let p = e.phase { parts.append("state `\(p.rawValue)`") }
        if e.model == true { parts.append("model called") }
        if e.model == false { parts.append("model not called") }
        return parts.joined(separator: "; ")
    }

    private static func taskText(_ t: TaskExpect) -> String {
        var extras: [String] = []
        if let c = t.category { extras.append(c) }
        if t.noCategory { extras.append("no category") }
        if let d = t.dueDays { extras.append("due +\(d)d") }
        if let p = t.priority { extras.append("\(p) priority") }
        if let a = t.assignee { extras.append("for \(a)") }
        if let s = t.schedule { extras.append(s) }
        return "“\(t.title)”" + (extras.isEmpty ? "" : " (\(extras.joined(separator: ", ")))")
    }

    private static func savedText(_ c: EvalCase) -> String {
        var parts: [String] = []
        if !c.saved.tasks.isEmpty {
            parts.append("\(c.saved.tasks.count) task\(c.saved.tasks.count == 1 ? "" : "s"): " + c.saved.tasks.map(taskText).joined(separator: ", "))
        }
        if !c.saved.routines.isEmpty {
            parts.append("\(c.saved.routines.count) routine\(c.saved.routines.count == 1 ? "" : "s"): " + c.saved.routines.map(taskText).joined(separator: ", "))
        }
        for p in c.saved.playbooks { parts.append("playbook “\(p.name)”, \(p.steps) steps") }
        var text = parts.isEmpty ? "nothing saved" : parts.joined(separator: "; ")
        if let d = c.finalDraft { text += "; still pending: " + d.joined(separator: " / ") }
        return text
    }

    private static func behaviour(_ t: EvalTurn) -> String {
        if t.expect.outcome == .held { return "no model call → " + outcomeText(t.expect) }
        return scriptText(t.script) + " → " + outcomeText(t.expect)
    }

    private static func said(_ t: EvalTurn) -> String {
        "“\(t.say)”" + (t.silence >= 10 ? " *(then a long silence)*" : "")
    }

    static func markdown() -> String {
        let all = EvalSuite.all
        var out = "# Kitty eval cases\n\n"
        out += "Generated from `Tests/KittyEvals.swift` (`testWriteEvalCatalogue`). \(all.count) cases. Each case is a recorded utterance sequence replayed against a scripted model. “Today” is Wednesday 21 October 2026; “+1d” means tomorrow.\n\n"
        out += "The 12 to start with: " + EvalSuite.minimal12.map { "#\($0)" }.joined(separator: ", ") + ".\n\n"
        for (letter, title) in titles {
            let cases = all.filter { $0.category == letter }
            guard !cases.isEmpty else { continue }
            out += "## \(letter). \(title)\n\n| # | Case | Input (each turn) | Expected behaviour (each turn) | Expected saved objects |\n|---|---|---|---|---|\n"
            for c in cases {
                let input = c.turns.count == 1 ? said(c.turns[0])
                    : c.turns.enumerated().map { "\($0.offset + 1). \(said($0.element))" }.joined(separator: "<br>")
                let expected = c.turns.count == 1 ? behaviour(c.turns[0])
                    : c.turns.enumerated().map { "\($0.offset + 1). \(behaviour($0.element))" }.joined(separator: "<br>")
                out += "| \(c.id) | \(c.name) | \(input) | \(expected) | \(savedText(c)) |\n"
            }
            out += "\n"
        }
        out += """
        ## H. Conversation quality (graded on every case)

        Every response Kitty speaks in every case above is graded by `Judge`, and the case fails on any issue:

        - one short sentence or two: no more than 32 words
        - at most one question per response
        - no robotic wording ("Are you done?", "Shall I go ahead and create…", "Please provide…", "required field")
        - no repeated question, and no more than three questions in a conversation
        - a finished sentence
        - plus, from the case checks: wait versus clarify is correct, interruption keeps the pending state,
          bulk saves get one grouped confirmation, no invented metadata, no duplicate objects

        ## Metrics reported after every run

        1. Wait accuracy  2. Clarify precision  3. Clarify recall  4. Task extraction accuracy  5. Task-type accuracy
        6. Bulk-split accuracy  7. Duplicate rate  8. Invented-field rate  9. Confirmation-loop rate
        10. Clarification-loop rate  11. Save success rate  12. Completion rate  13. Response quality (judge)

        For the long and noisy cases (K), four more, with the thresholds the test asserts:

        K1. Task recall (long turns) at least 90%: of the tasks the speaker asked for, how many were made.
        K2. Task precision (long turns) at least 90%: of the tasks made, how many were asked for.
        K3. Chatter-as-task rate at most 5%: tasks whose title is the story, not an ask.
        K4. Context-carry accuracy at least 90%: a shared day or person lands on the right tasks (and only those), and a day that
        was not said is asked about, never written in.

        The K cases use a scripted model, so these measure the rules around the model. `RealModelKTests` (opt in with
        KITTY_REAL_MODEL=1) is the check against the real model; see REAL_MODEL_RUNS.md.

        """
        return out
    }
}

// MARK: - The tests

@MainActor
final class KittyEvals: XCTestCase {

    private func run(_ cases: [EvalCase]) async -> [CaseResult] {
        var results: [CaseResult] = []
        for c in cases { results.append(await EvalRunner.run(c)) }
        return results
    }

    private func report(_ results: [CaseResult], title: String) -> String {
        let metrics = EvalMetrics.compute(results)
        let path = EvalReport.write(results, metrics: metrics)
        var out = "\n=== \(title): \(results.filter(\.passed).count)/\(results.count) cases passed ===\n"
        out += metrics.lines.joined(separator: "\n") + "\n"
        for r in results where !r.passed {
            out += "\nFAIL #\(r.evalCase.id) [\(r.evalCase.category)] \(r.evalCase.name)\n"
            for f in r.failures { out += "   - \(f)\n" }
        }
        out += "\nreport: \(path)\n"
        return out
    }

    func testTheSuiteHasSixtyNumberedCasesAndTheRegressionSet() {
        let numbered = EvalSuite.all.filter { $0.id <= 60 }
        XCTAssertEqual(numbered.count, 60)
        XCTAssertEqual(Set(EvalSuite.all.map(\.id)).count, EvalSuite.all.count, "ids must be unique")
        XCTAssertEqual(Set(numbered.map(\.category)), ["A", "B", "C", "D", "E", "F", "G"])
        XCTAssertGreaterThanOrEqual(EvalSuite.all.filter { $0.category == "I" }.count, 12)
        XCTAssertEqual(EvalSuite.all.filter { $0.category == "J" }.map(\.id), Array(76...107))
        XCTAssertEqual(EvalSuite.all.filter { $0.category == "K" }.map(\.id), Array(108...137))
        XCTAssertGreaterThanOrEqual(EvalSuite.all.filter { $0.category == "K" }.count, 25)
        XCTAssertEqual(EvalSuite.minimal12.count, 12)
    }

    /// Regenerate EVALS.md with KITTY_EVAL_CATALOGUE=$PWD/EVALS.md and -only-testing:KittyTests/KittyEvals/testWriteEvalCatalogue
    func testWriteEvalCatalogue() throws {
        let text = EvalCatalogue.markdown()
        XCTAssertTrue(text.contains("## J. Messy speech"))
        if let path = ProcessInfo.processInfo.environment["KITTY_EVAL_CATALOGUE"] {
            try text.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    func testMinimalTwelve() async {
        let cases = EvalSuite.all.filter { EvalSuite.minimal12.contains($0.id) }
        let results = await run(cases)
        let text = report(results, title: "Minimal 12")
        print(text)
        XCTAssertTrue(results.allSatisfy(\.passed), text)
    }

    func testFullSuiteAndMetrics() async {
        let results = await run(EvalSuite.all)
        let text = report(results, title: "Full suite")
        print(text)
        XCTAssertTrue(results.allSatisfy(\.passed), text)

        let m = EvalMetrics.compute(results)
        XCTAssertEqual(m.waitAccuracy, 1, "incomplete utterances must be held")
        XCTAssertEqual(m.duplicateRate, 0)
        XCTAssertEqual(m.inventedFieldRate, 0)
        XCTAssertEqual(m.confirmationLoopRate, 0)
        XCTAssertEqual(m.clarificationLoopRate, 0)
        XCTAssertEqual(m.saveSuccessRate, 1)
        XCTAssertEqual(m.completionRate, 1)
        XCTAssertGreaterThanOrEqual(m.responseQuality, 0.95)
        XCTAssertGreaterThanOrEqual(m.extractionAccuracy, 0.98)
        // Long and noisy turns, with the scripted model: what is asked for is made, the chatter is not, the context lands right.
        XCTAssertGreaterThanOrEqual(m.taskRecall, 0.90, "K recall")
        XCTAssertGreaterThanOrEqual(m.taskPrecision, 0.90, "K precision")
        XCTAssertLessThanOrEqual(m.chatterAsTaskRate, 0.05, "K chatter-as-task")
        XCTAssertGreaterThanOrEqual(m.contextCarryAccuracy, 0.90, "K context carry")
    }

    // MARK: Components

    func testYesExecutesExactlyOnce() async {
        let manager = ConfirmationManager()
        let id = UUID()
        manager.arm(id)
        XCTAssertTrue(manager.consume(id))
        XCTAssertFalse(manager.consume(id), "a second yes, a tap or the countdown must not run it again")
        XCTAssertFalse(manager.consume(UUID()))
    }

    func testConfirmationVocabulary() {
        XCTAssertEqual(ConfirmationManager.interpret("Yes, save them"), .yes)
        XCTAssertEqual(ConfirmationManager.interpret("yeah go ahead"), .yes)
        XCTAssertEqual(ConfirmationManager.interpret("No"), .no)               // a bare no asks what to change; it is not a discard
        XCTAssertEqual(ConfirmationManager.interpret("No, remove the trash task"), .other)
        XCTAssertEqual(ConfirmationManager.interpret("cancel"), .cancel)
        XCTAssertEqual(ConfirmationManager.interpret("yes but make it tomorrow"), .other)
    }

    func testClarificationNeverRepeatsAndStopsAfterThreeRounds() {
        let c = ClarificationStateManager()
        XCTAssertEqual(c.register(question: "What is it for?", field: .object), .ask("What is it for?"))
        // the same question again becomes the fallback for that slot
        XCTAssertEqual(c.register(question: "What is it for?", field: .action), .ask(ClarificationStateManager.fallbackQuestion(for: .action)))
        XCTAssertEqual(c.register(question: "Which one?", field: .target), .ask("Which one?"))
        XCTAssertEqual(c.register(question: "Anything else?", field: .action), .exhausted)
        XCTAssertEqual(c.rounds, 3)
    }

    func testOptionalMetadataIsNeverAsked() {
        for q in ["When should this be due?", "Who should do it?", "What priority is it?", "Which category?", "Any notes?"] {
            XCTAssertTrue(ClarificationStateManager.asksForOptionalMetadata(q), q)
        }
        for q in ["What should be cleaned?", "How often should it repeat?", "Should this be a one-time task or a routine?"] {
            XCTAssertFalse(ClarificationStateManager.asksForOptionalMetadata(q), q)
        }
    }

    func testBulkDetectionDoesNotSplitEveryAnd() {
        XCTAssertFalse(BulkDetector.analyze("Buy milk and bread").isBulk)
        XCTAssertFalse(BulkDetector.analyze("Buy groceries and cleaning supplies").isBulk)
        XCTAssertFalse(BulkDetector.analyze("Wash and fold the laundry").isBulk)
        XCTAssertEqual(BulkDetector.analyze("Clean the bathroom and buy milk").segments.count, 2)
        XCTAssertEqual(BulkDetector.analyze("Clean the bathroom, buy milk, and water the plants").segments.count, 3)
        XCTAssertEqual(BulkDetector.analyze("Add these tasks: dishes, laundry, trash").segments.count, 3)
        XCTAssertEqual(BulkDetector.analyze("Daily househelp tasks: make beds, wash dishes, wipe counters").kind, .routines)
        XCTAssertEqual(BulkDetector.analyze("Create a playbook to cook biryani").kind, .playbook)
    }

    func testJudgeCatchesRoboticAndRepeatedLines() {
        XCTAssertFalse(Judge.grade("Are you done? Shall I go ahead and create something on those lines in a meaningful way?", earlier: []).issues.isEmpty)
        XCTAssertFalse(Judge.grade("What is it for?", earlier: ["What is it for?"]).issues.isEmpty)
        XCTAssertFalse(Judge.grade("What? And when?", earlier: []).issues.isEmpty)
        XCTAssertTrue(Judge.grade("I have 3 tasks: a, b, and c. Should I save these?", earlier: []).issues.isEmpty)
    }
}

// MARK: - The long and noisy cases against Apple's real on-device model (opt in)

/// Skipped unless KITTY_REAL_MODEL=1. Runs the first turn of every K case through the real model, several times, with the rule
/// fallback off, and writes what came back to /tmp/kitty-real-model-k.md. Nothing is scripted and nothing is judged pass or fail:
/// the model varies from run to run, so this reports how often it does what the case wants, and how many model calls it took.
///
///     TEST_RUNNER_KITTY_REAL_MODEL=1 xcodebuild test -project Kitty.xcodeproj -scheme Kitty \
///         -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:KittyTests/RealModelKTests
@MainActor
final class RealModelKTests: XCTestCase {
    private func words(_ s: String) -> Set<String> {
        Set(s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { !["the", "a", "an", "to", "my", "of"].contains($0) })
    }

    /// Two titles are the same task when most of their words agree ("Clean the bathrooms" and "Clean bathrooms").
    private func same(_ a: String, _ b: String) -> Bool {
        let x = words(a), y = words(b)
        guard !x.isEmpty, !y.isEmpty else { return false }
        return Double(x.intersection(y).count) / Double(x.union(y).count) >= 0.6
    }

    func testLongTurnsAgainstTheOnDeviceModel() async throws {
        guard ProcessInfo.processInfo.environment["KITTY_REAL_MODEL"] == "1" else {
            throw XCTSkip("Set KITTY_REAL_MODEL=1 (as TEST_RUNNER_KITTY_REAL_MODEL=1 for xcodebuild) to run the real on-device model.")
        }
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) else { throw XCTSkip("Needs the on-device model (iOS 26).") }
        // No model, no result: an unavailable model must never be reported as "the model found nothing".
        guard case .available = SystemLanguageModel.default.availability else {
            let why = "\(SystemLanguageModel.default.availability)"
            try? "# Real on-device model, long and noisy cases (K)\n\nNot run: the on-device model is unavailable here (\(why)).\n"
                .write(toFile: "/tmp/kitty-real-model-k.md", atomically: true, encoding: .utf8)
            throw XCTSkip("The on-device model is unavailable: \(why)")
        }
        let runs = Int(ProcessInfo.processInfo.environment["KITTY_REAL_RUNS"] ?? "") ?? 5
        var summary = ["| # | case | runs | tasks found | extra / chatter | model calls (avg) | asked about a day | outcome |",
                       "|---|------|------|-------------|-----------------|-------------------|-------------------|---------|"]
        var raw = ""
        var totalExpected = 0, totalFound = 0, totalMade = 0, totalChatter = 0

        for c in EvalSuite.k {
            guard let first = c.turns.first else { continue }
            let expected: [String] = first.expect.draft ?? (c.saved.tasks + c.saved.routines).map(\.title)
            guard !expected.isEmpty else { continue }                                   // a case about a question or a wait: nothing to compare
            guard case .evaluate(let text) = VoiceTurnManager.gate(utterance: first.say, silence: max(first.silence, VoiceTurnManager.extendedCap + 0.1), lastActed: "") else { continue }

            var found = 0, extras = 0, chatter = 0, calls = 0, dayQuestions = 0
            var outcomes: [String: Int] = [:]
            raw += "\n#\(c.id) \(c.name)\n  said: \(first.say)\n  want: \(expected)\n"
            for run in 1...runs {
                let sink = InMemorySaveSink()
                let manager = VoiceTurnManager(engine: DecisionEngine(), sink: sink, knownCategories: { EvalRunner.knownCategories })
                manager.ruleFallbackEnabled = false
                manager.state.setListening(true)
                let result = await manager.decide(utterance: text, now: EvalRunner.now)
                calls += manager.modelCalls
                var titles: [String] = []
                var kind = ""
                switch result {
                case .proposal(let p):
                    kind = "preview"
                    titles = manager.state.drafts.hasContent ? manager.state.drafts.items.map(\.title) : p.rows.map(\.title)
                    if manager.state.pendingContextDue != nil { dayQuestions += 1 }
                case .question: kind = "question"
                case .reply: kind = "reply"
                case .wait: kind = "wait"
                }
                outcomes[kind, default: 0] += 1
                let hit = expected.filter { e in titles.contains { same($0, e) } }.count
                found += hit
                extras += titles.filter { t in !expected.contains { same(t, $0) } }.count
                chatter += titles.filter { t in c.chatter.contains { t.lowercased().contains($0) } }.count
                totalMade += titles.count
                raw += "  run \(run): \(kind), calls \(manager.modelCalls), route \(manager.lastTrace.route), \(titles)\n"
            }
            totalExpected += expected.count * runs
            totalFound += found
            totalChatter += chatter
            let outcome = outcomes.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
            summary.append("| \(c.id) | \(c.name) | \(runs) | \(found)/\(expected.count * runs) | \(extras) / \(chatter) | "
                           + String(format: "%.1f", Double(calls) / Double(runs)) + " | \(dayQuestions)/\(runs) | \(outcome) |")
        }

        let recall = totalExpected == 0 ? 0 : Double(totalFound) / Double(totalExpected)
        var out = "# Real on-device model, long and noisy cases (K)\n\n"
        out += "Run on \(ProcessInfo.processInfo.operatingSystemVersionString), Apple's on-device model, \(runs) runs per case, rule fallback off, the first turn of each case only.\n\n"
        out += String(format: "Task recall %.1f%% (%d of %d), %d tasks made in all, %d with chatter in the title.\n\n", recall * 100, totalFound, totalExpected, totalMade, totalChatter)
        out += summary.joined(separator: "\n") + "\n\n## Raw\n\n```\n" + raw + "```\n"
        try? out.write(toFile: "/tmp/kitty-real-model-k.md", atomically: true, encoding: .utf8)
        print(out)
        #else
        throw XCTSkip("FoundationModels is not available.")
        #endif
    }
}
