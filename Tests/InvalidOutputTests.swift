import XCTest
@testable import Kitty

/// What happens when the model's answer about a waiting draft cannot be used. Everything here is SCRIPTED: no model is called, so it
/// is fast and exact. What it checks is the Swift side of the rule: an answer that is not usable changes nothing, says so in words,
/// and offers a way on; a usable one is applied once; and nothing is reinterpreted on the model's behalf.
@MainActor
private final class ScriptedEngine: DecisionProviding {
    var creates: [BulkDecisionValue] = []
    var reviews: [DraftEditValue] = []
    var reviewPrompts: [String] = []
    var lastFailure: String?

    func extract(prompt: String, fresh: Bool) async -> BulkDecisionValue? { creates.isEmpty ? nil : creates.removeFirst() }
    func review(prompt: String) async -> DraftEditValue? {
        reviewPrompts.append(prompt)
        return reviews.isEmpty ? nil : reviews.removeFirst()
    }
}

@MainActor
final class InvalidOutputTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_793_000_000)
    private let first = "Cetaphil body lotion and sip curl"

    /// A turn manager with a draft of two items on the card: d1 "Get Cetaphil Body Lotion", d2 "Get Sip Curl".
    private func withDraft() async -> (VoiceTurnManager, ScriptedEngine) {
        let engine = ScriptedEngine()
        engine.creates = [BulkDecisionValue(action: "create", tasks: [
            TaskDraftValue(title: "Get Cetaphil Body Lotion", heardAs: "Cetaphil body lotion"),
            TaskDraftValue(title: "Get Sip Curl", heardAs: "sip curl"),
        ])]
        let turns = VoiceTurnManager(engine: engine, sink: InMemorySaveSink(), knownCategories: { [] }, knownAssignees: { [] }, savedTasks: { [] })
        let result = await turns.decide(utterance: first, now: now, final: true)
        guard case .proposal = result else { XCTFail("the draft was not made: \(result)"); return (turns, engine) }
        XCTAssertEqual(turns.state.drafts.items.map(\.title), ["Get Cetaphil Body Lotion", "Get Sip Curl"])
        return (turns, engine)
    }

    private func said(_ more: String) -> String { first + " " + more }

    private struct Snapshot: Equatable { var titles: [String]; var priorities: [String?]; var refs: [String]; var version: Int }
    private func snapshot(_ turns: VoiceTurnManager) -> Snapshot {
        let d = turns.state.drafts
        return Snapshot(titles: d.ordered.map(\.title), priorities: d.ordered.map(\.priority), refs: d.ordered.map(\.ref), version: d.version)
    }

    /// A rejected answer: the draft, its version and the log of changes are exactly as before, the card says so, and it offers a way on.
    private func assertRejected(_ result: TurnResult, _ turns: VoiceTurnManager, before: Snapshot, mentions: String,
                                file: StaticString = #filePath, line: UInt = #line) {
        guard case .proposal(let p) = result else { return XCTFail("expected a card, got \(result)", file: file, line: line) }
        XCTAssertEqual(snapshot(turns), before, "the draft changed", file: file, line: line)
        XCTAssertNotNil(p.recovery, "no recovery on the card", file: file, line: line)
        let prompt = p.prompt ?? ""
        XCTAssertFalse(prompt.lowercased().contains("should i save"), "the card still asks to save as if it worked: \(prompt)", file: file, line: line)
        XCTAssertTrue(prompt.contains("Nothing changed"), prompt, file: file, line: line)
        XCTAssertTrue(prompt.contains(mentions), "expected '\(mentions)' in: \(prompt)", file: file, line: line)
        XCTAssertFalse((p.recovery?.retryWords ?? "").isEmpty, "nothing to try again", file: file, line: line)
        XCTAssertTrue(turns.log.recentChanges().isEmpty, "a rejected answer was logged as a change", file: file, line: line)
        XCTAssertEqual(p.rows.count, before.titles.count, "the card does not show the list as it was", file: file, line: line)
    }

    // MARK: The trace's own answer

    /// Turn 7 of the supplied trace: an `answer` that also carries edits, removals of the items it edits, an add, a priority set and
    /// cleared together, and an invented repeat. None of it may reach the draft.
    func testTheTraceAnswerThatCarriesChangesIsRejectedWhole() async {
        let (turns, engine) = await withDraft()
        let before = snapshot(turns)
        engine.reviews = [DraftEditValue(
            action: "answer",
            reply: "You want individual tasks: Get Cetaphil body lotion, Get Cipcal, Get teddy bar soap, not a combined list.",
            edits: [
                DraftEditOpValue(refs: ["d1", "d2"], title: "Get Cipcal", priority: "high", clear: ["priority"]),
                DraftEditOpValue(refs: ["d1", "d2"], remove: true),
            ],
            add: [TaskDraftValue(title: "Get Cipcal", heardAs: "sip curl")])]
        let result = await turns.decide(utterance: said("It's Cipcal, not Ciccal."), now: now, final: true)
        assertRejected(result, turns, before: before, mentions: "answered but also tried to change the list")
        if case .proposal(let p) = result {
            XCTAssertEqual(Set(p.recovery?.items.map(\.title) ?? []), Set(["Get Cetaphil Body Lotion", "Get Sip Curl"]), "the items to fix by hand")
            XCTAssertTrue(p.recovery?.retryWords.contains("Cipcal") ?? false)
        }
        // The recap was never made the question the user is expected to answer.
        XCTAssertFalse(turns.state.questionBesidePreview)
        XCTAssertNil(turns.state.clarify.lastQuestion)
        XCTAssertFalse(turns.state.keepQuestionOnNextProposal)
    }

    // MARK: The other invalid shapes

    func testASetAndClearOfTheSameFieldRejectsTheWholeAnswer() async {
        let (turns, engine) = await withDraft()
        let before = snapshot(turns)
        // Entry 1 is fine on its own; entry 2 contradicts itself. Nothing may be applied, not even entry 1.
        engine.reviews = [DraftEditValue(action: "change", edits: [
            DraftEditOpValue(refs: ["d2"], title: "Get Cipcal"),
            DraftEditOpValue(refs: ["d1"], priority: "high", clear: ["priority"]),
        ])]
        let result = await turns.decide(utterance: said("Rename the second one"), now: now, final: true)
        assertRejected(result, turns, before: before, mentions: "set and emptied the same thing")
    }

    func testAnItemBothEditedAndRemovedRejectsTheWholeAnswer() async {
        let (turns, engine) = await withDraft()
        let before = snapshot(turns)
        engine.reviews = [DraftEditValue(action: "change", edits: [
            DraftEditOpValue(refs: ["d2"], title: "Get Cipcal"),
            DraftEditOpValue(refs: ["d2"], remove: true),
        ])]
        let result = await turns.decide(utterance: said("Fix the second"), now: now, final: true)
        assertRejected(result, turns, before: before, mentions: "both changed and removed")
    }

    func testAnUnknownRefRejectsTheWholeAnswer() async {
        let (turns, engine) = await withDraft()
        let before = snapshot(turns)
        engine.reviews = [DraftEditValue(action: "change", edits: [
            DraftEditOpValue(refs: ["d2"], title: "Get Cipcal"),
            DraftEditOpValue(refs: ["d9"], title: "Get Something"),
        ])]
        let result = await turns.decide(utterance: said("Fix it"), now: now, final: true)
        assertRejected(result, turns, before: before, mentions: "isn't on the list")
    }

    func testAnUnknownActionWordIsNotTurnedIntoAChange() async {
        let (turns, engine) = await withDraft()
        let before = snapshot(turns)
        engine.reviews = [DraftEditValue(action: "frobnicate", edits: [DraftEditOpValue(refs: ["d2"], title: "Get Cipcal")])]
        let result = await turns.decide(utterance: said("Fix it"), now: now, final: true)
        assertRejected(result, turns, before: before, mentions: "wasn't one I recognise")
    }

    func testAChangeWithNothingInItIsRejected() async {
        let (turns, engine) = await withDraft()
        let before = snapshot(turns)
        engine.reviews = [DraftEditValue(action: "change")]
        let result = await turns.decide(utterance: said("Change something"), now: now, final: true)
        assertRejected(result, turns, before: before, mentions: "gave no change")
    }

    func testAnUnknownFieldToEmptyIsRejected() async {
        let (turns, engine) = await withDraft()
        let before = snapshot(turns)
        engine.reviews = [DraftEditValue(action: "change", edits: [DraftEditOpValue(refs: ["d1"], clear: ["colour"])])]
        let result = await turns.decide(utterance: said("Clear the colour"), now: now, final: true)
        assertRejected(result, turns, before: before, mentions: "isn't a field")
    }

    func testAClarifyThatIsNotOneQuestionIsNeverStoredAsTheOpenQuestion() async {
        let (turns, engine) = await withDraft()
        let before = snapshot(turns)
        engine.reviews = [DraftEditValue(action: "clarify", reply: "You want individual tasks, not a combined list.")]
        let result = await turns.decide(utterance: said("I want individual tasks"), now: now, final: true)
        assertRejected(result, turns, before: before, mentions: "wasn't one question")
        XCTAssertNil(turns.state.clarify.lastQuestion)
        XCTAssertFalse(turns.state.questionBesidePreview)
    }

    func testAClarifyThatIsOneQuestionStaysOpenBesideTheDraft() async {
        let (turns, engine) = await withDraft()
        let before = snapshot(turns)
        engine.reviews = [DraftEditValue(action: "clarify", reply: "Which one do you mean?")]
        let result = await turns.decide(utterance: said("Change it"), now: now, final: true)
        guard case .proposal(let p) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(snapshot(turns), before)
        XCTAssertNil(p.recovery)
        XCTAssertEqual(turns.state.clarify.lastQuestion, "Which one do you mean?")
        XCTAssertTrue(turns.state.questionBesidePreview, "a real question stays open beside the card")
    }

    func testNoAnswerAtAllKeepsTheDraftAndOffersARetry() async {
        let (turns, engine) = await withDraft()
        let before = snapshot(turns)
        engine.lastFailure = "the model took longer than 25 s, so it was stopped"
        engine.reviews = []
        let result = await turns.decide(utterance: said("Fix the second one"), now: now, final: true)
        assertRejected(result, turns, before: before, mentions: "took longer than 25 s")
    }

    // MARK: A usable answer

    func testAUsableChangeIsAppliedOnceAndRemembersWhereItCameFrom() async {
        let (turns, engine) = await withDraft()
        engine.reviews = [DraftEditValue(action: "change", edits: [DraftEditOpValue(refs: ["d2"], title: "Get Cipcal")])]
        let result = await turns.decide(utterance: said("It's Cipcal"), now: now, final: true)
        guard case .proposal(let p) = result else { return XCTFail("\(result)") }
        XCTAssertNil(p.recovery)
        XCTAssertEqual(turns.state.drafts.ordered.map(\.title).sorted(), ["Get Cetaphil Body Lotion", "Get Cipcal"])
        let fixed = turns.state.drafts.item(ref: "d2")
        XCTAssertEqual(fixed?.history.last?.kind, "renamed")
        XCTAssertEqual(fixed?.history.first?.kind, "created")
        XCTAssertEqual(turns.state.drafts.item(ref: "d1")?.title, "Get Cetaphil Body Lotion")
        XCTAssertEqual(turns.log.recentChanges(), ["Updated get cipcal. (d2)"])
        XCTAssertTrue((p.prompt ?? "").contains("Should I save"))
    }

    func testAnAnswerChangesNothingAndSaysSo() async {
        let (turns, engine) = await withDraft()
        let before = snapshot(turns)
        engine.reviews = [DraftEditValue(action: "answer", reply: "There are two tasks.")]
        let result = await turns.decide(utterance: said("How many are there?"), now: now, final: true)
        guard case .proposal(let p) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(snapshot(turns), before)
        XCTAssertNil(p.recovery)
        XCTAssertEqual(p.reply, "There are two tasks.")
    }

    // MARK: What the model is sent

    func testTheReviewPromptHasTheDraftByRefAndTheLatestWordsOnly() async {
        let (turns, engine) = await withDraft()
        engine.reviews = [DraftEditValue(action: "answer", reply: "Two tasks.")]
        _ = await turns.decide(utterance: said("How many?"), now: now, final: true)
        let prompt = engine.reviewPrompts.last ?? ""
        XCTAssertFalse(prompt.contains("ORIGINAL REQUEST"), prompt)
        XCTAssertFalse(prompt.contains("LINES SO FAR"), prompt)
        XCTAssertTrue(prompt.contains("d1. \"Get Cetaphil Body Lotion\""), prompt)
        XCTAssertTrue(prompt.contains("created in L1 from \"Cetaphil body lotion\""), prompt)
        XCTAssertTrue(prompt.contains("USER: \"How many?\""), prompt)
        // The words of the first turn are not repeated as history: they appear once, in the item's own quote.
        XCTAssertEqual(prompt.components(separatedBy: "Cetaphil body lotion and sip curl").count - 1, 0, prompt)
    }

    func testTheReviewInstructionsDoNotTalkAboutWhatTheSchemaLacks() {
        let text = PersistentInstructions.review
        for word in ["RECENT TASKS", "search", "id from", "saved task", "heardAs"] {
            XCTAssertFalse(text.contains(word), "the review instructions mention '\(word)'")
        }
        XCTAssertTrue(PersistentInstructions.text.contains("RECENT TASKS"), "the extraction instructions keep the saved-task rules")
        XCTAssertTrue(PersistentInstructions.common.contains("overrides"), "the user's grouping must win over the default")
    }

    // MARK: The checks on their own

    func testTheValidatorOnItsOwn() {
        let refs: Set<String> = ["d1", "d2"]
        func problems(_ v: DraftEditValue) -> [DraftReviewValidator.Problem] { DraftReviewValidator.check(v, refs: refs) }
        XCTAssertEqual(problems(DraftEditValue(action: "answer", reply: "Two.")), [])
        XCTAssertEqual(problems(DraftEditValue(action: "unrelated")), [])
        XCTAssertEqual(problems(DraftEditValue(action: "change", edits: [DraftEditOpValue(refs: ["d1"], title: "X")])), [])
        XCTAssertEqual(problems(DraftEditValue(action: "change", edits: [DraftEditOpValue(all: true, clear: ["priority"])])), [])
        XCTAssertEqual(problems(DraftEditValue(action: "change", edits: [DraftEditOpValue(refs: ["d1"], remove: true)])), [])
        XCTAssertEqual(problems(DraftEditValue(action: "answer", reply: "")), [.emptyAnswer])
        XCTAssertEqual(problems(DraftEditValue(action: "change", edits: [DraftEditOpValue(title: "X")])), [.noTarget])
        XCTAssertEqual(problems(DraftEditValue(action: "change", edits: [DraftEditOpValue(refs: ["d1"])])), [.emptyEdit])
        XCTAssertEqual(problems(DraftEditValue(action: "ask", reply: "Which?")), [.unknownAction("ask")])
    }

    func testOneQuestion() {
        for ok in ["Which one?", "What day should it be on?", "Which day, Saturday or Sunday?"] {
            XCTAssertTrue(ClarificationStateManager.isOneQuestion(ok), ok)
        }
        for bad in ["", "?", "You want individual tasks.", "Okay. Which one?", "Which one? And when?", "Which one!", "Which one"] {
            XCTAssertFalse(ClarificationStateManager.isOneQuestion(bad), bad)
        }
    }
}
