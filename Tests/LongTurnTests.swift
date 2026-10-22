import XCTest
@testable import Kitty

final class LongTurnAnalyzerTests: XCTestCase {
    /// Thursday 22 October 2026, so Friday is the 23rd and Saturday the 24th.
    static let now: Date = {
        var c = DateComponents(); c.year = 2026; c.month = 10; c.day = 22; c.hour = 9
        return Calendar.current.date(from: c)!
    }()
    static func day(_ n: Int) -> Date {
        var c = DateComponents(); c.year = 2026; c.month = 10; c.day = n
        return Calendar.current.date(from: c)!
    }

    static let inLaws = "Okay so we have my in-laws coming this Saturday and honestly the house is a mess, so I was thinking the maid should clean the bathrooms and mop the living room on Friday, oh and I need to buy flowers and snacks, also remind me to call the caterer"

    private func analyze(_ s: String, words: [SpokenWord] = []) -> LongTurn {
        LongTurnAnalyzer.analyze(s, words: words, now: Self.now)
    }

    // MARK: The motivating example

    func testTheInLawsExample() {
        let t = analyze(Self.inLaws)
        XCTAssertEqual(t.actions.map(\.text), ["clean the bathrooms", "mop the living room", "buy flowers and snacks", "call the caterer"])
        XCTAssertEqual(t.actions.map(\.title), ["Clean the bathrooms", "Mop the living room", "Buy flowers and snacks", "Call the caterer"])
        XCTAssertEqual(t.actions.map(\.assignee), [Assignee.househelp, Assignee.househelp, nil, nil])
        XCTAssertEqual(t.actions.map(\.due), [Self.day(23), Self.day(23), nil, nil], "Friday is said for both cleaning tasks; context is not copied in")
        XCTAssertEqual(t.context.due, Self.day(24))
        XCTAssertEqual(t.context.dueLabel, "Saturday")
        XCTAssertEqual(t.context.occasion, "in-laws")
        XCTAssertEqual(t.context.notes, "For in-laws")
        XCTAssertEqual(t.context.usedLine, "Saturday, for in-laws")
        XCTAssertEqual(t.skipped, ["the house is a mess"])
    }

    func testARamblingStoryEndsInOneAction() {
        let t = analyze("So last week the plumber came and he said the tap was leaking and honestly I don't know if he fixed it, anyway call the plumber about the leaking tap tomorrow morning")
        XCTAssertEqual(t.actions.map(\.text), ["call the plumber about the leaking tap"])
        XCTAssertEqual(t.actions.first?.due, Self.day(23))
        XCTAssertGreaterThanOrEqual(t.skipped.count, 2)
        XCTAssertTrue(t.skipped.contains { $0.contains("he said the tap was leaking") })
    }

    func testAShoppingListAndARoutineAfterChatter() {
        let t = analyze("Um so it's been a crazy week you know but add milk eggs and bread to my Blinkit order and water the plants every morning")
        XCTAssertEqual(t.actions.count, 2)
        XCTAssertEqual(t.actions.map(\.scheduled), [false, true])
        XCTAssertTrue(t.actions[0].text.contains("milk eggs and bread"))
        XCTAssertTrue(t.skipped.contains { $0.contains("crazy week") })
    }

    // MARK: Splitting

    func testClausesSplitOnMarkers() {
        XCTAssertEqual(LongTurnAnalyzer.split("wash the car and then dry it also pay the rent plus call mom"),
                       ["wash the car", "dry it", "pay the rent", "call mom"])
        XCTAssertEqual(LongTurnAnalyzer.split("buy milk one more thing call the plumber another thing book the vet"),
                       ["buy milk", "call the plumber", "book the vet"])
        XCTAssertEqual(LongTurnAnalyzer.split("buy bread oh and remind me to call dad don't forget to pay the bill"),
                       ["buy bread", "remind me to call dad", "don't forget to pay the bill"])
    }

    func testAndBetweenObjectsDoesNotSplit() {
        XCTAssertEqual(LongTurnAnalyzer.split("clean the bathroom and the kitchen"), ["clean the bathroom and the kitchen"])
        XCTAssertEqual(LongTurnAnalyzer.split("buy flowers and snacks"), ["buy flowers and snacks"])
    }

