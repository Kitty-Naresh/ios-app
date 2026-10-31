import XCTest
@testable import Kitty

/// One task per requested action or target. Everything here is SCRIPTED: no model is called, so none of it says the model splits
/// well; the real-model matrix (SplitMatrixTests, REAL_MODEL_SPLIT_EXTRACTION.md) measures that. What these tests check is the Swift
/// side of the principle "the model interprets and splits, Swift manages state, basic validation, duplicates, review and saving":
/// Swift keeps what the model returns (it never splits or merges a title by meaning), keeps the shared context on every task, treats
/// a repeated identical item as a duplicate only when nobody asked for it twice, applies a split correction without restarting, and
/// saves nothing without approval. They also check that the instruction text carries no example that could come back as a task. (The instruction wording tried for this
/// plan was measured and reverted; see REAL_MODEL_SPLIT_EXTRACTION.md.)

@MainActor
private final class SplitEngine: DecisionProviding {
    var creates: [BulkDecisionValue] = []
    var reviews: [DraftEditValue] = []
    var extractCalls = 0
    var lastFailure: String?

    func extract(prompt: String, fresh: Bool) async -> BulkDecisionValue? {
        extractCalls += 1
        return creates.isEmpty ? nil : creates.removeFirst()
    }
    func review(prompt: String) async -> DraftEditValue? { reviews.isEmpty ? nil : reviews.removeFirst() }
}

