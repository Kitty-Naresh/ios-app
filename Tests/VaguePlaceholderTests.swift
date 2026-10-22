import XCTest
@testable import Kitty

/// "Add a task for the project" names no task. Kitty must ask what the task is, never create a task titled "Project".
/// Root cause: a title like "Project task" passed TaskValidator.isActionable (two words, the first not a determiner, so it
/// was taken for "an unfamiliar verb"), and with no model the rule planner took the words after "for" as the title.
@MainActor
final class VaguePlaceholderTests: XCTestCase {
    private func decision(_ action: String, title: String = "", question: String = "") -> AgentDecisionValue {
        AgentDecisionValue(wait: false, action: action, title: title, category: "", dueDate: "", dueTime: "", priority: "",
                           assignee: "", frequency: "", notes: "", playbookName: "", playbookSteps: [], clarifyingQuestion: question,
                           spokenResponse: "", moreTasks: [])
    }

    private func manager(_ answers: [AgentDecisionValue?], fallback: Bool = true) -> (VoiceTurnManager, ScriptedEngine) {
        let engine = ScriptedEngine(answers)
        let m = VoiceTurnManager(engine: engine, sink: InMemorySaveSink(), knownCategories: { [] }, knownAssignees: { [] })
        m.ruleFallbackEnabled = fallback
        m.state.setListening(true)
        return (m, engine)
    }

    private let vague = ["add a task for the project", "add a task for the project work", "add a task about the project",
                         "add a task for it", "create a task for that thing", "add a task for something",
                         "add a task for the house", "add a task for the kitchen", "Add a task for project", "add a task for the stuff"]

    private let legitimate: [(said: String, title: String)] = [
        ("add a task for the project: review budget", "Review budget"),
        ("add a task to call the project manager", "Call the project manager"),
        ("add a task for Sunday to clean the garage", "Clean the garage"),
        ("add task for kitchen to mop floor", "Mop floor"),
        ("add a task to clean the kitchen", "Clean the kitchen"),
        ("add a task for the project to book the venue", "Book the venue"),
    ]

    private func assertAsks(_ r: TurnResult, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        guard case .question(let q) = r else { return XCTFail("\(what): expected a question, got \(VoiceTurnManager.describe(r))", file: file, line: line) }
        XCTAssertTrue(q.hasSuffix("?"), "\(what): \(q)", file: file, line: line)
    }

    // MARK: The recogniser

    func testPlaceholderRequestsAreRecognisedAndSpecificOnesAreNot() {
        for said in vague { XCTAssertNotNil(VaguePlaceholder.question(forRequest: said), said) }
        for (said, _) in legitimate { XCTAssertNil(VaguePlaceholder.question(forRequest: said), said) }
        // Lists, bare actions and complete sentences are other routes' business.
        for said in ["A list of tasks for the Garden project. Number one buy soil. Number two plant tomatoes.",
                     "I want to create a list of tasks for the Kitty project", "Add a task to clean", "Add a task", "Buy milk",
                     "add a task for laundry", "add a task for the Kitty project to ship the beta"] {
            XCTAssertNil(VaguePlaceholder.question(forRequest: said), said)
        }
    }

    func testTheQuestionIsSpecific() {
        XCTAssertEqual(VaguePlaceholder.question(forRequest: "add a task for the project"), "What would you like the task to be for the project?")
        XCTAssertEqual(VaguePlaceholder.question(forRequest: "add a task for the kitchen"), "What would you like the task to be for the kitchen?")
        XCTAssertEqual(VaguePlaceholder.question(forRequest: "add a task for it"), "What would you like the task to be?")
    }

    func testPlaceholderTitlesAreNotTasks() {
        for title in ["Project", "The project", "Project task", "Project work", "It", "That thing", "Something", "Task"] {
            XCTAssertTrue(VaguePlaceholder.isVague(title: title), title)
            XCTAssertFalse(TaskValidator.isActionable(title), title)
        }
        for title in ["Review budget", "Call the project manager", "Project plan", "Clean the garage", "The bathroom", "Laundry", "Do the thing"] {
            XCTAssertFalse(VaguePlaceholder.isVague(title: title), title)
        }
    }

    // MARK: The model path

    func testAModelPlaceholderTitleAsksInsteadOfCreating() async {
        for title in ["Project", "Project task", "The project", "Project work", "Task for the project"] {
            for said in vague {
                let (m, _) = manager([decision("create_task", title: title)])
                let r = await m.decide(utterance: said)
                assertAsks(r, "\(said) / model title \(title)")
                XCTAssertEqual(m.state.phase, .awaitingClarification)
            }
        }
    }

    func testTheModelsOwnQuestionIsKept() async {
        let (m, engine) = manager([decision("clarify", question: "What do you want to do for the project?")])
        let r = await m.decide(utterance: "add a task for the project")
        guard case .question(let q) = r else { return XCTFail("\(r)") }
        XCTAssertEqual(q, "What do you want to do for the project?")
        XCTAssertEqual(engine.prompts.count, 1)
    }

    func testWithNoModelTheRulesAskInsteadOfTakingTheNounAsTheTitle() async {
        for fallback in [true, false] {
            for said in vague {
                let (m, _) = manager([nil], fallback: fallback)
                let r = await m.decide(utterance: said)
                assertAsks(r, "\(said) / fallback \(fallback)")
                XCTAssertEqual(m.lastTrace.route, "vague-placeholder", said)
            }
        }
    }

