// Add this file to a UNIT TEST target only (File > New > Target > Unit Testing Bundle), never to the app target.
// If your app module is not called MyApp, change the import below to its name.
import XCTest
@testable import Kitty

/// A model that answers from a script, so tests can count calls and control the answers.
@MainActor
final class ScriptedEngine: DecisionProviding {
    var answers: [AgentDecisionValue?]
    private(set) var prompts: [String] = []
    init(_ answers: [AgentDecisionValue?]) { self.answers = answers }
    func decide(prompt: String) async -> AgentDecisionValue? {
        prompts.append(prompt)
        return answers.isEmpty ? nil : answers.removeFirst()
    }
}

@MainActor
final class KittyVoiceTurnTests: XCTestCase {

    // A fixed "now": Wednesday 21 October 2026, in UTC, so date answers never depend on the day the tests run.
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    private var now: Date { DateComponents(calendar: calendar, year: 2026, month: 10, day: 21, hour: 9).date! }
    private func ctx(known: [String] = ["Bathroom", "Groceries", "Plants"], pending: [String] = [], recent: [String] = []) -> ValidationContext {
        ValidationContext(knownCategories: known, pendingTitles: pending, recentTitles: recent, now: now, calendar: calendar)
    }
    private func decision(_ action: String, title: String = "", category: String = "", dueDate: String = "", priority: String = "",
                          assignee: String = "", frequency: String = "", more: [String] = [], steps: [String] = [],
                          name: String = "", question: String = "", wait: Bool = false) -> AgentDecisionValue {
        AgentDecisionValue(wait: wait, action: action, title: title, category: category, dueDate: dueDate, priority: priority,
                           assignee: assignee, frequency: frequency, playbookName: name, playbookSteps: steps,
                           clarifyingQuestion: question, moreTasks: more)
    }

    // MARK: Incomplete utterances

    func testIncompleteUtterancesDoNotReachTheModel() {
        let incomplete = ["Add a task to…", "Add a task to clean the…", "Um, I want to…", "The bathroom", "Buy…",
                          "Clean bathroom, buy milk, and…", "Add a task to clean the", "I need to", "actually make it", "wait",
                          "Clean the bathroom and", "Buy milk but"]
        for text in incomplete {
            guard case .incomplete = LocalSemanticPrechecker.check(text) else { return XCTFail("should wait: \(text)") }
        }
    }

    func testLikelyCompleteUtterancesMayBeSent() {
        let complete = ["Add a task to clean the bathroom", "Water the plants every morning", "Buy milk tomorrow",
                        "Clean bathroom, buy milk, and water plants", "Add a task for laundry.", "What tasks do I have today?",
                        "Actually, make it high priority", "Create a playbook to cook biryani", "yes", "done"]
        for text in complete {
            XCTAssertEqual(LocalSemanticPrechecker.check(text), .mayBeComplete, text)
        }
    }

    func testShortPauseNeverCallsTheModelAndLongPauseOnlyWhenComplete() {
        XCTAssertEqual(VoiceTurnManager.gate(utterance: "Add a task to clean the bathroom", silence: 0.8, lastActed: ""), .keepListening)
        if case .hold = VoiceTurnManager.gate(utterance: "Add a task to clean the", silence: 4.0, lastActed: "") {} else { XCTFail() }
        XCTAssertEqual(VoiceTurnManager.gate(utterance: "Add a task to clean the bathroom", silence: 4.0, lastActed: ""),
                       .evaluate("Add a task to clean the bathroom"))
        // the same words are not judged twice
        XCTAssertEqual(VoiceTurnManager.gate(utterance: "Add a task to clean the bathroom", silence: 3, lastActed: "Add a task to clean the bathroom"), .keepListening)
        // a long silence on unfinished speech asks whether the user is done
        XCTAssertEqual(VoiceTurnManager.gate(utterance: "Add a task to", silence: 11, lastActed: ""), .nudge)
    }

    // MARK: Ambiguous utterances

