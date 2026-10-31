import XCTest
@testable import Kitty

/// A user-named list on the production path: the model returns the list name once (`listName`) and one item per thing. SCRIPTED: no
/// model is called, so none of this says the model returns that; it checks the Swift side. The list name is a grouping name only: it
/// is shown on the card, a list is made or joined only when the user approves, every approved item points at it, and nothing about it
/// comes from a category. The fixtures are placeholders on purpose: no product, brand or food names.

@MainActor
private final class ListEngine: DecisionProviding {
    var creates: [BulkDecisionValue] = []
    var lastFailure: String?
    func extract(prompt: String, fresh: Bool) async -> BulkDecisionValue? { creates.isEmpty ? nil : creates.removeFirst() }
    func review(prompt: String) async -> DraftEditValue? { nil }
}

/// A save sink on a scratch `TaskStore`, so lists and tasks can be read back and the user's real store is never touched.
@MainActor
private final class ScratchSink: SaveSink {
    let store: TaskStore
    init(_ store: TaskStore) { self.store = store }
    func saveTasks(_ planned: [PlannedTask]) -> [UUID] { store.addMany(planned).map(\.id) }
    func saveRoutine(_ planned: PlannedTask) -> UUID? { nil }
    func savePlaybook(name: String, category: TaskCategory?, steps: [PlaybookStep], due: Date?) -> (replaced: Bool, created: [UUID]) { (false, []) }
    func playbook(matching title: String) -> Playbook? { nil }
    func addPlaybookTasks(_ playbook: Playbook, due: Date?) -> [UUID] { [] }
    func recordUtterance(_ rawText: String) -> UUID? { nil }
    func existingListName(for raw: String) -> String? { store.profile(named: raw)?.name }
    func link(_ taskIDs: [UUID], to utteranceID: UUID) {}
    func finishSaving(routineIDs: Set<UUID>) async -> [UUID] { [] }
}

