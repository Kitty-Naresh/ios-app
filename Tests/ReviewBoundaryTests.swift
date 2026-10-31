import XCTest
@testable import Kitty

/// Review is the save boundary. Everything here is SCRIPTED: no model is called. What it checks is the Swift side:
/// a quote that is not in the transcript is a flag on a task that stays in the draft (never a removal), a flagged task is
/// asked about one at a time, nothing is saved without approval, an approval belongs to one draft version, a completed
/// answer is applied once, and success is reported only when something was stored.
/// None of it says that a task is RIGHT. A matching quote proves nothing, and these tests do not claim otherwise.

@MainActor
private final class BoundaryEngine: DecisionProviding {
    var creates: [BulkDecisionValue] = []
    var reviews: [DraftEditValue] = []
    var reviewPrompts: [String] = []
    var extractCalls = 0
    var lastFailure: String?

    func extract(prompt: String, fresh: Bool) async -> BulkDecisionValue? {
        extractCalls += 1
        return creates.isEmpty ? nil : creates.removeFirst()
    }
    func review(prompt: String) async -> DraftEditValue? {
        reviewPrompts.append(prompt)
        return reviews.isEmpty ? nil : reviews.removeFirst()
    }
}

/// A sink whose task store can be made to fail, to check that a failed save is never reported as a save.
@MainActor
private final class FlakySink: SaveSink {
    let inner = InMemorySaveSink()
    var failing = true
    func saveTasks(_ planned: [PlannedTask]) -> [UUID] { failing ? [] : inner.saveTasks(planned) }
    func saveRoutine(_ planned: PlannedTask) -> UUID? { failing ? nil : inner.saveRoutine(planned) }
    func savePlaybook(name: String, category: TaskCategory?, steps: [PlaybookStep], due: Date?) -> (replaced: Bool, created: [UUID]) {
        inner.savePlaybook(name: name, category: category, steps: steps, due: due)
    }
    func playbook(matching title: String) -> Playbook? { nil }
    func addPlaybookTasks(_ playbook: Playbook, due: Date?) -> [UUID] { [] }
    func recordUtterance(_ rawText: String) -> UUID? { inner.recordUtterance(rawText) }
    func link(_ taskIDs: [UUID], to utteranceID: UUID) { inner.link(taskIDs, to: utteranceID) }
    func finishSaving(routineIDs: Set<UUID>) async -> [UUID] { [] }
}