    func testAmbiguousRequestsAskOneQuestion() {
        let laundry = TaskValidator.validate(decision("create_task", title: "Laundry"), utterance: "Add a task for laundry.", context: ctx())
        XCTAssertEqual(laundry, .clarify("What would you like me to do with laundry?"))

        let asked = TaskValidator.validate(decision("clarify", question: "Wash, fold, or put it away? And when?"),
                                           utterance: "Add a task for laundry.", context: ctx())
        XCTAssertEqual(asked, .clarify("Wash, fold, or put it away?"))     // only the first question

        XCTAssertEqual(TaskValidator.validate(decision("complete_task"), utterance: "mark it done", context: ctx()), .clarify("Which task do you mean?"))
        XCTAssertEqual(TaskValidator.validate(decision("create_task", title: "The bathroom"), utterance: "The bathroom", context: ctx()),
                       .clarify("What would you like me to do with the bathroom?"))
    }

    func testWaitSavesNothing() {
        XCTAssertEqual(TaskValidator.validate(decision("create_task", title: "Clean bathroom", wait: true), utterance: "Add a task to", context: ctx()), .wait)
    }

    // MARK: One-time tasks

    func testOneTimeTask() {
        let v = TaskValidator.validate(decision("create_task", title: "clean bathroom", category: "Bathroom"),
                                       utterance: "Add a task to clean the bathroom.", context: ctx())
        guard case .tasks(let tasks) = v, tasks.count == 1 else { return XCTFail("\(v)") }
        XCTAssertEqual(tasks[0].title, "Clean bathroom")
        XCTAssertEqual(tasks[0].categoryName, "Bathroom")
        XCTAssertNil(tasks[0].due)
        XCTAssertNil(tasks[0].priority)
    }

    func testRelativeDatesAreResolvedInSwiftAndNothingIsInvented() {
        let tomorrow = TaskValidator.validate(decision("create_task", title: "Buy milk", category: "Groceries", dueDate: "2020-01-01"),
                                              utterance: "Buy milk tomorrow.", context: ctx())
        guard case .tasks(let t1) = tomorrow else { return XCTFail() }
        XCTAssertEqual(t1[0].due, calendar.date(from: DateComponents(year: 2026, month: 10, day: 22)))   // the model's date is ignored

        // the model invents a date, a priority and an assignee that the user never said
        let invented = TaskValidator.validate(decision("create_task", title: "Buy milk", dueDate: "2026-10-25", priority: "high", assignee: "Rani"),
                                              utterance: "Buy milk.", context: ctx())
        guard case .tasks(let t2) = invented else { return XCTFail() }
        XCTAssertNil(t2[0].due); XCTAssertNil(t2[0].priority); XCTAssertNil(t2[0].assignee)
    }

    func testCategoryRules() {
        XCTAssertEqual(TaskValidator.resolveCategory("bathroom", known: ["Bathroom"]), "Bathroom")     // reuse
        XCTAssertEqual(TaskValidator.resolveCategory("Balcony", known: ["Bathroom"]), "Balcony")       // new but specific
        XCTAssertNil(TaskValidator.resolveCategory("Other", known: []))                                // too generic
        XCTAssertNil(TaskValidator.resolveCategory("miscellaneous household chores for later", known: []))
    }

    // MARK: Routines

    func testRoutines() {
        let daily = TaskValidator.validate(decision("create_routine", title: "Water plants", category: "Plants", frequency: "daily"),
                                           utterance: "Water the plants every morning.", context: ctx())
        guard case .routine(let r1) = daily else { return XCTFail("\(daily)") }
        XCTAssertEqual(r1.recurrence, RecurrenceSpec())

        let weekly = TaskValidator.validate(decision("create_routine", title: "Clean bathroom", category: "Bathroom", assignee: "househelp", frequency: "weekly"),
                                            utterance: "Add a task to clean the bathroom every Monday for the househelp", context: ctx())
        guard case .routine(let r2) = weekly else { return XCTFail("\(weekly)") }
        XCTAssertEqual(r2.recurrence?.weekdays, [2])
        XCTAssertEqual(r2.assignee, "Househelp")

        XCTAssertEqual(TaskValidator.validate(decision("create_routine", title: "Clean bathroom", frequency: "weekly"),
                                              utterance: "Clean the bathroom every week", context: ctx()),
                       .clarify("Which day of the week should it repeat?"))
        XCTAssertEqual(TaskValidator.validate(decision("create_routine", title: "Clean bathroom", frequency: "once"),
                                              utterance: "Clean the bathroom", context: ctx()),
                       .clarify("How often should it repeat?"))
    }