    func testClausesSplitOnPausesWhenTimestampsExist() {
        let said = "buy milk call mom pay rent"
        let words = said.split(separator: " ").enumerated().map { i, w -> SpokenWord in
            // a 0.9 s pause after "milk" and after "mom"
            let starts: [Double] = [0, 0.4, 1.7, 2.1, 3.4, 3.8]
            return SpokenWord(text: String(w), confidence: 0.9, timestamp: starts[i], duration: 0.3)
        }
        XCTAssertEqual(LongTurnAnalyzer.split(said, words: words), ["buy milk", "call mom", "pay rent"])
        XCTAssertEqual(LongTurnAnalyzer.split(said), [said], "without timestamps nothing splits it")
    }

    // MARK: Labels

    func testFramesAreStrippedFromActions() {
        for (said, body) in [("I need to call the bank", "call the bank"), ("we have to pick up the kids", "pick up the kids"),
                             ("can you book the vet", "book the vet"), ("please pay the electricity bill", "pay the electricity bill"),
                             ("make sure to lock the gate", "lock the gate"), ("have the maid wash the windows", "wash the windows"),
                             ("ask Rani to buy bread", "buy bread"), ("the cook should prepare dinner", "prepare dinner"),
                             ("I was thinking we should clean the garage", "clean the garage")] {
            XCTAssertEqual(LongTurnAnalyzer.actionBody(said.split(separator: " ").map(String.init))?.joined(separator: " "), body, said)
        }
        XCTAssertNil(LongTurnAnalyzer.actionBody("the house is a mess".split(separator: " ").map(String.init)))
        XCTAssertNil(LongTurnAnalyzer.actionBody(["call"]), "an action needs an object")
    }

    func testChatterContextAndActionsAreLabelled() {
        let t = analyze(Self.inLaws)
        XCTAssertEqual(t.clauses.map(\.kind), [.context, .chatter, .action, .action, .action])
        XCTAssertEqual(analyze("the guests arrive on Friday").clauses.map(\.kind), [.context])
        XCTAssertEqual(analyze("it has been such a long day honestly").clauses.map(\.kind), [.chatter])
    }

    func testAssigneeIsOnlyARoleTheUserNamed() {
        let t = analyze("I need to buy flowers and snacks")
        XCTAssertNil(t.actions.first?.assignee, "“I need to” is not an assignee")
    }

    func testTwoContextDatesAreNotPickedBetween() {
        let t = analyze("The guests arrive on Friday and the party is on Saturday, so buy snacks and book the cake")
        XCTAssertNil(t.context.due)
        XCTAssertEqual(t.actions.count, 2)
    }

    func testACorrectionChangesTheLastActionsDay() {
        let t = analyze("Call the plumber on Friday, no wait make that Saturday")
        XCTAssertEqual(t.actions.map(\.text), ["call the plumber"])
        XCTAssertEqual(t.actions.first?.due, Self.day(24))
    }

    func testEachActionKeepsItsOwnDay() {
        let t = analyze("Wash the car on Friday and mop the floor on Saturday")
        XCTAssertEqual(t.actions.map(\.due), [Self.day(23), Self.day(24)])
    }

    func testLongTurnsAreOverTwelveWords() {
        XCTAssertFalse(LongTurnAnalyzer.isLong("buy milk and bread tomorrow"))
        XCTAssertTrue(LongTurnAnalyzer.isLong(Self.inLaws))
    }

    // MARK: BulkDetector uses the action clauses of a long turn

    func testAnIntroNoLongerDefeatsBulkDetection() {
        let a = BulkDetector.analyze(Self.inLaws, now: Self.now)
        XCTAssertEqual(a.kind, .tasks)
        XCTAssertEqual(a.segments, ["clean the bathrooms", "mop the living room", "buy flowers and snacks", "call the caterer"])
        XCTAssertEqual(a.context.usedLine, "Saturday, for in-laws")
        XCTAssertEqual(a.skipped, ["the house is a mess"])
    }

    func testShortUtterancesKeepTheVerbLedRule() {
        XCTAssertNil(BulkDetector.analyze("So I need to clean the bathroom and buy milk").turn, "12 words or fewer: no long-turn reading")
        XCTAssertFalse(BulkDetector.analyze("Okay so honestly the house is a mess").isBulk)
    }

    func testOneAskInALongTurnIsNotBulkButKeepsTheReading() {
        let a = BulkDetector.analyze("So last week the plumber came and he said the tap was leaking, anyway call the plumber about the leaking tap tomorrow morning", now: Self.now)
        XCTAssertFalse(a.isBulk)
        XCTAssertEqual(a.turn?.actions.map(\.text), ["call the plumber about the leaking tap"])
    }