    func testTheRulePlannerNeverTurnsAPlaceholderRequestIntoATask() async {
        for said in vague {
            let r = await TaskAgent.propose(said)
            assertAsks(r, "TaskAgent.propose: \(said)")
        }
    }

    func testAFinishedTurnWhereTheModelWaitsStillAsks() async {
        let wait = AgentDecisionValue(wait: true, action: "wait", title: "", category: "", dueDate: "", dueTime: "", priority: "",
                                      assignee: "", frequency: "", notes: "", playbookName: "", playbookSteps: [], clarifyingQuestion: "",
                                      spokenResponse: "", moreTasks: [])
        let (m, _) = manager([wait])
        assertAsks(await m.decide(utterance: "add a task for the project", final: true), "model waits after the user stopped")
    }

    // MARK: Legitimate requests still become tasks

    func testRequestsWithRealContentStillCreateTheRightTask() async {
        for (said, title) in legitimate {
            let (m, _) = manager([decision("create_task", title: title)])
            let r = await m.decide(utterance: said)
            guard case .proposal(let p) = r else { return XCTFail("\(said): expected a proposal, got \(VoiceTurnManager.describe(r))") }
            XCTAssertEqual(p.rows.map(\.title), [title], said)
        }
    }

    func testTheRuleFallbackStillHandlesRealRequests() async {
        for said in ["add a task to call the project manager", "add a task for the project: review budget", "add task for kitchen to mop floor"] {
            let (m, _) = manager([nil])
            let r = await m.decide(utterance: said)
            guard case .proposal(let p) = r else { return XCTFail("\(said): expected a proposal, got \(VoiceTurnManager.describe(r))") }
            XCTAssertFalse(p.rows.isEmpty, said)
            XCTAssertNotEqual(m.lastTrace.route, "vague-placeholder", said)
        }
    }

    func testBareActionsAndProjectListsAreUntouched() async {
        let (m, _) = manager([nil])
        guard case .question(let q) = await m.decide(utterance: "Add a task to clean") else { return XCTFail() }
        XCTAssertEqual(q, "What should I clean?")
        XCTAssertEqual(m.lastTrace.route, "bare-action")

        let (list, engine) = manager([nil])
        let r = await list.decide(utterance: "A list of tasks for the Garden project. Number one buy soil. Number two plant tomatoes. Number three water the plants.")
        guard case .proposal(let p) = r else { return XCTFail("expected a draft, got \(VoiceTurnManager.describe(r))") }
        XCTAssertEqual(p.rows.count, 3)
        XCTAssertEqual(engine.prompts.count, 0, "a spoken list is read in Swift")
    }

    // MARK: Question, answer, task

    func testTheAnswerBecomesTheRealTask() async {
        let (m, engine) = manager([decision("create_task", title: "Project task"), decision("create_task", title: "Review the budget")])
        let first = await m.decide(utterance: "add a task for the project")
        guard case .question(let q) = first else { return XCTFail("\(first)") }
        XCTAssertEqual(q, "What would you like the task to be for the project?")
        XCTAssertEqual(m.state.phase, .awaitingClarification)
        XCTAssertEqual(m.state.clarify.lastQuestion, q)

        let second = await m.decide(utterance: "review the budget")
        guard case .proposal(let p) = second else { return XCTFail("expected a proposal, got \(VoiceTurnManager.describe(second))") }
        XCTAssertEqual(p.rows.map(\.title), ["Review the budget"])
        XCTAssertEqual(m.state.pendingTitles, ["Review the budget"])
        XCTAssertTrue(engine.prompts.last?.contains("They answered: “review the budget”") ?? false, engine.prompts.last ?? "")
    }

    func testTheAnswerSpokenAsOneRunningTurnStillBecomesTheRealTask() async {
        let (m, _) = manager([decision("create_task", title: "Project task"), decision("create_task", title: "Review the budget")])
        _ = await m.decide(utterance: "add a task for the project")
        let second = await m.decide(utterance: "add a task for the project review the budget")
        guard case .proposal(let p) = second else { return XCTFail("expected a proposal, got \(VoiceTurnManager.describe(second))") }
        XCTAssertEqual(p.rows.map(\.title), ["Review the budget"])
    }

    func testTheAnswerWorksWithNoModelToo() async {
        let (m, _) = manager([nil, nil])
        assertAsks(await m.decide(utterance: "add a task for the project"), "first turn")
        let second = await m.decide(utterance: "add a task for the project review the budget")
        guard case .proposal(let p) = second else { return XCTFail("expected a proposal, got \(VoiceTurnManager.describe(second))") }
        XCTAssertEqual(p.rows.map(\.title), ["Review the budget"])
    }

    func testAskingNeverRepeatsForever() async {
        let (m, _) = manager([decision("create_task", title: "Project"), decision("create_task", title: "Project"),
                              decision("create_task", title: "Project"), decision("create_task", title: "Project")])
        var results: [TurnResult] = []
        for said in ["add a task for the project", "the project", "project", "the project again"] { results.append(await m.decide(utterance: said)) }
        for r in results {
            if case .proposal(let p) = r { XCTAssertFalse(p.rows.map(\.title).contains { VaguePlaceholder.isVague(title: $0) }, "\(p.rows.map(\.title))") }
        }
    }
}