    // MARK: Playbooks

    func testPlaybooks() {
        let steps = ["Buy ingredients", "Marinate chicken", "Cook rice", "Assemble and cook biryani"]
        let proposed = TaskValidator.validate(decision("create_playbook", steps: steps, name: "Cook biryani"),
                                              utterance: "Create a playbook to cook biryani.", context: ctx())
        XCTAssertEqual(proposed, .playbook(name: "Cook biryani", steps: steps, stated: false))      // suggested: needs a yes

        let stated = TaskValidator.validate(decision("create_playbook", steps: steps, name: "Cook biryani"),
                                            utterance: "Playbook for biryani: buy ingredients, marinate chicken, cook rice", context: ctx())
        XCTAssertEqual(stated, .playbook(name: "Cook biryani", steps: steps, stated: true))

        XCTAssertEqual(TaskValidator.validate(decision("create_playbook", name: "Cook biryani"), utterance: "Create a playbook to cook biryani", context: ctx()),
                       .clarify("What steps should it include?"))
    }

    // MARK: Several unrelated tasks

    func testMultipleUnrelatedTasksAreSeparate() {
        let v = TaskValidator.validate(decision("create_task", title: "Clean bathroom", category: "Bathroom",
                                                more: ["Buy milk | Groceries", "Water plants | Plants"]),
                                       utterance: "Clean the bathroom, buy milk, and water the plants.", context: ctx())
        guard case .tasks(let tasks) = v else { return XCTFail("\(v)") }
        XCTAssertEqual(tasks.map(\.title), ["Clean bathroom", "Buy milk", "Water plants"])
        XCTAssertEqual(tasks.map(\.categoryName), ["Bathroom", "Groceries", "Plants"])
    }

    // MARK: Corrections and duplicates

    func testCorrectionsChangeThePendingTaskInsteadOfAddingOne() {
        let v = TaskValidator.validate(decision("update_task", priority: "high"), utterance: "Actually, make it high priority.", context: ctx(pending: ["Clean bathroom"]))
        guard case .update(let target, let changes) = v else { return XCTFail("\(v)") }
        XCTAssertEqual(target, "")
        XCTAssertEqual(changes.priority, "high")

        XCTAssertEqual(TaskValidator.validate(decision("update_task"), utterance: "Actually, change it", context: ctx()), .clarify("What would you like to change?"))

        // the same task again with the pending one: replaces it, not a duplicate
        let again = TaskValidator.validate(decision("create_task", title: "Clean bathroom", priority: "high"),
                                           utterance: "Clean the bathroom, it's urgent", context: ctx(pending: ["Clean bathroom"]))
        guard case .tasks(let tasks) = again else { return XCTFail("\(again)") }
        XCTAssertEqual(tasks.count, 1)

        // one that was just saved is not added twice
        let dup = TaskValidator.validate(decision("create_task", title: "Clean bathroom"), utterance: "Clean the bathroom", context: ctx(recent: ["Clean bathroom"]))
        XCTAssertEqual(dup, .duplicate("Clean bathroom"))
    }

    // MARK: Confirmation phrases