    func testAScheduledActionMakesTheLongTurnRoutines() {
        let a = BulkDetector.analyze("Um so it's been a crazy week you know but add milk eggs and bread to my Blinkit order and water the plants every morning", now: Self.now)
        XCTAssertEqual(a.kind, .routines)
    }

    func testLongQuestionsAndManagementRequestsAreNotReadAsNewTasks() {
        XCTAssertNil(BulkDetector.analyze("What do I have for tomorrow and also remind me what I wanted to buy for the party on Saturday", now: Self.now).turn)
        XCTAssertNil(BulkDetector.analyze("Please mark the laundry task as done and remove the milk task from my list and cancel the plumber visit", now: Self.now).turn)
    }
}

/// A model that answers bulk prompts one after another and keeps every prompt it was shown.
@MainActor
final class BulkQueueEngine: DecisionProviding {
    var answers: [BulkDecisionValue?]
    private(set) var prompts: [String] = []
    init(_ answers: [BulkDecisionValue?]) { self.answers = answers }
    func decide(prompt: String) async -> AgentDecisionValue? { nil }
    func decideBulk(prompt: String) async -> BulkDecisionValue? {
        prompts.append(prompt)
        return answers.isEmpty ? nil : answers.removeFirst()
    }
    static func tasks(_ titles: [String]) -> BulkDecisionValue {
        BulkDecisionValue(action: "create_tasks", tasks: titles.map { TaskDraftValue(title: $0) })
    }
}

@MainActor
final class LongTurnPromptTests: XCTestCase {
    private func manager(_ engine: DecisionProviding, fallback: Bool = false) -> VoiceTurnManager {
        let m = VoiceTurnManager(engine: engine, sink: InMemorySaveSink(), knownCategories: { [] }, knownAssignees: { [] })
        m.ruleFallbackEnabled = fallback
        return m
    }

    func testTheDigestListsContextThenOneLinePerAction() {
        let t = LongTurnAnalyzer.analyze(LongTurnAnalyzerTests.inLaws, now: LongTurnAnalyzerTests.now)
        let d = LongTurnAnalyzer.digest(context: t.context, actions: t.actions)
        XCTAssertEqual(d, """
        Context: Saturday, for in-laws.
        - clean the bathrooms (Friday, Househelp)
        - mop the living room (Friday, Househelp)
        - buy flowers and snacks
        - call the caterer
        """)
    }

    func testTheDigestFitsItsBudgetByShorteningWordsNotDroppingActions() {
        let actions = (1...12).map { ActionClause(text: "clean the very large dusty room number \($0) in the old house at the end of the road", title: "") }
        let d = LongTurnAnalyzer.digest(context: SharedContext(), actions: actions, budget: 900)
        XCTAssertLessThanOrEqual(d.count, 900)
        XCTAssertEqual(d.split(separator: "\n").count, 12)
        XCTAssertTrue(d.hasPrefix("- clean the very"), "the front of the first action is kept")
    }

    func testChunksOfFourWithAtMostThreeCalls() {
        func acts(_ n: Int) -> [ActionClause] { (1...n).map { ActionClause(text: "do thing \($0)", title: "") } }
        XCTAssertEqual(LongTurnAnalyzer.chunks(acts(4)).groups.map(\.count), [4])
        XCTAssertEqual(LongTurnAnalyzer.chunks(acts(5)).groups.map(\.count), [4, 1])
        let big = LongTurnAnalyzer.chunks(acts(14))
        XCTAssertEqual(big.groups.map(\.count), [4, 4, 4])
        XCTAssertEqual(big.rest.count, 2)
    }

    func testThePromptNoLongerCutsTheFrontOfALongUtterance() {
        let said = "START " + String(repeating: "word ", count: 400) + "END"
        let p = PromptBuilder.build(utterance: said, pendingTask: nil, pendingPlaybook: nil, knownCategories: [], now: LongTurnAnalyzerTests.now)
        XCTAssertTrue(p.contains("Current utterance: \"START"))
        XCTAssertTrue(p.contains("END\""))
        XCTAssertFalse(p.contains("…START"))
    }

    func testALongTurnSendsTheModelADigestNotTheRamble() async {
        let engine = BulkQueueEngine([BulkQueueEngine.tasks(["Clean bathrooms", "Mop living room", "Buy flowers and snacks", "Call the caterer"])])
        let m = manager(engine)
        _ = await m.decide(utterance: LongTurnAnalyzerTests.inLaws, now: LongTurnAnalyzerTests.now)
        XCTAssertEqual(engine.prompts.count, 1)
        let p = engine.prompts[0]
        XCTAssertTrue(p.contains("Context: Saturday, for in-laws."), p)
        XCTAssertTrue(p.contains("- clean the bathrooms (Friday, Househelp)"), p)
        XCTAssertFalse(p.contains("honestly"), "the chatter is not sent")
        XCTAssertEqual(m.lastTrace.modelCallCount, 1)
        XCTAssertEqual(m.lastTrace.chunks, 1)
    }