@MainActor
final class SplitExtractionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_793_000_000)

    private func make(_ engine: SplitEngine, sink: SaveSink? = nil) -> VoiceTurnManager {
        VoiceTurnManager(engine: engine, sink: sink ?? InMemorySaveSink(), knownCategories: { [] }, knownAssignees: { [] }, savedTasks: { [] })
    }

    private func proposal(_ result: TurnResult, file: StaticString = #filePath, line: UInt = #line) -> Proposal? {
        guard case .proposal(let p) = result else { XCTFail("expected a card, got \(result)", file: file, line: line); return nil }
        return p
    }

    private func save(_ p: Proposal, _ turns: VoiceTurnManager) async -> AgentReply? {
        guard turns.state.confirmation.consume(p.id) else { return nil }
        return await p.apply()
    }

    private func isoDay(_ offset: Int) -> String {
        let d = Calendar.current.date(byAdding: .day, value: offset, to: now)!
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    // MARK: Swift keeps what the model returned

    func testTwoTargetsFromOneShopAreTwoDraftsEachKeepingTheShop() async {
        let engine = SplitEngine(), sink = InMemorySaveSink()
        let said = "Buy milk and bread from Blinkit"
        engine.creates = [BulkDecisionValue(action: "create", tasks: [
            TaskDraftValue(title: "Buy Milk From Blinkit", heardAs: said),
            TaskDraftValue(title: "Buy Bread From Blinkit", heardAs: said),
        ])]
        let turns = make(engine, sink: sink)
        guard let p = proposal(await turns.decide(utterance: said, now: now, final: true)) else { return }
        XCTAssertEqual(turns.state.drafts.items.map(\.title), ["Buy Milk From Blinkit", "Buy Bread From Blinkit"])
        XCTAssertTrue(turns.state.drafts.items.allSatisfy { $0.title.contains("Blinkit") })
        XCTAssertEqual(p.rows.count, 2)
        XCTAssertEqual(p.title, "Save 2 tasks")
        XCTAssertTrue(sink.tasks.isEmpty, "nothing is saved without approval")
        XCTAssertEqual(engine.extractCalls, 1)

        _ = await save(p, turns)
        XCTAssertEqual(sink.tasks.map(\.title), ["Buy Milk From Blinkit", "Buy Bread From Blinkit"])
    }

    func testSwiftNeverSplitsACombinedTitleByItself() async {
        // The model returned ONE task that holds both. Swift does not read the title for "and": it is one draft.
        let engine = SplitEngine()
        let said = "Buy milk and bread from Blinkit, but make it one task"
        engine.creates = [BulkDecisionValue(action: "create", tasks: [TaskDraftValue(title: "Buy Milk And Bread From Blinkit", heardAs: said)])]
        let turns = make(engine)
        guard proposal(await turns.decide(utterance: said, now: now, final: true)) != nil else { return }
        XCTAssertEqual(turns.state.drafts.items.map(\.title), ["Buy Milk And Bread From Blinkit"])
    }

    func testAProductNameWithSeveralWordsAndAnAndStaysWhole() async {
        let engine = SplitEngine()
        let said = "Get Cetaphil body lotion, Cipcal and Tedibar soap"
        engine.creates = [BulkDecisionValue(action: "create", tasks: [
            TaskDraftValue(title: "Get Cetaphil Body Lotion", heardAs: "Get Cetaphil body lotion"),
            TaskDraftValue(title: "Get Cipcal", heardAs: "Cipcal"),
            TaskDraftValue(title: "Get Tedibar Soap", heardAs: "Tedibar soap"),
        ])]
        let turns = make(engine)
        guard let p = proposal(await turns.decide(utterance: said, now: now, final: true)) else { return }
        XCTAssertEqual(turns.state.drafts.items.map(\.title), ["Get Cetaphil Body Lotion", "Get Cipcal", "Get Tedibar Soap"])
        XCTAssertEqual(p.rows.count, 3)
    }

    // MARK: Shared context is on every task

    func testSharedAssigneeDayAndTimeOfDayArriveOnEveryTaskAndSurviveSaving() async {
        let engine = SplitEngine(), sink = InMemorySaveSink()
        let said = "Order paneer and Amul butter from Zepto tomorrow evening for Rani"
        let day = isoDay(1)
        engine.creates = [BulkDecisionValue(action: "create", tasks: [
            TaskDraftValue(title: "Order Paneer From Zepto", dueDate: day, timeOfDay: "evening", assignee: "Rani", heardAs: said),
            TaskDraftValue(title: "Order Amul Butter From Zepto", dueDate: day, timeOfDay: "evening", assignee: "Rani", heardAs: said),
        ])]
        let turns = make(engine, sink: sink)
        guard let p = proposal(await turns.decide(utterance: said, now: now, final: true)) else { return }
        let items = turns.state.drafts.items
        XCTAssertEqual(items.count, 2)
        XCTAssertNotNil(items[0].due)
        XCTAssertEqual(items[0].due, items[1].due)
        XCTAssertTrue(items.allSatisfy { $0.assignee == "Rani" && $0.slot == .evening && $0.title.contains("Zepto") })

        _ = await save(p, turns)
        XCTAssertEqual(sink.tasks.count, 2)
        XCTAssertTrue(sink.tasks.allSatisfy { $0.assignee == "Rani" && $0.slot == .evening && $0.due != nil })
        XCTAssertEqual(sink.tasks[0].due, sink.tasks[1].due)
    }

    func testTwoRepeatedActionsAreTwoRoutinesNotTasks() async {
        let engine = SplitEngine(), sink = InMemorySaveSink()
        let said = "Water the plants and feed the cat every morning"
        engine.creates = [BulkDecisionValue(action: "create", routines: [
            RoutineDraftValue.daily("Water The Plants", schedule: "every morning", timeOfDay: "morning"),
            RoutineDraftValue.daily("Feed The Cat", schedule: "every morning", timeOfDay: "morning"),
        ])]
        let turns = make(engine, sink: sink)
        guard let p = proposal(await turns.decide(utterance: said, now: now, final: true)) else { return }
        let items = turns.state.drafts.items
        XCTAssertEqual(items.map(\.title), ["Water The Plants", "Feed The Cat"])
        XCTAssertTrue(items.allSatisfy { $0.kind == .routine && $0.recurrence != nil && $0.slot == .morning })

        _ = await save(p, turns)
        XCTAssertEqual(sink.routines.count, 2)
        XCTAssertTrue(sink.tasks.isEmpty, "a repeating item is saved as a routine only")
    }

    // MARK: Duplicates

    func testTheSameItemTwiceIsOneDraftUnlessTheUserAskedForItTwice() async {
        let said = "Buy milk from Blinkit"
        // The model wrote the same thing twice and gave no reason: a duplicate.
        let a = SplitEngine()
        a.creates = [BulkDecisionValue(action: "create", tasks: [
            TaskDraftValue(title: "Buy Milk From Blinkit", heardAs: said), TaskDraftValue(title: "Buy Milk From Blinkit", heardAs: said)])]
        let first = make(a)
        _ = await first.decide(utterance: said, now: now, final: true)
        XCTAssertEqual(first.state.drafts.items.count, 1)

        // Two occurrences were asked for, and the model says so in the user's words: both stay.
        let b = SplitEngine()
        let twice = "Buy milk from Blinkit, two separate times"
        b.creates = [BulkDecisionValue(action: "create", tasks: [
            TaskDraftValue(title: "Buy Milk From Blinkit", heardAs: twice, distinctBecause: "two separate times"),
            TaskDraftValue(title: "Buy Milk From Blinkit", heardAs: twice, distinctBecause: "two separate times")])]
        let second = make(b)
        _ = await second.decide(utterance: twice, now: now, final: true)
        XCTAssertEqual(second.state.drafts.items.count, 2)
    }

    // MARK: Corrections that split or combine, without starting over

    func testSplittingACombinedDraftRemovesItAddsOneTaskPerTargetAndKeepsTheRest() async {
        let engine = SplitEngine()
        let said = "Get Cetaphil body lotion and Cipcal, and call the plumber"
        engine.creates = [BulkDecisionValue(action: "create", tasks: [
            TaskDraftValue(title: "Get Cetaphil Body Lotion And Cipcal", heardAs: "Get Cetaphil body lotion and Cipcal"),
            TaskDraftValue(title: "Call The Plumber", heardAs: "call the plumber"),
        ])]
        let turns = make(engine)
        _ = await turns.decide(utterance: said, now: now, final: true)
        let combined = turns.state.drafts.items.first { $0.title.contains("Cipcal") }!
        let plumber = turns.state.drafts.items.first { $0.title.contains("Plumber") }!

        engine.reviews = [DraftEditValue(action: "change",
                                         edits: [DraftEditOpValue(refs: [combined.ref], remove: true)],
                                         add: [TaskDraftValue(title: "Get Cetaphil Body Lotion"), TaskDraftValue(title: "Get Cipcal")])]
        _ = await turns.decide(utterance: said + " Make those two separate tasks.", now: now, final: true)

        let titles = turns.state.drafts.items.map(\.title)
        XCTAssertEqual(Set(titles), ["Get Cetaphil Body Lotion", "Get Cipcal", "Call The Plumber"])
        XCTAssertEqual(turns.state.drafts.items.first { $0.ref == plumber.ref }, plumber, "an unrelated item changed")
        XCTAssertEqual(engine.extractCalls, 1, "a correction is a review turn, not a new extraction")
    }

    func testCombiningDraftsIsTheModelsDecisionAndSwiftAppliesIt() async {
        let engine = SplitEngine()
        let said = "Buy milk and bread from Blinkit"
        engine.creates = [BulkDecisionValue(action: "create", tasks: [
            TaskDraftValue(title: "Buy Milk From Blinkit", heardAs: said), TaskDraftValue(title: "Buy Bread From Blinkit", heardAs: said)])]
        let turns = make(engine)
        _ = await turns.decide(utterance: said, now: now, final: true)
        let (first, second) = (turns.state.drafts.items[0], turns.state.drafts.items[1])

        engine.reviews = [DraftEditValue(action: "change", edits: [
            DraftEditOpValue(refs: [first.ref], title: "Buy Milk And Bread From Blinkit"), DraftEditOpValue(refs: [second.ref], remove: true)])]
        _ = await turns.decide(utterance: said + " Make it one task.", now: now, final: true)
        XCTAssertEqual(turns.state.drafts.items.map(\.title), ["Buy Milk And Bread From Blinkit"])
    }

    // MARK: The instruction text

    func testTheInstructionsStillSayThatWhatTheUserAsksForWinsOverTheDefault() {
        // The wording that was tried to make the model split by default measured worse and was reverted (REAL_MODEL_SPLIT_EXTRACTION.md);
        // what stays is that an explicit request to split or combine overrides every default, stated once.
        XCTAssertTrue(PersistentInstructions.common.contains("separate tasks when they ask for separate tasks"))
        XCTAssertEqual(PersistentInstructions.text.components(separatedBy: "overrides these defaults").count - 1, 1)
        XCTAssertEqual(PersistentInstructions.text.components(separatedBy: "One item per requested action").count - 1, 1)
    }

    func testNoInstructionCarriesAnExampleThatCouldComeBackAsATask() {
        // Examples in instructions and schema text come back as tasks (see the leak case in the matrix).
        for text in [PersistentInstructions.text, PersistentInstructions.review] {
            for word in ["milk", "bread", "blinkit", "zepto", "paneer", "cetaphil", "cipcal", "tedibar", "pharmacy"] {
                XCTAssertFalse(text.lowercased().contains(word), "\"\(word)\" appears in the instructions")
            }
        }
    }

    func testTheInstructionsStayShort() {
        // Consolidated, not stacked: the extraction instructions must not grow beyond a modest size.
        XCTAssertLessThan(PersistentInstructions.text.count, 5_200, "the instructions have grown to \(PersistentInstructions.text.count) characters")
    }
}
