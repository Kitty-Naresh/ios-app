import XCTest
@testable import Kitty

/// A model that answers "show everything" to anything, the way the real one did for "I don't know".
@MainActor
private final class AlwaysViewEngine: DecisionProviding {
    private(set) var calls = 0
    func decide(prompt: String) async -> AgentDecisionValue? {
        calls += 1
        return AgentDecisionValue(action: "view_tasks")
    }
}

/// A model that answers with an action Kitty has never heard of.
@MainActor
private final class UnknownActionEngine: DecisionProviding {
    func decide(prompt: String) async -> AgentDecisionValue? { AgentDecisionValue(action: "do_something_else") }
}

/// A model that answers with nothing at all (empty action, not waiting).
@MainActor
private final class EmptyActionEngine: DecisionProviding {
    func decide(prompt: String) async -> AgentDecisionValue? { AgentDecisionValue(action: "") }
}

/// Regression: "I need to…" -> "What would you like the task to be?" -> "I don't know" showed every task.
/// A hesitation is not a request: Kitty says it is unclear, that she did nothing, and what she can do.
@MainActor
final class UnclearAnswerTests: XCTestCase {
    private let nonAnswers = ["I don't know", "no idea", "I'm not sure", "nothing", "don't know", "I dunno",
                              "um I don't know what", "I don’t know", "Hmm, I'm not sure.", "I have no idea"]

    private func manager(_ engine: DecisionProviding, fallback: Bool = true) -> VoiceTurnManager {
        let m = VoiceTurnManager(engine: engine, sink: InMemorySaveSink(), knownCategories: { [] }, knownAssignees: { [] })
        m.ruleFallbackEnabled = fallback
        return m
    }

    /// The reply is the plain "unclear, nothing done, here is what I do" line, and nothing is shown or added.
    private func assertUnclearReply(_ r: TurnResult, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        guard case .reply(let reply) = r else {
            return XCTFail("\(label): expected a plain reply, got \(VoiceTurnManager.describe(r))", file: file, line: line)
        }
        XCTAssertNil(reply.spec, "\(label): no list may be shown", file: file, line: line)
        XCTAssertFalse(reply.didAdd, label, file: file, line: line)
        XCTAssertFalse(reply.didChange, label, file: file, line: line)
        XCTAssertTrue(reply.created.isEmpty, label, file: file, line: line)
        XCTAssertTrue(reply.message.contains("not sure"), "\(label): says it is unclear: \(reply.message)", file: file, line: line)
        XCTAssertTrue(reply.message.contains("haven't done anything"), "\(label): says nothing was done: \(reply.message)", file: file, line: line)
        XCTAssertTrue(reply.message.contains("I'm Kitty, your house help"), label, file: file, line: line)
        XCTAssertTrue(reply.message.contains("add tasks"), label, file: file, line: line)
        XCTAssertTrue(reply.message.contains("organise them"), label, file: file, line: line)
        XCTAssertTrue(reply.message.contains("read them back"), label, file: file, line: line)
    }

    // MARK: The exact bug

    func testNudgeThenEachNonAnswerWhenTheModelWouldListEverything() async {
        for answer in nonAnswers {
            let engine = AlwaysViewEngine()
            let m = manager(engine)
            XCTAssertEqual(m.nudgeQuestion(for: "I need to"), "What would you like the task to be?", answer)
            XCTAssertEqual(m.state.phase, .awaitingClarification, answer)
            let r = await m.decide(utterance: answer, final: true)
            assertUnclearReply(r, answer)
            XCTAssertNil(m.state.lastView, "\(answer): nothing to narrow later")
            XCTAssertNil(m.state.clarify.lastQuestion, "\(answer): the pending question is cleared")
            XCTAssertNil(m.state.clarification, answer)
            XCTAssertNotEqual(m.state.phase, .awaitingClarification, answer)
            XCTAssertEqual(engine.calls, 0, "\(answer): the model is not even asked")
        }
    }

    func testNudgeThenEachNonAnswerWithNoModelAtAll() async {
        for answer in nonAnswers {
            let m = manager(NoModelEngine())
            XCTAssertEqual(m.nudgeQuestion(for: "I need to"), "What would you like the task to be?", answer)
            assertUnclearReply(await m.decide(utterance: answer, final: true), answer)
            XCTAssertNil(m.state.lastView, answer)
        }
    }

    func testNudgeThenEachNonAnswerThroughTheScriptedModel() async {
        for answer in nonAnswers {
            let m = manager(ScriptedEngine([AgentDecisionValue(action: "view_tasks"), AgentDecisionValue(action: "view_tasks")]))
            _ = m.nudgeQuestion(for: "I need to")
            assertUnclearReply(await m.decide(utterance: answer), answer)
        }
    }

    func testTheNextTurnStartsFresh() async {
        let m = manager(NoModelEngine())
        _ = m.nudgeQuestion(for: "I need to")
        assertUnclearReply(await m.decide(utterance: "I don't know", final: true), "first")
        XCTAssertEqual(m.state.clarify.rounds, 0)
        XCTAssertNil(m.state.clarify.lastQuestion)
        XCTAssertEqual(m.state.pendingTitles, [])
        // asking again is the same plain answer, not a repeat of the old question and not a list
        assertUnclearReply(await m.decide(utterance: "no idea", final: true), "second")
        // and a real question is answered as a fresh request
        let r = await m.decide(utterance: "show my tasks", final: true)
        guard case .reply(let reply) = r else { return XCTFail("expected a list reply") }
        XCTAssertNotNil(reply.spec)
    }