    func testSixActionsUseTwoCallsAndAreMerged() async {
        let said = "Okay so it is a busy week and honestly I am tired, but I need to call the plumber, buy milk, pay the rent, wash the car, book the vet, and email the landlord"
        let engine = BulkQueueEngine([BulkQueueEngine.tasks(["Call the plumber", "Buy milk", "Pay the rent", "Wash the car"]),
                                      BulkQueueEngine.tasks(["Book the vet", "Email the landlord"])])
        let m = manager(engine)
        let r = await m.decide(utterance: said, now: LongTurnAnalyzerTests.now)
        XCTAssertEqual(engine.prompts.count, 2)
        XCTAssertEqual(m.lastTrace.modelCallCount, 2)
        XCTAssertTrue(engine.prompts[0].contains("- call the plumber"))
        XCTAssertFalse(engine.prompts[0].contains("book the vet"), "the second group is a second call")
        XCTAssertTrue(engine.prompts[1].contains("- book the vet"))
        guard case .proposal(let p) = r else { return XCTFail("\(r)") }
        XCTAssertEqual(p.rows.count, 6)
    }

    func testMoreThanTwelveActionsUseThreeCallsAndTheRestComesFromTheClauses() async {
        let verbs = ["call the plumber", "buy milk", "pay the rent", "wash the car", "book the vet", "email the landlord", "clean the garage",
                     "water the plants", "fix the tap", "order the cake", "print the tickets", "pack the bags", "renew the passport", "send the invoice"]
        let said = "Okay so honestly it is a lot but I need to " + verbs.joined(separator: ", ")
        let engine = BulkQueueEngine([BulkQueueEngine.tasks(Array(verbs[0..<4]).map { $0.capitalized }),
                                      BulkQueueEngine.tasks(Array(verbs[4..<8]).map { $0.capitalized }),
                                      BulkQueueEngine.tasks(Array(verbs[8..<12]).map { $0.capitalized })])
        let m = manager(engine)
        let r = await m.decide(utterance: said, now: LongTurnAnalyzerTests.now)
        XCTAssertEqual(engine.prompts.count, 3, "never more than three calls")
        guard case .proposal(let p) = r else { return XCTFail("\(r)") }
        XCTAssertEqual(p.rows.count, 14, "the last two come from the rule planner")
    }
}

@MainActor
final class LongTurnValidationTests: XCTestCase {
    private let inLaws = LongTurnAnalyzerTests.inLaws
    private let now = LongTurnAnalyzerTests.now
    private func day(_ n: Int) -> Date { LongTurnAnalyzerTests.day(n) }

    private func manager(_ engine: DecisionProviding) -> VoiceTurnManager {
        let m = VoiceTurnManager(engine: engine, sink: InMemorySaveSink(), knownCategories: { [] }, knownAssignees: { [] })
        m.ruleFallbackEnabled = false
        return m
    }

    private let fourTitles = ["Clean bathrooms", "Mop living room", "Buy flowers and snacks", "Call the caterer"]

    func testOwnDaysAndPeopleStayWithTheirTasksAndContextIsNotCopiedIn() async {
        let m = manager(BulkQueueEngine([BulkQueueEngine.tasks(fourTitles)]))
        let r = await m.decide(utterance: inLaws, now: now)
        guard case .proposal = r else { return XCTFail("\(r)") }
        let items = m.state.drafts.items
        XCTAssertEqual(items.map(\.title), fourTitles)
        XCTAssertEqual(items.map(\.due), [day(23), day(23), nil, nil])
        XCTAssertEqual(items.map(\.assignee), [Assignee.househelp, Assignee.househelp, nil, nil])
        XCTAssertEqual(items.map(\.notes), Array(repeating: "For in-laws", count: 4))
    }