    func testConfirmationPhrases() {
        for phrase in ["done", "save it", "go ahead", "thats all", "yes", "okay"] {
            XCTAssertTrue(VoiceConversation.isConfirmation(phrase), phrase)
        }
        XCTAssertEqual(VoiceTurnManager.splitFinalizer("every Monday for the househelp, done").isFinal, true)
        XCTAssertEqual(VoiceTurnManager.splitFinalizer("every Monday for the househelp, done").text, "every Monday for the househelp")
        XCTAssertEqual(VoiceTurnManager.splitFinalizer("Clean the bathroom, that's all.").text, "Clean the bathroom")
        XCTAssertEqual(VoiceTurnManager.splitFinalizer("save it").text, "")
        // "done" inside a command is not "I'm finished talking"
        XCTAssertFalse(VoiceTurnManager.splitFinalizer("mark dusting done").isFinal)
        XCTAssertFalse(VoiceTurnManager.splitFinalizer("the dishes are done").isFinal)
        XCTAssertEqual(VoiceTurnManager.gate(utterance: "Clean the bathroom every Monday done", silence: 0.6, lastActed: ""),
                       .forceEvaluate("Clean the bathroom every Monday"))
    }

    // MARK: Context-window safety

    func testPromptsStayShort() {
        let manyCategories = (1...100).map { "Category \($0)" }
        let long = String(repeating: "clean the bathroom and then ", count: 100)
        let prompt = PromptBuilder.build(utterance: long, pendingTask: String(repeating: "x", count: 500), pendingPlaybook: nil,
                                         knownCategories: manyCategories, now: now, calendar: calendar)
        XCTAssertLessThan(prompt.count, 1_800)
        XCTAssertTrue(prompt.contains("Category 12"))
        XCTAssertFalse(prompt.contains("Category 13"))
        XCTAssertTrue(prompt.contains("Current date: 2026-10-21"))
        XCTAssertLessThan(PersistentInstructions.text.count, 6_000)     // about 1,500 tokens, well inside the window
    }