    func testNeverMindKeepsItsOwnReply() async {
        let m = manager(NoModelEngine())
        _ = m.nudgeQuestion(for: "I need to")
        guard case .reply(let r) = await m.decide(utterance: "never mind", final: true) else { return XCTFail("expected a reply") }
        XCTAssertEqual(r.message, "Okay, never mind.")
        XCTAssertFalse(r.didAdd)
    }

    // MARK: Standalone

    func testAStandaloneNonAnswerWithNothingPending() async {
        for answer in nonAnswers {
            let engine = AlwaysViewEngine()
            let m = manager(engine)
            assertUnclearReply(await m.decide(utterance: answer, final: true), answer)
            XCTAssertEqual(engine.calls, 0, answer)
        }
    }

    func testANonAnswerNeverTouchesAPendingDraft() async {
        // Something is waiting for a yes: a hesitation is not a reason to drop it or to claim nothing is happening.
        let m = manager(ScriptedEngine([AgentDecisionValue(action: "create_task", title: "Buy milk")]))
        let first = await m.decide(utterance: "buy milk", final: true)
        guard case .proposal = first else { return XCTFail("expected a preview, got \(VoiceTurnManager.describe(first))") }
        let r = await m.decide(utterance: "I don't know", final: true)
        if case .reply(let reply) = r { XCTAssertNotEqual(reply.message, UnclearAnswer.message) }
        XCTAssertNotNil(m.state.pendingProposal ?? (r.isProposal ? nil : nil) ?? m.state.pendingProposal, "the preview is still waiting")
    }

    // MARK: The general principle

    func testAViewActionFromAnUtteranceWithNoQueryIntentIsNotAList() async {
        for text in ["banana pancakes", "purple monkey", "blue"] {
            let m = manager(AlwaysViewEngine())
            assertUnclearReply(await m.decide(utterance: text, final: true), text)
            XCTAssertNil(m.state.lastView, text)
        }
    }

    func testAnUnknownOrEmptyActionIsNotAList() async {
        for engine: DecisionProviding in [UnknownActionEngine(), EmptyActionEngine()] {
            let m = manager(engine)
            assertUnclearReply(await m.decide(utterance: "banana pancakes", final: true), "banana pancakes")
        }
    }

    func testTheRulePathNeverListsEverythingForAnUnclearUtterance() async {
        // The rule router answers "ask" for a question mark. With no query words that is still not a request to see tasks.
        let r = await TaskAgent.propose("hmm?")
        if case .reply(let reply) = r { XCTAssertNil(reply.spec, "no list for a bare hesitation") }
    }

    // MARK: Real requests still work

    func testShowMyTasksStillListsThem() async {
        let m = manager(ScriptedEngine([AgentDecisionValue(action: "view_tasks")]))
        let r = await m.decide(utterance: "show my tasks", final: true)
        guard case .reply(let reply) = r else { return XCTFail("expected a list, got \(VoiceTurnManager.describe(r))") }
        XCTAssertNotNil(reply.spec, "the list is shown")
        XCTAssertNotEqual(reply.message, UnclearAnswer.message)
        XCTAssertNotNil(m.state.lastView)
    }

    func testShowMyTasksStillListsThemWithoutTheModel() async {
        let m = manager(NoModelEngine())
        let r = await m.decide(utterance: "show my tasks", final: true)
        guard case .reply(let reply) = r else { return XCTFail("expected a list, got \(VoiceTurnManager.describe(r))") }
        XCTAssertNotNil(reply.spec)
    }

    func testOtherReadBackRequestsStillList() async {
        for text in ["what are my tasks for today", "read my tasks back to me", "tell me what's overdue", "do I have anything left"] {
            let m = manager(ScriptedEngine([AgentDecisionValue(action: "view_tasks")]))
            guard case .reply(let reply) = await m.decide(utterance: text, final: true) else { return XCTFail(text) }
            XCTAssertNotNil(reply.spec, text)
        }
    }

    // MARK: The recogniser

    func testRecogniserAcceptsHesitations() {
        for s in nonAnswers + ["Nothing.", "No idea!", "um, no idea", "i really don't know", "I'm not sure yet", "I don't know what to say"] {
            XCTAssertTrue(UnclearAnswer.matches(s), s)
        }
    }

    func testRecogniserLeavesRealSpeechAlone() {
        for s in ["never mind", "cancel", "no", "yes", "buy milk", "I don't know, maybe call the plumber", "nothing is due today",
                  "show my tasks", "I need to", "add a task to clean the bathroom", "I don't know the plumber's number, call him"] {
            XCTAssertFalse(UnclearAnswer.matches(s), s)
        }
    }

    func testQueryIntent() {
        for s in ["show my tasks", "what's on today", "read them back", "list everything", "anything overdue", "tasks for tomorrow", "what?"] {
            XCTAssertTrue(UnclearAnswer.hasQueryIntent(s), s)
        }
        for s in ["I don't know", "banana pancakes", "no idea", "nothing"] {
            XCTAssertFalse(UnclearAnswer.hasQueryIntent(s), s)
        }
    }

    func testTheGateLetsANonAnswerThroughInsteadOfHoldingIt() {
        for s in nonAnswers {
            if case .evaluate = VoiceTurnManager.gate(utterance: s, silence: 2, lastActed: "") {} else {
                XCTFail("\(s): the gate should hand it on, not hold it: \(VoiceTurnManager.gate(utterance: s, silence: 2, lastActed: ""))")
            }
        }
    }
}

private extension TurnResult {
    var isProposal: Bool { if case .proposal = self { return true }; return false }
}