    func testTheModelCannotSpreadAPersonOrADayToTasksThatDidNotSayIt() async {
        var tasks = BulkQueueEngine.tasks(fourTitles)
        for i in tasks.tasks.indices { tasks.tasks[i].assignee = "Househelp"; tasks.tasks[i].dueDate = "2026-10-24" }
        let m = manager(BulkQueueEngine([tasks]))
        _ = await m.decide(utterance: inLaws, now: now)
        let items = m.state.drafts.items
        XCTAssertEqual(items.map(\.assignee), [Assignee.househelp, Assignee.househelp, nil, nil])
        XCTAssertEqual(items.map(\.due), [day(23), day(23), nil, nil])
    }

    func testAnInventedTaskIsDroppedAndAMissedOneComesBackWithItsOwnFields() async {
        let m = manager(BulkQueueEngine([BulkQueueEngine.tasks(["Clean bathrooms", "Mop living room", "Buy flowers and snacks", "Walk the dog"])]))
        _ = await m.decide(utterance: inLaws, now: now)
        let items = m.state.drafts.items
        XCTAssertEqual(items.map { $0.title.lowercased() }, ["clean bathrooms", "mop living room", "buy flowers and snacks", "call the caterer"])
        XCTAssertFalse(items.contains { $0.title.lowercased().contains("dog") })
    }

    func testTheChatterIsNotAddedBack() async {
        let m = manager(BulkQueueEngine([BulkQueueEngine.tasks(fourTitles)]))
        _ = await m.decide(utterance: inLaws, now: now)
        XCTAssertFalse(m.state.drafts.items.contains { $0.title.lowercased().contains("mess") })
    }

    // MARK: The due date is asked, not assumed

    func testKittyAsksBeforeTaggingTheContextDay() async {
        let m = manager(BulkQueueEngine([BulkQueueEngine.tasks(fourTitles)]))
        let r = await m.decide(utterance: inLaws, now: now)
        guard case .proposal(let p) = r else { return XCTFail("\(r)") }
        XCTAssertEqual(p.prompt, "I picked these because of Saturday, for in-laws. Should I tag the ones without a date as due Saturday?")
        XCTAssertFalse(p.autoConfirm)
        XCTAssertEqual(m.state.pendingContextDue?.keys.count, 2)
    }

    func testYesTagsOnlyTheUndatedTasks() async {
        let m = manager(BulkQueueEngine([BulkQueueEngine.tasks(fourTitles)]))
        _ = await m.decide(utterance: inLaws, now: now)
        let r = await m.decide(utterance: inLaws + " yes", now: now)
        guard case .proposal(let p) = r else { return XCTFail("\(r)") }
        XCTAssertEqual(m.state.drafts.items.map(\.due), [day(23), day(23), day(24), day(24)])
        XCTAssertEqual(p.prompt, "Tagged 2 tasks as due Saturday. Should I save these?")
        XCTAssertNil(m.state.pendingContextDue)
    }

    func testNoLeavesThemWithoutADate() async {
        let m = manager(BulkQueueEngine([BulkQueueEngine.tasks(fourTitles)]))
        _ = await m.decide(utterance: inLaws, now: now)
        let r = await m.decide(utterance: inLaws + " no", now: now)
        guard case .proposal(let p) = r else { return XCTFail("\(r)") }
        XCTAssertEqual(m.state.drafts.items.map(\.due), [day(23), day(23), nil, nil])
        XCTAssertEqual(p.prompt, "Okay, no due date for those. Should I save these?")
    }

    func testSayingSomethingElseDropsTheQuestionWithoutTagging() async {
        let m = manager(BulkQueueEngine([BulkQueueEngine.tasks(fourTitles)]))
        _ = await m.decide(utterance: inLaws, now: now)
        _ = await m.decide(utterance: inLaws + " also add buy candles", now: now)
        XCTAssertNil(m.state.pendingContextDue)
        XCTAssertEqual(m.state.drafts.items.filter { $0.due == day(24) }.count, 0)
    }

    func testNoQuestionWhenEveryTaskHasItsOwnDayOrThereIsNoContextDay() async {
        let said = "Okay so honestly it has been a long week but I need to call the plumber on Friday and wash the car on Saturday and buy the paint on Monday"
        let m = manager(BulkQueueEngine([BulkQueueEngine.tasks(["Call the plumber", "Wash the car", "Buy the paint"])]))
        let r = await m.decide(utterance: said, now: now)
        guard case .proposal(let p) = r else { return XCTFail("\(r)") }
        XCTAssertNotEqual(p.prompt?.hasPrefix("I picked these"), true)
        XCTAssertNil(m.state.pendingContextDue)
    }
}


// MARK: A model that only says "wait" does not stop a turn that holds real actions