@MainActor
final class ReviewBoundaryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_793_000_000)
    /// The sentence of the trace this was built from. Item 1 quotes all of it (a match); items 2 and 3 stitch the lead-in onto their
    /// own clause, which is not an unbroken run of what was said.
    private let sentence = "My friends are visiting — I need to prepare the room, order food from Blinkit , book a cab"

    private func three(allFail: Bool = false) -> BulkDecisionValue {
        BulkDecisionValue(action: "create", tasks: [
            TaskDraftValue(title: "prepare the room", heardAs: allFail ? "get the guest room ready" : sentence),
            TaskDraftValue(title: "order food from Blinkit", heardAs: "My friends are visiting — I need to order food from Blinkit"),
            TaskDraftValue(title: "book a cab", heardAs: "My friends are visiting — I need to book a cab"),
        ])
    }

    private func make(_ engine: BoundaryEngine, sink: SaveSink, saved: [SavedKey] = []) -> VoiceTurnManager {
        VoiceTurnManager(engine: engine, sink: sink, knownCategories: { [] }, knownAssignees: { [] },
                         savedTasks: { saved })
    }

    private func proposal(_ result: TurnResult, file: StaticString = #filePath, line: UInt = #line) -> Proposal? {
        guard case .proposal(let p) = result else { XCTFail("expected a card, got \(result)", file: file, line: line); return nil }
        return p
    }

    /// What Save does on the screen: the confirmation lets one approval through, then the card's apply runs.
    private func save(_ p: Proposal, _ turns: VoiceTurnManager) async -> AgentReply? {
        guard turns.state.confirmation.consume(p.id) else { return nil }
        return await p.apply()
    }

    private func flagged(_ turns: VoiceTurnManager) -> [String] { turns.state.drafts.ordered.filter(\.quoteUnverified).map(\.title) }

    // MARK: 1 and 2. Imperfect quotes never remove a task

    func testThreeRequestedTasksWithTwoImperfectQuotesAreAllInTheDraft() async {
        let engine = BoundaryEngine(), sink = InMemorySaveSink()
        engine.creates = [three()]
        let turns = make(engine, sink: sink)
        guard let p = proposal(await turns.decide(utterance: sentence, now: now, final: true)) else { return }

        XCTAssertEqual(Set(turns.state.drafts.items.map(\.title)), ["prepare the room", "order food from Blinkit", "book a cab"])
        XCTAssertEqual(p.rows.count, 3, "the card must show every task")
        XCTAssertEqual(p.title, "Save 3 tasks")
        XCTAssertEqual(Set(flagged(turns)), ["order food from Blinkit", "book a cab"])
        XCTAssertFalse(turns.state.drafts.items.first { $0.title == "prepare the room" }?.quoteUnverified ?? true)
        XCTAssertEqual(engine.extractCalls, 1, "a quote mismatch must not retry the model")
        XCTAssertTrue(sink.tasks.isEmpty, "nothing is saved without approval")
        // The flagged rows say the quote is unverified; none shows the model's wording as if it were speech.
        for row in p.rows where flagged(turns).contains(row.title) {
            XCTAssertTrue(row.tags.contains { $0.text.hasPrefix("Quote unverified") }, row.title)
            XCTAssertFalse(row.tags.contains { $0.text.contains("I need to") }, "the unverified quote is shown as speech on \(row.title)")
        }
        // One targeted question about one flagged task, not a generic save prompt.
        XCTAssertNotNil(p.flagQuestionItemID)
        XCTAssertTrue((p.prompt ?? "").hasPrefix("Should I include ‘"), p.prompt ?? "")
        XCTAssertFalse((p.prompt ?? "").lowercased().contains("should i save"))
    }

    func testWhenEveryQuoteFailsTheSamePolicyApplies() async {
        let engine = BoundaryEngine()
        engine.creates = [BulkDecisionValue(action: "create", tasks: [
            TaskDraftValue(title: "prepare the room", heardAs: "get the guest room ready"),
            TaskDraftValue(title: "order food from Blinkit", heardAs: "get dinner delivered"),
            TaskDraftValue(title: "book a cab", heardAs: "arrange a taxi"),
        ])]
        let turns = make(engine, sink: InMemorySaveSink())
        guard let p = proposal(await turns.decide(utterance: sentence, now: now, final: true)) else { return }
        XCTAssertEqual(turns.state.drafts.items.count, 3)
        XCTAssertEqual(flagged(turns).count, 3)
        XCTAssertEqual(p.rows.count, 3)
        XCTAssertTrue(turns.state.drafts.items.allSatisfy { !$0.advisories.contains("Not found in what you said") },
                      "the old all-fail special case is gone")
    }

    func testAnItemWithNoQuoteMakesNoClaimAndIsNotFlagged() async {
        let engine = BoundaryEngine()
        engine.creates = [BulkDecisionValue(action: "create", tasks: [TaskDraftValue(title: "book a cab")])]
        let turns = make(engine, sink: InMemorySaveSink())
        guard let p = proposal(await turns.decide(utterance: "book a cab", now: now, final: true)) else { return }
        XCTAssertTrue(flagged(turns).isEmpty)
        XCTAssertNil(p.flagQuestionItemID)
    }

    // MARK: 3. A matching quote is not trust

    func testAMatchingQuoteWithTheWrongTaskIsNotTrusted() async {
        let engine = BoundaryEngine(), sink = InMemorySaveSink()
        // The quote is exactly in the words; the task made from it is wrong.
        engine.creates = [BulkDecisionValue(action: "create", tasks: [TaskDraftValue(title: "Book a flight to Delhi", heardAs: "book a cab")])]
        let turns = make(engine, sink: sink)
        guard let p = proposal(await turns.decide(utterance: "I need to book a cab", now: now, final: true)) else { return }
        let item = turns.state.drafts.items[0]
        XCTAssertFalse(item.quoteUnverified)
        XCTAssertFalse(item.reviewed, "a match must not mark anything as reviewed")
        XCTAssertFalse(p.rows[0].tags.contains { $0.text.lowercased().contains("verified") }, "a match is not shown as verified")
        XCTAssertTrue(sink.tasks.isEmpty, "approval is still needed")
        XCTAssertTrue((p.prompt ?? "").lowercased().contains("save"), "the task still goes to the user for approval")
    }

    // MARK: 4, 5 and 6. Excluding, including and not approving

    func testAFlaggedTaskTheUserExcludesIsNotSaved() async {
        let engine = BoundaryEngine(), sink = InMemorySaveSink()
        engine.creates = [three()]
        let turns = make(engine, sink: sink)
        guard var p = proposal(await turns.decide(utterance: sentence, now: now, final: true)) else { return }
        let asked = turns.state.drafts.item(id: p.flagQuestionItemID ?? UUID())?.title ?? ""
        XCTAssertFalse(asked.isEmpty)
        guard let after = proposal(await turns.decide(utterance: "no", now: now, final: true)) else { return }
        p = after
        XCTAssertFalse(turns.state.drafts.items.contains { $0.title == asked })
        XCTAssertEqual(turns.state.drafts.items.count, 2)
        XCTAssertTrue(sink.tasks.isEmpty, "answering the question saves nothing")
        // Resolve the other flagged item by including it, then save.
        while p.flagQuestionItemID != nil {
            guard let next = proposal(await turns.decide(utterance: "yes", now: now, final: true)) else { return }
            p = next
        }
        let reply = await save(p, turns)
        XCTAssertEqual(reply?.didAdd, true)
        XCTAssertEqual(sink.tasks.count, 2)
        XCTAssertFalse(sink.tasks.contains { $0.title == asked }, "the excluded task was saved")
    }

    func testAFlaggedTaskTheUserIncludesIsSavedOnce() async {
        let engine = BoundaryEngine(), sink = InMemorySaveSink()
        engine.creates = [three()]
        let turns = make(engine, sink: sink)
        guard var p = proposal(await turns.decide(utterance: sentence, now: now, final: true)) else { return }
        var asked: [String] = []
        while let id = p.flagQuestionItemID {
            asked.append(turns.state.drafts.item(id: id)?.title ?? "")
            guard let next = proposal(await turns.decide(utterance: "yes", now: now, final: true)) else { return }
            p = next
        }
        XCTAssertEqual(Set(asked), ["order food from Blinkit", "book a cab"], "one question per flagged task, each asked once")
        XCTAssertTrue(sink.tasks.isEmpty, "a yes to a question about one task saves nothing")
        XCTAssertTrue((p.prompt ?? "").hasSuffix("Should I save these?"), p.prompt ?? "")
        XCTAssertTrue(turns.state.drafts.items.filter(\.quoteUnverified).allSatisfy(\.reviewed))

        // The save: a "yes" then runs once, and a second "yes" or tap saves nothing more.
        guard let go = proposal(await turns.decide(utterance: "yes", now: now, final: true)) else { return }
        XCTAssertTrue(go.runImmediately)
        let first = await save(go, turns)
        XCTAssertEqual(first?.didAdd, true)
        XCTAssertEqual(Set(sink.tasks.map(\.title)), ["prepare the room", "order food from Blinkit", "book a cab"])
        let second = await save(go, turns)
        XCTAssertNil(second, "a second approval must not run")
        let direct = await go.apply()
        XCTAssertEqual(direct.message, "Already saved.")
        XCTAssertEqual(sink.tasks.count, 3, "saved once")
    }

    func testWithoutApprovalNothingIsSaved() async {
        let engine = BoundaryEngine(), sink = InMemorySaveSink()
        engine.creates = [three()]
        let turns = make(engine, sink: sink)
        guard var p = proposal(await turns.decide(utterance: sentence, now: now, final: true)) else { return }
        // Include one flagged task; still no save.
        if let next = proposal(await turns.decide(utterance: "yes", now: now, final: true)) { p = next }
        _ = p
        XCTAssertTrue(sink.tasks.isEmpty)
        XCTAssertTrue(sink.routines.isEmpty)
        XCTAssertTrue(sink.utterances.isEmpty, "the words are kept only when Save runs")
        XCTAssertEqual(turns.state.drafts.items.count, 3)
    }

    // MARK: 7. An approval belongs to one draft version

    func testAnEditedDraftCannotBeSavedByTheOldApproval() async {
        let engine = BoundaryEngine()
        engine.creates = [three()]
        let turns = make(engine, sink: InMemorySaveSink())
        guard let old = proposal(await turns.decide(utterance: sentence, now: now, final: true)) else { return }
        XCTAssertTrue(old.approves(currentDraftVersion: turns.state.drafts.version))

        // By hand: the title of one task changes.
        var item = turns.state.drafts.ordered[0]
        item.title += " tonight"
        guard let edited = turns.editDraft(item) else { return XCTFail("no card after the edit") }
        XCTAssertFalse(old.approves(currentDraftVersion: turns.state.drafts.version), "the old approval still covers the changed draft")
        XCTAssertTrue(edited.approves(currentDraftVersion: turns.state.drafts.version))

        // Including a flagged task is also a change: an approval given before it does not carry over.
        let before = edited
        guard let id = before.flagQuestionItemID, let after = turns.includeFlaggedItem(id: id) else { return XCTFail("nothing to include") }
        XCTAssertFalse(before.approves(currentDraftVersion: turns.state.drafts.version))
        XCTAssertTrue(after.approves(currentDraftVersion: turns.state.drafts.version))
        XCTAssertNotEqual(before.id, after.id)
    }

    // MARK: 8. A completed answer is applied once

    func testACompletedAnswerIsAppliedOncePerRequest() async {
        let engine = BoundaryEngine()
        engine.creates = [three()]
        let turns = make(engine, sink: InMemorySaveSink())
        _ = await turns.decide(utterance: sentence, now: now, final: true)
        XCTAssertEqual(turns.state.drafts.items.count, 3)
        let t = turns.ticket
        XCTAssertEqual(turns.commit(t), .repeated, "this request was already applied")

        // A fresh request claims the draft; the old one is then superseded, and a draft that moved on is not overwritten.
        let stale = VoiceTurnManager.TurnTicket(draftVersion: turns.state.drafts.version - 1)
        XCTAssertNotNil(turns.commit(stale))
        XCTAssertEqual(turns.state.drafts.items.count, 3, "a denied answer leaves the draft as it was")
    }

    func testIdenticalCopiesAreCombinedButDistinctOccurrencesAndDifferentDatesAreKept() async {
        let engine = BoundaryEngine()
        engine.creates = [
            // The model wrote the same item three times.
            BulkDecisionValue(action: "create", tasks: Array(repeating: TaskDraftValue(title: "Buy milk", heardAs: "buy milk"), count: 3)),
        ]
        var turns = make(engine, sink: InMemorySaveSink())
        _ = await turns.decide(utterance: "buy milk", now: now, final: true)
        XCTAssertEqual(turns.state.drafts.items.count, 1)
        XCTAssertTrue(turns.state.drafts.items[0].advisories.contains("Combined 3 identical items"))

        // Distinct occurrences the user asked for are kept.
        let engine2 = BoundaryEngine()
        engine2.creates = [BulkDecisionValue(action: "create", tasks: [
            TaskDraftValue(title: "Buy milk", heardAs: "buy milk"),
            TaskDraftValue(title: "Buy milk", heardAs: "buy milk", distinctBecause: "twice"),
        ])]
        turns = make(engine2, sink: InMemorySaveSink())
        _ = await turns.decide(utterance: "buy milk twice", now: now, final: true)
        XCTAssertEqual(turns.state.drafts.items.count, 2)

        // Same title, different days: two tasks.
        let engine3 = BoundaryEngine()
        engine3.creates = [BulkDecisionValue(action: "create", tasks: [
            TaskDraftValue(title: "Pay rent", dueDate: "2026-11-01", heardAs: "pay rent on the first of November"),
            TaskDraftValue(title: "Pay rent", dueDate: "2026-12-01", heardAs: "pay rent on the first of December"),
        ])]
        turns = make(engine3, sink: InMemorySaveSink())
        _ = await turns.decide(utterance: "pay rent on the first of November and pay rent on the first of December", now: now, final: true)
        XCTAssertEqual(turns.state.drafts.items.count, 2)
        XCTAssertEqual(Set(turns.state.drafts.items.compactMap(\.due)).count, 2, "the two dates must both survive")
    }

    func testANewRequestThatMatchesASavedTaskIsShownAsAPossibleDuplicateNotSuppressed() async {
        let engine = BoundaryEngine()
        engine.creates = [BulkDecisionValue(action: "create", tasks: [TaskDraftValue(title: "Buy milk", heardAs: "buy milk")])]
        let turns = make(engine, sink: InMemorySaveSink(), saved: [SavedKey(title: Words.key("Buy milk"))])
        guard let p = proposal(await turns.decide(utterance: "buy milk", now: now, final: true)) else { return }
        XCTAssertEqual(turns.state.drafts.items.count, 1)
        XCTAssertTrue(p.rows[0].tags.contains { $0.text == "You already have this saved" })
    }

    // MARK: 10. A correction fixes one item and leaves the rest

    func testACorrectionChangesOnlyTheNamedItem() async {
        let engine = BoundaryEngine()
        engine.creates = [BulkDecisionValue(action: "create", tasks: [
            TaskDraftValue(title: "Get Cetaphil Body Lotion", heardAs: "Cetaphil body lotion"),
            TaskDraftValue(title: "Get Sip Curl", heardAs: "sip curl"),
        ])]
        let turns = make(engine, sink: InMemorySaveSink())
        let said = "Cetaphil body lotion and sip curl"
        _ = await turns.decide(utterance: said, now: now, final: true)
        let before = turns.state.drafts.items
        let lotion = before.first { $0.title == "Get Cetaphil Body Lotion" }!
        let curl = before.first { $0.title == "Get Sip Curl" }!

        engine.reviews = [DraftEditValue(action: "change", edits: [DraftEditOpValue(refs: [curl.ref], title: "Get Cipcal")])]
        _ = await turns.decide(utterance: said + " It's Cipcal, not sip curl.", now: now, final: true)
        let after = turns.state.drafts.items
        XCTAssertEqual(after.count, 2)
        XCTAssertEqual(after.first { $0.ref == curl.ref }?.title, "Get Cipcal")
        XCTAssertEqual(after.first { $0.ref == lotion.ref }, lotion, "an unrelated item changed")

        // A contradictory answer is not applied and the card does not claim success.
        let snapshot = turns.state.drafts.items
        engine.reviews = [DraftEditValue(action: "change", edits: [
            DraftEditOpValue(refs: [curl.ref], title: "Get Cipcal Syrup"), DraftEditOpValue(refs: [curl.ref], remove: true)])]
        guard let p = proposal(await turns.decide(utterance: said + " It's Cipcal, not sip curl. Change it again.", now: now, final: true)) else { return }
        XCTAssertEqual(turns.state.drafts.items, snapshot)
        XCTAssertNotNil(p.recovery)
        XCTAssertFalse((p.prompt ?? "").lowercased().contains("should i save"))
    }

    // MARK: What the model is sent

    func testTheModelIsNeverToldAnUnverifiedQuoteAsWhatTheUserSaid() async {
        let engine = BoundaryEngine()
        engine.creates = [three()]
        let turns = make(engine, sink: InMemorySaveSink())
        _ = await turns.decide(utterance: sentence, now: now, final: true)
        engine.reviews = [DraftEditValue(action: "answer", reply: "Three tasks.")]
        _ = await turns.decide(utterance: "how many are there", now: now, final: true)
        let prompt = engine.reviewPrompts.last ?? ""
        XCTAssertTrue(prompt.contains("quote unverified"), prompt)
        XCTAssertFalse(prompt.contains("I need to order food from Blinkit\""), "an unverified quote is given back as speech: \(prompt)")
    }

    // MARK: 11. Success is reported only when something was stored

    func testAFailedSaveIsNotReportedAsASaveAndCanBeApprovedAgain() async {
        let engine = BoundaryEngine(), sink = FlakySink()
        engine.creates = [BulkDecisionValue(action: "create", tasks: [
            TaskDraftValue(title: "Buy milk", heardAs: "buy milk"), TaskDraftValue(title: "Call mom", heardAs: "call mom")])]
        let turns = make(engine, sink: sink)
        guard let p = proposal(await turns.decide(utterance: "buy milk and call mom", now: now, final: true)) else { return }

        let failed = await save(p, turns)
        XCTAssertEqual(failed?.didAdd, false)
        XCTAssertEqual(failed?.report?.persistenceFailed, true)
        XCTAssertEqual(failed?.report?.savedCount, 0)
        XCTAssertFalse((failed?.message ?? "").hasPrefix("Saved"), failed?.message ?? "")
        XCTAssertTrue((failed?.message ?? "").contains("couldn't save"), failed?.message ?? "")
        XCTAssertEqual(turns.state.drafts.items.count, 2, "the draft is kept")

        // The same approval can be given once more, and then stores once.
        turns.state.confirmation.rearm(p.id)
        sink.failing = false
        let again = await save(p, turns)
        XCTAssertEqual(again?.didAdd, true)
        XCTAssertEqual(sink.inner.tasks.map(\.title).sorted(), ["Buy milk", "Call mom"])
        let third = await save(p, turns)
        XCTAssertNil(third)
        XCTAssertEqual(sink.inner.tasks.count, 2)
    }

    func testAnApprovedRoutineThatMatchesASavedOneIsSavedNotSuppressed() async {
        let engine = BoundaryEngine(), sink = InMemorySaveSink()
        engine.creates = [BulkDecisionValue(action: "create", routines: [.daily("Water plants", schedule: "every day")])]
        let turns = make(engine, sink: sink, saved: [SavedKey(title: Words.key("Water plants"), schedule: "every day")])
        guard let p = proposal(await turns.decide(utterance: "water plants every day", now: now, final: true)) else { return }
        XCTAssertTrue(p.rows[0].tags.contains { $0.text == "You already have this saved" }, "the card warns before approval")
        let reply = await save(p, turns)
        XCTAssertEqual(reply?.didAdd, true)
        XCTAssertEqual(sink.routines.count, 1)
    }

    // MARK: 12. The old gate is gone

    func testNoHardQuoteGateIsLeftInTheSource() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        for name in ["Agent.swift", "BulkAgent.swift", "ConversationMode.swift"] {
            guard let text = try? String(contentsOf: root.appendingPathComponent(name), encoding: .utf8) else {
                throw XCTSkip("the source is not readable from the test host")
            }
            XCTAssertFalse(text.contains("splitByQuote"), "\(name) still has the quote gate")
            XCTAssertFalse(text.contains("addUnheard"), "\(name) still keeps an unheard list")
            XCTAssertFalse(text.contains("Not in what you said"), "\(name) still shows the unheard list")
        }
    }
}