@MainActor
final class ListExtractionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_793_000_000)

    private func make(_ engine: ListEngine, sink: SaveSink? = nil) -> VoiceTurnManager {
        VoiceTurnManager(engine: engine, sink: sink ?? InMemorySaveSink(), knownCategories: { [] }, knownAssignees: { [] }, savedTasks: { [] })
    }

    private func proposal(_ result: TurnResult, file: StaticString = #filePath, line: UInt = #line) -> Proposal? {
        guard case .proposal(let p) = result else { XCTFail("expected a card, got \(result)", file: file, line: line); return nil }
        return p
    }

    private func approve(_ p: Proposal, _ turns: VoiceTurnManager) async -> AgentReply? {
        guard turns.state.confirmation.consume(p.id) else { return nil }
        return await p.apply()
    }

    private func decoded(_ d: BulkDecisionValue) -> [DraftItem] {
        guard case .items(let items) = BulkValidator.decode(d, context: ValidationContext()) else { XCTFail("expected drafts"); return [] }
        return items
    }

    private func scratch() -> (TaskStore, UserDefaults, String) {
        let suite = "ListExtractionTests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        return (TaskStore(defaults: defaults), defaults, suite)
    }

    // MARK: List splitting

    func testANamedListWithThreeItemsIsThreeDraftsOnThatList() {
        let items = decoded(BulkDecisionValue(action: "create", tasks: [
            TaskDraftValue(title: "Get Item One", notes: "detail one"),
            TaskDraftValue(title: "Get Item Two", notes: "detail two"),
            TaskDraftValue(title: "Get Item Three"),
        ], listName: "Sample"))
        XCTAssertEqual(items.map(\.title), ["Get Item One", "Get Item Two", "Get Item Three"])
        XCTAssertTrue(items.allSatisfy { $0.listName == "Sample" })
        XCTAssertFalse(items.contains { Words.key($0.title) == Words.key("Sample") || Words.key($0.title) == Words.key("Sample list") },
                       "no task is titled with the list name")
        XCTAssertEqual(items.map(\.notes), ["detail one", "detail two", nil], "details stay on their own item")
        XCTAssertTrue(items.allSatisfy { $0.kind == .task })
    }

    func testTheFinalItemAndItsDetailAreKept() {
        let items = decoded(BulkDecisionValue(action: "create", tasks: [
            TaskDraftValue(title: "Get Item One"),
            TaskDraftValue(title: "Get Item Two"),
            TaskDraftValue(title: "Get Item Three", notes: "the last detail"),
        ], listName: "Sample"))
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items.last?.title, "Get Item Three")
        XCTAssertEqual(items.last?.notes, "the last detail")
        XCTAssertTrue(items.dropLast().allSatisfy { $0.notes == nil })
    }

    func testAPersonLikeWordInAProductPhraseIsNotMadeAnAssignee() async {
        // The model may not infer one; and when it does not, Swift adds none.
        let engine = ListEngine()
        engine.creates = [BulkDecisionValue(action: "create", tasks: [TaskDraftValue(title: "Get Rose Water", notes: "the small bottle")], listName: "Sample")]
        let turns = make(engine)
        _ = await turns.decide(utterance: "Add Sample list. Rose water, the small bottle.", now: now, final: true)
        XCTAssertNil(turns.state.drafts.items.first?.assignee)
        XCTAssertEqual(turns.state.drafts.items.first?.title, "Get Rose Water")
        XCTAssertEqual(turns.state.drafts.items.first?.notes, "the small bottle")
    }

    func testThreeItemsAreNotCombinedIntoOneTask() {
        let items = decoded(BulkDecisionValue(action: "create", tasks: [
            TaskDraftValue(title: "Get Item One"), TaskDraftValue(title: "Get Item Two"), TaskDraftValue(title: "Get Item Three"),
        ], listName: "Sample"))
        XCTAssertEqual(items.count, 3, "Swift never combines items that differ")
        XCTAssertFalse(items.contains { $0.title.lowercased().contains(" and ") })
    }

    func testAnExplicitRequestForOneCombinedTaskIsKept() {
        let items = decoded(BulkDecisionValue(action: "create", tasks: [TaskDraftValue(title: "Get Item One And Item Two")], listName: "Sample"))
        XCTAssertEqual(items.count, 1)
    }

    func testRoutinesInAListAreOnTheListToo() {
        let items = decoded(BulkDecisionValue(action: "create", routines: [RoutineDraftValue.daily("Check Item")], listName: "Sample"))
        XCTAssertEqual(items.first?.kind, .routine)
        XCTAssertEqual(items.first?.listName, "Sample")
    }

    // MARK: listName is optional and never comes from anywhere else

    func testNoListNameMeansNoList() {
        let blank = decoded(BulkDecisionValue(action: "create", tasks: [TaskDraftValue(title: "Get Item One", category: "Shopping")]))
        XCTAssertNil(blank[0].listName)
        let spaces = decoded(BulkDecisionValue(action: "create", tasks: [TaskDraftValue(title: "Get Item One")], listName: "   "))
        XCTAssertNil(spaces[0].listName, "a blank list name is no list")
        XCTAssertEqual(blank[0].categoryName, "Shopping")
    }

    func testTheListNameIsTidiedButKeepsTheUsersSpelling() {
        let items = decoded(BulkDecisionValue(action: "create", tasks: [TaskDraftValue(title: "Get Item One")], listName: "  My   Sample List "))
        XCTAssertEqual(items.first?.listName, "My Sample List")
    }

    func testAnItemsOwnListIsNotOverwritten() {
        // Items added to a draft elsewhere keep what they have.
        var item = DraftItem(title: "Get Item One")
        item.listName = "Other"
        XCTAssertEqual(item.listName, "Other")
    }

    // MARK: answer is empty for create

    func testAnAnswerBesideACreateIsNeverShownAndTheDraftsAreStillProposed() async {
        let engine = ListEngine()
        engine.creates = [BulkDecisionValue(action: "create", tasks: [TaskDraftValue(title: "Get Item One"), TaskDraftValue(title: "Get Item Two")],
                                            answer: "Sample list created with the items.", listName: "Sample")]
        let turns = make(engine)
        let result = await turns.decide(utterance: "Add Sample list. Item one. Item two.", now: now, final: true)
        guard let p = proposal(result) else { return }
        XCTAssertFalse((p.reply ?? "").contains("created"), "the app says what happened, never the model")
        XCTAssertFalse((p.prompt ?? "").contains("created"))
        XCTAssertEqual(turns.state.drafts.items.count, 2)
    }

    func testAnAnswerIsStillReadForAnUnrelatedTurn() {
        let result = BulkValidator.decode(BulkDecisionValue(action: "unrelated", answer: "A short reply."), context: ValidationContext())
        XCTAssertEqual(result, .unrelated("A short reply."))
    }

    // MARK: Approval makes the list; nothing before

    func testTheListIsMadeOnlyWhenTheUserApprovesAndEveryItemPointsAtIt() async {
        let (store, defaults, suite) = scratch()
        defer { defaults.removePersistentDomain(forName: suite) }
        let engine = ListEngine()
        engine.creates = [BulkDecisionValue(action: "create", tasks: [
            TaskDraftValue(title: "Get Item One"), TaskDraftValue(title: "Get Item Two"), TaskDraftValue(title: "Get Item Three"),
        ], listName: "Sample List")]
        let turns = make(engine, sink: ScratchSink(store))
        guard let p = proposal(await turns.decide(utterance: "Add Sample List. Item one. Item two. Item three.", now: now, final: true)) else { return }

        XCTAssertTrue(store.profiles.isEmpty, "no list while it is a draft")
        XCTAssertTrue(store.tasks.isEmpty, "no task while it is a draft")
        XCTAssertEqual(p.sections.map(\.listName), ["Sample List"])
        XCTAssertTrue(p.sections.first?.isNew ?? false)

        _ = await approve(p, turns)
        XCTAssertEqual(store.profiles.map(\.name), ["Sample List"], "named as the user said it")
        let list = store.profiles[0]
        XCTAssertEqual(store.tasks.count, 3)
        XCTAssertTrue(store.tasks.allSatisfy { $0.profileID == list.id })
        XCTAssertTrue(store.tasks.allSatisfy { $0.dueDate == nil }, "list items are not due today by default")
        XCTAssertFalse(list.isOrdered, "a list is not a sequence unless the user says so")
    }

    func testAnExistingListIsJoinedNotMadeAgain() async {
        let (store, defaults, suite) = scratch()
        defer { defaults.removePersistentDomain(forName: suite) }
        let existing = store.ensureProfile("Sample List").profile
        let engine = ListEngine()
        engine.creates = [BulkDecisionValue(action: "create", tasks: [TaskDraftValue(title: "Get Item One")], listName: "sample")]
        let turns = make(engine, sink: ScratchSink(store))
        guard let p = proposal(await turns.decide(utterance: "Add to the sample list. Item one.", now: now, final: true)) else { return }
        XCTAssertFalse(p.sections.first?.isNew ?? true, "the card says it joins a list you have")
        _ = await approve(p, turns)
        XCTAssertEqual(store.profiles.count, 1)
        XCTAssertEqual(store.tasks.first?.profileID, existing.id)
        XCTAssertEqual(store.profiles.first?.name, "Sample List", "the saved list's name is not rewritten")
    }

    func testACategoryNeverMakesAList() async {
        let (store, defaults, suite) = scratch()
        defer { defaults.removePersistentDomain(forName: suite) }
        let engine = ListEngine()
        engine.creates = [BulkDecisionValue(action: "create", tasks: [TaskDraftValue(title: "Get Item One", category: "Shopping")])]
        let turns = make(engine, sink: ScratchSink(store))
        guard let p = proposal(await turns.decide(utterance: "Get item one", now: now, final: true)) else { return }
        _ = await approve(p, turns)
        XCTAssertTrue(store.profiles.isEmpty)
        XCTAssertNil(store.tasks.first?.profileID)
    }

    func testNothingIsSavedWithoutApprovalAndNoEmptyStringsAreStored() async {
        let (store, defaults, suite) = scratch()
        defer { defaults.removePersistentDomain(forName: suite) }
        let engine = ListEngine()
        engine.creates = [BulkDecisionValue(action: "create", tasks: [TaskDraftValue(title: "Get Item One", reason: " ", assignee: "  ", notes: "")], listName: "")]
        let turns = make(engine, sink: ScratchSink(store))
        guard let p = proposal(await turns.decide(utterance: "Get item one", now: now, final: true)) else { return }
        XCTAssertTrue(store.tasks.isEmpty)
        _ = await approve(p, turns)
        let t = store.tasks.first
        XCTAssertEqual(store.tasks.count, 1)
        XCTAssertNil(t?.assignee)
        XCTAssertNil(t?.notes)
        XCTAssertNil(t?.reason)
        XCTAssertTrue(store.profiles.isEmpty)
    }

    func testAPartialResultIsStillAReviewCardTheUserCanAddTo() async {
        // No Swift counting of items: a short answer is a draft like any other. Nothing is saved, and the user can say what is missing.
        let engine = ListEngine()
        engine.creates = [BulkDecisionValue(action: "create", tasks: [TaskDraftValue(title: "Get Item One")], listName: "Sample")]
        let sink = InMemorySaveSink()
        let turns = make(engine, sink: sink)
        guard proposal(await turns.decide(utterance: "Add Sample list. Item one. Item two. Item three.", now: now, final: true)) != nil else { return }
        XCTAssertEqual(turns.state.drafts.items.count, 1)
        XCTAssertTrue(sink.tasks.isEmpty)
    }

    // MARK: The instruction text and the schema order

    func testTheInstructionsCarryTheListRulesOnceAndNoExamples() {
        let text = PersistentInstructions.text
        for rule in ["set listName to that list name", "Do not create a task for the list name itself",
                     "Every requested list item belongs in the items array", "Do not infer an assignee from",
                     "answer must be empty"] {
            XCTAssertEqual(text.components(separatedBy: rule).count - 1, 1, rule)
        }
        XCTAssertFalse(text.contains("labels"), "labels no longer exist")
        XCTAssertFalse(text.contains("ONE purchase task"))
        XCTAssertLessThan(text.count, 5_200)
    }

    func testTheModelSchemaHasAListNameAndTheListGuides() throws {
        // The schema's printed form does not keep declaration order (the order is the order of the properties in `BulkAgentDecision`),
        // so only its content is checked.
        #if canImport(FoundationModels)
        guard #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) else { throw XCTSkip("needs iOS 26") }
        let json = String(describing: BulkAgentDecision.generationSchema)
        XCTAssertTrue(json.contains("listName"))
        XCTAssertTrue(json.contains("The user-named list that groups the returned items"))
        XCTAssertFalse(json.contains("ONE purchase task"))
        XCTAssertTrue(json.contains("Must be empty for create, operate, lookup, and clarify"))
        #endif
    }
}