@MainActor
final class LongTurnWaitTests: XCTestCase {
    private struct WaitingEngine: DecisionProviding {
        func decide(prompt: String) async -> AgentDecisionValue? { AgentDecisionValue(wait: true, action: "wait") }
        func decideBulk(prompt: String) async -> BulkDecisionValue? { BulkDecisionValue(action: "wait") }
    }
    private let now = LongTurnAnalyzerTests.now
    private func manager(fallback: Bool) -> VoiceTurnManager {
        let m = VoiceTurnManager(engine: WaitingEngine(), sink: InMemorySaveSink(), knownCategories: { [] }, knownAssignees: { [] })
        m.ruleFallbackEnabled = fallback
        return m
    }

    func testSeveralActionsComeFromTheClausesWhenEveryCallSaysWait() async {
        let m = manager(fallback: true)
        let r = await m.decide(utterance: LongTurnAnalyzerTests.inLaws, now: now)
        guard case .proposal = r else { return XCTFail("\(r)") }
        XCTAssertEqual(m.lastTrace.route, "long-turn-rules")
        XCTAssertEqual(m.state.drafts.items.count, 4)
    }

    func testOneActionInALongTurnGoesThroughTheRulePlanner() async {
        let m = manager(fallback: true)
        let said = "So yesterday was a total mess and honestly I am so tired of it all but anyway I need to call the plumber on Friday"
        let r = await m.decide(utterance: said, now: now)
        XCTAssertEqual(m.lastTrace.route, "long-turn-rules")
        switch r {
        case .wait: XCTFail("a turn with an action must not wait")
        case .proposal(let p): XCTAssertTrue(p.rows.contains { $0.title.lowercased().contains("plumber") }, "\(p.rows.map(\.title))")
        default: break
        }
    }

    func testWithoutTheRuleFallbackTheWaitIsReportedHonestly() async {
        let m = manager(fallback: false)
        let said = "So yesterday was a total mess and honestly I am so tired of it all but anyway I need to call the plumber on Friday"
        let r = await m.decide(utterance: said, now: now)
        if case .wait = r {} else { XCTFail("\(r)") }
    }

    func testAShortUnfinishedTurnStillWaits() async {
        let m = manager(fallback: true)
        let r = await m.decide(utterance: "Add a task to", now: now)
        if case .wait = r {} else { XCTFail("\(r)") }
    }
}

// MARK: The preview shows what it used and what it skipped

@MainActor
final class LongTurnPreviewTests: XCTestCase {
    private let inLaws = LongTurnAnalyzerTests.inLaws
    private let now = LongTurnAnalyzerTests.now
    private func manager() -> VoiceTurnManager {
        let m = VoiceTurnManager(engine: BulkQueueEngine([BulkQueueEngine.tasks(["Clean bathrooms", "Mop living room", "Buy flowers and snacks", "Call the caterer"])]),
                                 sink: InMemorySaveSink(), knownCategories: { [] }, knownAssignees: { [] })
        m.ruleFallbackEnabled = false
        return m
    }

    func testThePreviewSaysWhatItUsedAndWhatItSkipped() async {
        let m = manager()
        let r = await m.decide(utterance: inLaws, now: now)
        guard case .proposal(let p) = r else { return XCTFail("\(r)") }
        XCTAssertEqual(p.used, "Saturday, for in-laws")
        XCTAssertTrue(p.skipped.contains { $0.contains("mess") }, "\(p.skipped)")
        XCTAssertFalse(p.skipped.isEmpty)
    }

    func testAlsoAddWorksForTheSkippedText() {
        guard case .addItem(let t)? = DraftEditParser.parse("also add the house is a mess", hasPlaybook: false) else { return XCTFail("not parsed") }
        XCTAssertEqual(t, "the house is a mess")
    }

    func testSayingAlsoAddWithASkippedLineMakesItATaskAndRemovesItFromSkipped() async {
        let m = manager()
        let first = await m.decide(utterance: inLaws, now: now)
        guard case .proposal(let p) = first, let mess = p.skipped.first(where: { $0.contains("mess") }) else { return XCTFail("\(first)") }
        let r = await m.decide(utterance: inLaws + " also add " + mess, now: now)
        guard case .proposal(let after) = r else { return XCTFail("\(r)") }
        XCTAssertEqual(m.state.drafts.items.count, 5)
        XCTAssertTrue(m.state.drafts.items.last?.title.lowercased().contains("mess") == true)
        XCTAssertFalse(after.skipped.contains(mess))
        XCTAssertEqual(after.used, "Saturday, for in-laws")
    }
}