    func testTheSessionIsReplacedBeforeItFillsUp() {
        if #available(iOS 26.0, *) {
            XCTAssertFalse(DecisionEngine.shouldRotate(turnsSoFar: 5))
            XCTAssertTrue(DecisionEngine.shouldRotate(turnsSoFar: DecisionEngine.maxTurnsPerSession))
        }
    }

    // MARK: The acceptance sequence

    func testAcceptanceSequence() async {
        let engine = ScriptedEngine([
            decision("", wait: true),                                                                   // "...clean the bathroom": may be incomplete
            decision("create_routine", title: "Clean bathroom", category: "Bathroom", assignee: "househelp", frequency: "weekly")
        ])
        let manager = VoiceTurnManager(engine: engine)

        // 1-4: "Add a task to…", pause, "clean the…", pause: the app keeps listening and never asks the model
        XCTAssertEqual(VoiceTurnManager.gate(utterance: "Add a task to…", silence: 4.0, lastActed: ""), .hold("trailing off"))
        if case .hold = VoiceTurnManager.gate(utterance: "Add a task to clean the…", silence: 4.0, lastActed: "") {} else { XCTFail() }
        XCTAssertEqual(engine.prompts.count, 0)

        // 5: "bathroom": the model may be asked once, and says wait
        let u5 = "Add a task to clean the bathroom"
        XCTAssertEqual(VoiceTurnManager.gate(utterance: u5, silence: VoiceTurnManager.longPause + 0.5, lastActed: ""), .evaluate(u5))
        let r5 = await manager.decide(utterance: u5)
        guard case .wait = r5 else { return XCTFail("expected wait") }
        XCTAssertEqual(engine.prompts.count, 1)

        // 7: "every Monday for the househelp": one more call, and it becomes a routine
        let u7 = "Add a task to clean the bathroom every Monday for the househelp"
        XCTAssertEqual(VoiceTurnManager.gate(utterance: u7, silence: VoiceTurnManager.longPause + 0.5, lastActed: u5), .evaluate(u7))
        let r7 = await manager.decide(utterance: u7)
        guard case .proposal(let proposal) = r7 else { return XCTFail("expected a proposal") }
        XCTAssertEqual(engine.prompts.count, 2)
        XCTAssertEqual(proposal.rows.first?.title, "Clean bathroom")
        let tags = proposal.rows.first?.tags.map(\.text) ?? []
        XCTAssertTrue(tags.contains("every Monday"), "\(tags)")
        XCTAssertTrue(tags.contains("Househelp"), "\(tags)")
        XCTAssertTrue(tags.contains("Bathroom"), "\(tags)")
        XCTAssertEqual(manager.state.pendingTitles, ["Clean bathroom"])

        // 8: "done" saves what is pending (no extra model call)
        let u8 = u7 + " done"
        XCTAssertEqual(VoiceTurnManager.gate(utterance: u8, silence: 0.6, lastActed: u7), .forceEvaluate(u7))
        XCTAssertTrue(VoiceConversation.isConfirmation("done"))
        XCTAssertEqual(engine.prompts.count, 2)
    }

    /// Regression: the real model returned wait=true together with a finished task ("Add a task to clean bathroom").
    func testWaitWithACompleteTaskIsNotDropped() {
        func decision(wait: Bool, title: String) -> AgentDecisionValue {
            AgentDecisionValue(wait: wait, action: "create_task", title: title, category: "", dueDate: "", dueTime: "", priority: "",
                               assignee: "", frequency: "", notes: "", playbookName: "", playbookSteps: [], clarifyingQuestion: "",
                               spokenResponse: "", moreTasks: [])
        }
        XCTAssertTrue(TaskValidator.waitIsContradicted(decision(wait: true, title: "Clean bathroom"), utterance: "add a taks to clean bathroom"))
        XCTAssertFalse(TaskValidator.waitIsContradicted(decision(wait: true, title: ""), utterance: "add a task to clean bathroom"))
        XCTAssertFalse(TaskValidator.waitIsContradicted(decision(wait: true, title: "Clean bathroom"), utterance: "add a task to clean the bathroom and"))
    }

    /// A lone "clean" is never silent: the gate holds it, then a long silence turns it into a question.
    func testALoneVerbGetsAQuestionAfterALongSilence() {
        let m = VoiceTurnManager(engine: NoModelEngine(), sink: InMemorySaveSink(), knownCategories: { [] })
        XCTAssertEqual(VoiceTurnManager.gate(utterance: "clean", silence: 5.5, lastActed: ""), .nudge)
        XCTAssertEqual(m.nudgeQuestion(for: "clean"), "What should I clean?")
    }

    /// Regression: "clean", "buy" and "Add a task to clean" got silence. They are always a question, even typed.
    func testBareActionsAlwaysAskWhatToDo() async {
        for (text, q) in [("clean", "What should I clean?"), ("Buy", "What should I buy?"), ("Add a task to clean", "What should I clean?")] {
            let m = VoiceTurnManager(engine: NoModelEngine(), sink: InMemorySaveSink(), knownCategories: { [] })
            let r = await m.decide(utterance: text)
            guard case .question(let asked) = r else { return XCTFail("\(text): expected a question, got \(VoiceTurnManager.describe(r))") }
            XCTAssertEqual(asked, q)
        }
    }

    /// Regression: the model said wait=true with action "clarify", and the question was swallowed.
    func testWaitWithAClarifyActionBecomesTheQuestion() {
        XCTAssertTrue(TaskValidator.waitIsReallyAQuestion(AgentDecisionValue(wait: true, action: "clarify", title: "", category: "", dueDate: "", dueTime: "", priority: "", assignee: "", frequency: "", notes: "", playbookName: "", playbookSteps: [], clarifyingQuestion: "", spokenResponse: "", moreTasks: [])))
    }

    /// Regression: "show me personal tasks" came back as wait=true with action view_tasks, so nothing was listed.
    func testWaitWithAViewRequestStillShowsTheTasks() {
        let d = AgentDecisionValue(wait: true, action: "view_tasks", title: "", category: "", dueDate: "", dueTime: "", priority: "",
                                   assignee: "", frequency: "", notes: "", playbookName: "", playbookSteps: [], clarifyingQuestion: "",
                                   spokenResponse: "", moreTasks: [])
        XCTAssertTrue(TaskValidator.waitIsContradicted(d, utterance: "show me personal tasks"))
        XCTAssertEqual(TaskValidator.validate(d, utterance: "show me personal tasks",
                                              context: ValidationContext(knownCategories: [], pendingTitles: [], recentTitles: [], now: Date(), calendar: .current)), .view)
    }

    /// Regression: the question and your answer both stay in the chat.
    func testAQuestionAndTheAnswerStayInTheChat() async throws {
        let convo = VoiceConversation()
        convo.open(seed: "clean")
        for _ in 0..<50 where convo.lines.isEmpty { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertEqual(convo.lines.map(\.text), ["clean", "What should I clean?"])
        XCTAssertEqual(convo.lines.map(\.role), [.you, .kitty])
        XCTAssertEqual(convo.liveText, "")
        convo.close()
    }

    /// Regression: "clean the" went quiet. A trailing "the" says nothing, so it is the same question as "clean".
    func testATrailingFillerWordStillGetsTheQuestion() {
        XCTAssertEqual(VoiceTurnManager.bareQuestion(for: "clean the"), "What should I clean?")
        XCTAssertEqual(VoiceTurnManager.bareQuestion(for: "Add a task to clean the"), "What should I clean?")
        XCTAssertNil(VoiceTurnManager.bareQuestion(for: "clean the bathroom"))
        XCTAssertEqual(VoiceTurnManager.gate(utterance: "clean the", silence: 5.5, lastActed: ""), .nudge)
        XCTAssertEqual(VoiceTurnManager.dropTrailingFiller("buy milk and"), "buy milk")
    }

    /// Regression: "I want my maid to clean the floor weekly" came back wait=true with a routine, and nothing happened.
    func testWaitWithARoutineIsNotDropped() {
        let d = AgentDecisionValue(wait: true, action: "create_routine", title: "Clean the floor", category: "", dueDate: "", dueTime: "",
                                   priority: "", assignee: "maid", frequency: "weekly", notes: "", playbookName: "", playbookSteps: [],
                                   clarifyingQuestion: "", spokenResponse: "", moreTasks: [])
        XCTAssertTrue(TaskValidator.waitIsContradicted(d, utterance: "i want my maid to clean the floor weekly"))
    }

    /// When you have stopped, a model "wait" gets an answer from the rule-based path instead of silence.
    func testFinalTurnNeverEndsInSilence() async {
        let engine = ScriptedEngine([AgentDecisionValue(wait: true, action: "wait", title: "", category: "", dueDate: "", dueTime: "", priority: "",
                                         assignee: "", frequency: "", notes: "", playbookName: "", playbookSteps: [], clarifyingQuestion: "",
                                         spokenResponse: "", moreTasks: [])])
        let m = VoiceTurnManager(engine: engine, sink: InMemorySaveSink(), knownCategories: { [] })
        let r = await m.decide(utterance: "ask the maid to clean the floor every Monday", final: true)
        if case .wait = r { XCTFail("a final turn must not end in silence") }
    }

    /// Spoken replies are cleaned up for the ear: no brackets, emoji or "Tasks:" labels, one breath per sentence.
    func testRepliesAreWrittenForTheEar() {
        let said = Speaker.speakable("You have 2 open personal tasks. Tasks: Call the dentist (Me), Renew passport (Me). 🙂")
        XCTAssertEqual(said, "You have 2 open personal tasks. Call the dentist, Renew passport.")
        XCTAssertEqual(Speaker.sentences(of: said).count, 2)
        XCTAssertGreaterThan(Speaker.pause(after: "What should I clean?"), Speaker.pause(after: "Okay."))
    }

    // MARK: Messy speech reaches the gate and the model already cleaned

    func testTheGateJudgesTheCleanedWords() {
        XCTAssertEqual(VoiceTurnManager.gate(utterance: "Um, add a task to clean the bathroom", silence: 4.0, lastActed: ""),
                       .evaluate("add a task to clean the bathroom"))
        XCTAssertEqual(VoiceTurnManager.gate(utterance: "um uh", silence: 4.0, lastActed: ""), .keepListening)
        // "clean the... no wait, wash the car" is one complete request
        XCTAssertEqual(VoiceTurnManager.gate(utterance: "clean the... no wait, wash the car", silence: 4.0, lastActed: ""),
                       .evaluate("wash the car"))
    }

    func testARepairWithNoCorrectionYetKeepsListeningInsteadOfAskingWhatToClean() {
        for silence in [4.0, 5.5, 7.0] {
            if case .hold = VoiceTurnManager.gate(utterance: "clean the bathroom, no wait", silence: silence, lastActed: "") {} else {
                XCTFail("should keep waiting for the correction at \(silence)s")
            }
        }
    }

    func testTheModelOnlyEverSeesTheCleanedWords() async {
        let engine = ScriptedEngine([nil])
        let m = VoiceTurnManager(engine: engine, sink: InMemorySaveSink(), knownCategories: { [] })
        _ = await m.decide(utterance: "um, clean the... no wait, wash the car", final: true)
        let prompt = engine.prompts.first ?? ""
        XCTAssertTrue(prompt.contains("wash the car"), prompt)
        XCTAssertFalse(prompt.lowercased().contains("no wait"), prompt)
        XCTAssertEqual(m.lastTrace.utterance, "wash the car")
    }

    func testTheDeltaIgnoresWhatWasTakenBack() {
        let state = ConversationStateManager()
        state.markProcessed("um, add milk")
        XCTAssertEqual(state.delta(for: "add milk, uh, and bread"), "and bread")
        XCTAssertEqual(state.lastProcessed, "add milk")
    }

    // MARK: Run-ons without commas

    func testRunOnsAreSplitAtEachNewAction() {
        let cases: [(String, [String])] = [
            ("clean bathroom buy milk wash the car", ["clean bathroom", "buy milk", "wash the car"]),
            ("clean the bathroom buy milk water the plants", ["clean the bathroom", "buy milk", "water the plants"]),
            ("wash the car fold laundry", ["wash the car", "fold laundry"]),
            ("call mom ask her to buy milk", ["call mom", "ask her to buy milk"]),
            ("clean the bathroom buy milk, wash the car", ["clean the bathroom", "buy milk", "wash the car"])
        ]
        for (text, expected) in cases {
            let a = BulkDetector.analyze(text)
            XCTAssertTrue(a.isBulk, text)
            XCTAssertEqual(a.segments, expected, text)
        }
    }

    func testSingleActionsAreNeverSplit() {
        for text in ["add a task to clean the bathroom", "buy fresh water bottles", "buy bottled water filters", "remember to lock the door",
                     "take out the trash", "clean the kitchen sink", "ask her to buy milk", "water the plants every morning"] {
            XCTAssertFalse(BulkDetector.analyze(text).isBulk, text)
        }
    }

    // MARK: A model that waits on a finished sentence (seen in real-model runs)

    func testAWaitWithACreateActionOnAFinishedSentenceIsAskedAgainOnce() async {
        let confused = decision("create_task", wait: true)
        let engine = ScriptedEngine([confused, decision("create_task", title: "Buy bread")])
        let m = VoiceTurnManager(engine: engine, sink: InMemorySaveSink(), knownCategories: { [] })
        m.ruleFallbackEnabled = false
        m.state.setListening(true)
        let r = await m.decide(utterance: "Buy bread", now: now)
        guard case .proposal(let p) = r else { return XCTFail("expected a proposal, got \(r)") }
        XCTAssertEqual(p.rows.map(\.title), ["Buy bread"])
        XCTAssertEqual(m.modelCalls, 2)
    }

    func testAGenuineWaitIsNotRetried() async {
        let engine = ScriptedEngine([decision("wait", wait: true), decision("create_task", title: "Buy bread")])
        let m = VoiceTurnManager(engine: engine, sink: InMemorySaveSink(), knownCategories: { [] })
        m.ruleFallbackEnabled = false
        m.state.setListening(true)
        let r = await m.decide(utterance: "Buy bread", now: now)
        guard case .wait = r else { return XCTFail("expected wait, got \(r)") }
        XCTAssertEqual(m.modelCalls, 1)
    }

    // MARK: Stopping Kitty and narrowing a list

    func testAListIsReadAsItIsWithNoCannedSuffix() {
        let message = "You have 3 open tasks. Call the dentist (Me), Renew passport (Me), Pay rent (Me)."
        XCTAssertEqual(Speaker.spokenForm(of: message, isList: true), message)
        XCTAssertFalse(Speaker.spokenForm(of: message, isList: true).lowercased().contains("narrow"))
        XCTAssertEqual(Speaker.spokenForm(of: "You have 1 open task. Pay rent (Me).", isList: true), "You have 1 open task. Pay rent (Me).")
        XCTAssertEqual(Speaker.spokenForm(of: message, isList: false), message)
    }

    func testAVeryLongListIsCutAtABreakWithoutAQuestion() {
        let items = (1...60).map { "Task number \($0)" }.joined(separator: ", ")
        let spoken = Speaker.spokenForm(of: "You have 60 open tasks. \(items).", isList: true)
        XCTAssertTrue(spoken.hasSuffix("The rest are on the screen."))
        XCTAssertFalse(spoken.contains("?"))
        XCTAssertLessThan(spoken.split(separator: " ").count, 160)
        XCTAssertFalse(spoken.contains("Task number 60"))
    }

    func testTheHintIsAlwaysTheLastThingSaid() {
        let hint = "Want just today's?"
        let spoken = Speaker.spokenForm(of: "You have 9 open tasks. A, B, C. \(hint)", isList: true, hint: hint)
        XCTAssertTrue(spoken.hasSuffix(hint))
        XCTAssertEqual(spoken.components(separatedBy: hint).count, 2, "said once")
    }

    func testWhichPhrasesNarrowTheLastList() {
        for text in ["only tomorrow", "just today", "only overdue", "what about done ones", "and for tomorrow", "only the maid",
                     "just personal", "now everyone", "only completed"] {
            XCTAssertTrue(TaskAgent.isViewRefinement(text), text)
        }
        for text in ["wash the car tomorrow", "buy milk", "show tasks for tomorrow", "add a task for today", "yes", "remind me tomorrow",
                     "what time is it", "clean the bathroom", "okay"] {
            XCTAssertFalse(TaskAgent.isViewRefinement(text), text)
        }
    }

    func testAFollowUpNarrowsTheListInsteadOfStartingOver() async {
        let engine = ScriptedEngine([decision("view_tasks")])
        let m = VoiceTurnManager(engine: engine, sink: InMemorySaveSink(), knownCategories: { [] })
        m.ruleFallbackEnabled = false
        m.state.setListening(true)
        guard case .reply(let first) = await m.decide(utterance: "Show me personal tasks", now: now), let base = first.spec else {
            return XCTFail("expected a list")
        }
        let calls = m.modelCalls

        guard case .reply(let second) = await m.decide(utterance: "only tomorrow", now: now), let narrowed = second.spec else {
            return XCTFail("expected a narrowed list")
        }
        XCTAssertEqual(m.lastTrace.route, "view-refine")
        XCTAssertEqual(m.modelCalls, calls, "a refinement needs no model call")
        XCTAssertEqual(narrowed.day, .tomorrow)
        XCTAssertEqual(narrowed.assignees, base.assignees, "the person filter stays")

        guard case .reply(let third) = await m.decide(utterance: "and only overdue", now: now), let overdue = third.spec else {
            return XCTFail("expected another narrowed list")
        }
        XCTAssertTrue(overdue.overdueOnly)
        XCTAssertEqual(overdue.assignees, base.assignees)
    }

    func testARefinementWithNoListOnScreenIsNotTreatedAsOne() async {
        let engine = ScriptedEngine([decision("clarify", question: "What would you like to see?")])
        let m = VoiceTurnManager(engine: engine, sink: InMemorySaveSink(), knownCategories: { [] })
        m.ruleFallbackEnabled = false
        m.state.setListening(true)
        _ = await m.decide(utterance: "only tomorrow", now: now)
        XCTAssertNotEqual(m.lastTrace.route, "view-refine")
    }
}
