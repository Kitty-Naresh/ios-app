import XCTest
@testable import Kitty

@MainActor
final class BargeInTests: XCTestCase {

    // MARK: Stop words

    func testStopPhrasesInterruptAndLeaveNoRequest() {
        for said in ["stop", "Stop.", "okay stop", "Kitty, stop", "hold on", "that's enough", "enough", "wait", "never mind", "pause"] {
            XCTAssertEqual(BargeIn.decide(heard: said, spoken: "You have 3 open tasks. Call the dentist, Pay rent."),
                           .interrupt(rest: ""), said)
        }
    }

    func testWhatFollowsStopIsTheNextPrompt() {
        XCTAssertEqual(BargeIn.decide(heard: "stop, only tomorrow", spoken: "You have 9 open tasks."), .interrupt(rest: "only tomorrow"))
        XCTAssertEqual(BargeIn.decide(heard: "okay stop just the maid", spoken: "You have 9 open tasks."), .interrupt(rest: "just the maid"))
        XCTAssertEqual(BargeIn.decide(heard: "hold on only overdue", spoken: "x y z"), .interrupt(rest: "only overdue"))
    }

    func testWaitInARequestIsNotAStop() {
        // "wait for the plumber" is a task, not a stop (but as plain speech of 2+ words it still counts as speaking).
        BargeIn.anySpeechInterrupts = false
        defer { BargeIn.anySpeechInterrupts = true }
        XCTAssertEqual(BargeIn.decide(heard: "wait for the plumber", spoken: "You have 3 open tasks."), .ignore)
    }

    // MARK: Echo

    func testKittysOwnVoiceIsIgnored() {
        let spoken = "You have 3 open tasks. Call the dentist, Renew passport, Pay rent."
        for echo in ["you have 3 open tasks", "call the dentist renew passport", "Pay rent", "the dentist", "open tasks call"] {
            XCTAssertEqual(BargeIn.decide(heard: echo, spoken: spoken), .ignore, echo)
        }
        XCTAssertEqual(BargeIn.userWords(heard: "you have 3 open tasks stop", spoken: spoken), ["stop"])
    }

    func testRealSpeechInterruptsEvenWhenItSharesAWordWithKitty() {
        let spoken = "You have 3 open tasks tomorrow, Thursday. Call the dentist."
        // Two words that share nothing with her sentence are enough; two that overlap it could be her own voice.
        XCTAssertEqual(BargeIn.decide(heard: "only tomorrow", spoken: spoken), .ignore)
        XCTAssertEqual(BargeIn.decide(heard: "only tomorrow tasks please", spoken: spoken), .interrupt(rest: "only tomorrow tasks please"))
        XCTAssertEqual(BargeIn.decide(heard: "show overdue", spoken: spoken), .interrupt(rest: "show overdue"))
        XCTAssertEqual(BargeIn.decide(heard: "add a task to buy milk", spoken: spoken), .interrupt(rest: "add a task to buy milk"))
    }

    func testOneStrayWordDoesNotInterrupt() {
        XCTAssertEqual(BargeIn.decide(heard: "hmm", spoken: "You have 3 open tasks."), .ignore)
        XCTAssertEqual(BargeIn.decide(heard: "tomorrow", spoken: "Call the dentist."), .ignore)
    }

    func testStopWordsOnlyModeIgnoresOrdinarySpeech() {
        BargeIn.anySpeechInterrupts = false
        defer { BargeIn.anySpeechInterrupts = true }
        XCTAssertEqual(BargeIn.decide(heard: "only tomorrow", spoken: "x"), .ignore)
        XCTAssertEqual(BargeIn.decide(heard: "stop only tomorrow", spoken: "x"), .interrupt(rest: "only tomorrow"))
    }

    // MARK: When Kitty suggests a filter

    private func task(_ title: String, who: String? = nil, category: String? = nil, days: Int = 0) -> TaskItem {
        var t = TaskItem(title: title)
        t.assignee = who
        t.categoryName = category
        t.dueDate = Calendar.current.date(byAdding: .day, value: days, to: Calendar.current.startOfDay(for: .now))
        return t
    }

    func testNoHintForShortOrOneItemLists() {
        let spec = TaskLookupSpec()
        XCTAssertNil(TaskAgent.narrowingHint(for: spec, items: [task("Pay rent")]))
        let eight = (1...8).map { task("T\($0)", who: $0 % 2 == 0 ? "Maid" : nil) }
        XCTAssertNil(TaskAgent.narrowingHint(for: spec, items: eight))
    }

    func testAHintForALongUnfilteredListNamesTheBestSplit() {
        let items = (1...10).map { task("T\($0)", who: $0 <= 5 ? "Maid" : nil, category: "Home") }
        let hint = TaskAgent.narrowingHint(for: TaskLookupSpec(), items: items)
        XCTAssertNotNil(hint)
        XCTAssertTrue(hint?.hasSuffix("?") ?? false)
        XCTAssertTrue(hint?.contains("Househelp's") ?? false, hint ?? "")
    }

    func testNoHintWhenTheListIsAlreadyNarrowed() {
        let items = (1...12).map { task("T\($0)", who: $0 <= 6 ? "Maid" : nil) }
        var byPerson = TaskLookupSpec(); byPerson.assignees = ["Maid"]
        var byDay = TaskLookupSpec(); byDay.day = .today
        var byCategory = TaskLookupSpec(); byCategory.category = .errands
        var overdue = TaskLookupSpec(); overdue.overdueOnly = true
        for spec in [byPerson, byDay, byCategory, overdue] {
            XCTAssertNil(TaskAgent.narrowingHint(for: spec, items: items))
        }
    }

    func testNoHintWhenEveryTaskIsTheSame() {
        let items = (1...12).map { task("T\($0)", category: "Home") }
        XCTAssertNil(TaskAgent.narrowingHint(for: TaskLookupSpec(), items: items))
    }

    func testTheHintIsOfferedOncePerConversation() {
        let m = VoiceTurnManager(engine: ScriptedEngine([]), sink: InMemorySaveSink(), knownCategories: { [] })
        var reply = AgentReply(message: "You have 12 open tasks.", didAdd: false)
        reply.hint = "Want just today's?"
        let first = m.offeringHintOnce(reply)
        XCTAssertEqual(first.message, "You have 12 open tasks. Want just today's?")
        let second = m.offeringHintOnce(reply)
        XCTAssertEqual(second.message, "You have 12 open tasks.")
        XCTAssertNil(second.hint)
        m.state.reset()
        XCTAssertEqual(m.offeringHintOnce(reply).message, first.message, "a new conversation may offer it again")
    }
}

// MARK: - Keeping the mic on

@MainActor
final class MicPolicyTests: XCTestCase {

    func testAStartUpHiccupIsRetriedQuietlyThenGivesUp() {
        XCTAssertEqual(MicPolicy.retryDelay(afterFailure: 0, permanent: false), 0.3)
        XCTAssertEqual(MicPolicy.retryDelay(afterFailure: 1, permanent: false), 0.8)
        XCTAssertEqual(MicPolicy.retryDelay(afterFailure: 2, permanent: false), 1.5)
        XCTAssertNil(MicPolicy.retryDelay(afterFailure: 3, permanent: false), "after three retries, tell the user")
    }

    func testAPermissionProblemIsNeverRetried() {
        XCTAssertNil(MicPolicy.retryDelay(afterFailure: 0, permanent: true))
    }

    func testManyEndingsInARowBackOffInsteadOfGivingUp() {
        XCTAssertEqual(MicPolicy.restartDelay(restartsInWindow: 1), 0)
        XCTAssertEqual(MicPolicy.restartDelay(restartsInWindow: 4), 0)
        XCTAssertGreaterThan(MicPolicy.restartDelay(restartsInWindow: 5), 0)
        XCTAssertLessThanOrEqual(MicPolicy.restartDelay(restartsInWindow: 50), 5)
    }

    private func should(active: Bool = true, micWanted: Bool = true, userMuted: Bool = false, blocked: Bool = false, micOn: Bool = false,
                        isSpeaking: Bool = false, starting: Bool = false, thinking: Bool = false) -> Bool {
        MicPolicy.shouldRestart(active: active, micWanted: micWanted, userMuted: userMuted, blocked: blocked, micOn: micOn,
                                isSpeaking: isSpeaking, starting: starting, thinking: thinking)
    }

    func testTheWatchdogTurnsAnUnexpectedlyOffMicBackOn() {
        XCTAssertTrue(should())
    }

    func testOnlyAnExplicitReasonKeepsTheMicOff() {
        XCTAssertFalse(should(userMuted: true), "you muted it")
        XCTAssertFalse(should(blocked: true), "permission is off")
        XCTAssertFalse(should(micWanted: false), "you typed instead of talking")
        XCTAssertFalse(should(active: false), "the screen is closed")
        XCTAssertFalse(should(micOn: true), "already listening")
        XCTAssertFalse(should(isSpeaking: true), "Kitty is talking, her mic session is separate")
        XCTAssertFalse(should(starting: true), "a start is already under way")
        XCTAssertFalse(should(thinking: true))
    }

    func testRestartingRecognitionNeedsARunningMic() {
        let speech = SpeechRecognizer()
        XCTAssertFalse(speech.restartRecognition(), "nothing is recording: the caller must do a full start")
    }

    func testBreadcrumbsKeepEnoughHistoryToDiagnoseAFailure() {
        Breadcrumb.clear()
        for i in 0..<60 { Breadcrumb.log("step \(i)") }
        XCTAssertEqual(Breadcrumb.lines.count, 40)
        XCTAssertTrue(Breadcrumb.lines.last?.hasSuffix("step 59") ?? false)
        Breadcrumb.clear()
    }
}


// MARK: - Long prompts and Kitty's own voice

@MainActor
final class TurnAccumulatorTests: XCTestCase {

    func testAPartialThatStartsOverKeepsTheEarlierSentence() {
        let first = "I'm working on a project and I would like to create a list of tasks for that project"
        let second = "and the first task is to write a strategy document"
        XCTAssertTrue(TurnAccumulator.isReset(previous: first, new: second))
        let merged = TurnAccumulator.absorb(carry: "", session: first, partial: second)
        XCTAssertTrue(merged.reset)
        XCTAssertEqual(merged.carry, first)
        XCTAssertEqual(merged.session, second)
    }

    func testALongerOrRevisedPartialIsNotAReset() {
        XCTAssertFalse(TurnAccumulator.isReset(previous: "I'm working on a project", new: "I'm working on a project and I would like"))
        XCTAssertFalse(TurnAccumulator.isReset(previous: "im working on a project", new: "I am working on a project and"))
        XCTAssertFalse(TurnAccumulator.isReset(previous: "clean the bathroom", new: "Clean the bath room every Monday"))
        XCTAssertFalse(TurnAccumulator.isReset(previous: "buy milk", new: "by milk and eggs"))
        XCTAssertFalse(TurnAccumulator.isReset(previous: "", new: "hello there"))
        let same = TurnAccumulator.absorb(carry: "earlier", session: "buy milk", partial: "buy milk and eggs")
        XCTAssertFalse(same.reset)
        XCTAssertEqual(same.carry, "earlier")
    }

    func testEverySentenceSurvivesSeveralRestarts() {
        var carry = "", session = ""
        for partial in ["I have a project", "I have a project called Goa trip", "and the first task is to book flights", "and the second is hotels"] {
            let m = TurnAccumulator.absorb(carry: carry, session: session, partial: partial)
            carry = m.carry; session = m.session
        }
        let whole = [carry, session].filter { !$0.isEmpty }.joined(separator: " ")
        XCTAssertTrue(whole.contains("I have a project called Goa trip"))
        XCTAssertTrue(whole.contains("book flights"))
        XCTAssertTrue(whole.contains("second is hotels"))
    }
}

@MainActor
final class EchoGuardTests: XCTestCase {
    private let spoken = "You have 3 open tasks. Call the dentist, Renew passport, Pay rent."

    func testGarbledEchoOfHerSentenceIsRecognised() {
        for echo in ["you have three tasks", "you have 3 open task's call the dentist", "call dentist renew passport", "open tasks call the", "pay the rent"] {
            XCTAssertTrue(EchoGuard.userWords(heard: echo, spoken: spoken).isEmpty, "\(echo) -> \(EchoGuard.userWords(heard: echo, spoken: spoken))")
        }
    }

    func testAWordFromHerSentenceInYourOwnRequestSurvives() {
        XCTAssertEqual(EchoGuard.userWords(heard: "add a task to buy milk", spoken: spoken).joined(separator: " "), "add a task to buy milk")
        XCTAssertEqual(EchoGuard.userWords(heard: "only rent", spoken: spoken), ["only", "rent"])
    }

    func testRightAfterSheStopsEvenSingleEchoedWordsAreDropped() {
        XCTAssertEqual(EchoGuard.userWords(heard: "rent", spoken: spoken, strict: true), [])
        XCTAssertEqual(EchoGuard.userWords(heard: "rent", spoken: spoken, strict: false), ["rent"])
    }

    func testTheEchoTailAtTheStartOfARecognitionIsCounted() {
        XCTAssertEqual(EchoGuard.leadingEcho(heard: "pay rent only tomorrow", spoken: spoken, strict: false), 2)
        XCTAssertEqual(EchoGuard.leadingEcho(heard: "only tomorrow", spoken: spoken, strict: false), 0)
        XCTAssertEqual(EchoGuard.leadingEcho(heard: "renew passport add a task to buy milk", spoken: spoken, strict: false), 2)
    }

    func testStopStillGetsThrough() {
        XCTAssertEqual(BargeIn.decide(heard: "pay rent stop", spoken: spoken), .interrupt(rest: ""))
    }

    func testTheSpokenBufferForgetsAfterTheTail() {
        var b = SpokenBuffer()
        let t0 = Date(timeIntervalSince1970: 1_000)
        b.began("You have 3 open tasks.")
        XCTAssertEqual(b.recentText(now: t0), "You have 3 open tasks.", "still speaking")
        b.ended(at: t0)
        XCTAssertTrue(b.inQuietWindow(now: t0.addingTimeInterval(0.3)))
        XCTAssertFalse(b.inQuietWindow(now: t0.addingTimeInterval(1)))
        XCTAssertFalse(b.recentText(now: t0.addingTimeInterval(1)).isEmpty)
        XCTAssertTrue(b.recentText(now: t0.addingTimeInterval(SpokenBuffer.tail + 1)).isEmpty)
    }
}

@MainActor
final class LongPromptTests: XCTestCase {
    private let intro = "I'm working on a project and I would like to create list of tasks for that project."
    private let full = "I'm working on a project and I would like to create list of tasks for that project. And the first task is, to write a strategy document."

    private func manager(_ engine: ScriptedEngine) -> VoiceTurnManager {
        let m = VoiceTurnManager(engine: engine, sink: InMemorySaveSink(), knownCategories: { [] }, knownAssignees: { [] })
        m.ruleFallbackEnabled = false
        return m
    }

    // MARK: The gate

    func testASetupSentenceIsHeldNotAnswered() {
        XCTAssertTrue(LocalSemanticPrechecker.announcesMore(intro))
        for pause in [4.0, 5.0, 5.5] {
            if case .hold = VoiceTurnManager.gate(utterance: intro, silence: pause, lastActed: "") {} else { XCTFail("held at \(pause)s") }
        }
        XCTAssertEqual(VoiceTurnManager.gate(utterance: intro, silence: 6.5, lastActed: ""), .nudge)
    }

    func testTheWholeThoughtIsEvaluatedOnceTheTaskIsSaid() {
        XCTAssertFalse(LocalSemanticPrechecker.announcesMore(full))
        XCTAssertEqual(VoiceTurnManager.gate(utterance: full, silence: 5.2, lastActed: ""), .evaluate(full))
    }

    func testRequestsAboutAListAreNotSetupSentences() {
        for said in ["Show my list of tasks", "What is on my list of tasks", "Can you show the list of tasks I have",
                     "Add a task to clean the bathroom", "Create a list of groceries and buy milk"] {
            XCTAssertFalse(LocalSemanticPrechecker.announcesMore(said), said)
        }
        XCTAssertEqual(VoiceTurnManager.gate(utterance: "Show my list of tasks", silence: 4.0, lastActed: ""), .evaluate("Show my list of tasks"))
    }

    func testOtherSetupSentences() {
        for said in ["I have a few things to add", "Let me give you a bunch of tasks", "I want to create a list of tasks for the kitchen project",
                     "We have some tasks for this week"] {
            XCTAssertTrue(LocalSemanticPrechecker.announcesMore(said), said)
        }
    }

    func testALongTurnGetsALongerPause() {
        XCTAssertEqual(VoiceTurnManager.pauseNeeded(for: "Buy milk"), VoiceTurnManager.longPause)
        XCTAssertGreaterThan(VoiceTurnManager.pauseNeeded(for: full), VoiceTurnManager.longPause)
        XCTAssertLessThanOrEqual(VoiceTurnManager.pauseNeeded(for: String(repeating: "word ", count: 100) + ". a. b."), VoiceTurnManager.normalCap)
        let long = "I need to sort out the garage this weekend and then call the plumber about the kitchen tap and then remember the school form."
        XCTAssertEqual(VoiceTurnManager.gate(utterance: long, silence: VoiceTurnManager.longPause + 0.1, lastActed: ""), .keepListening)
    }

    // MARK: The project and its tasks

    func testListOutlineFindsTheTaskAndAsksForTheNameWhenNoneWasSaid() {
        let outline = ListOutline.parse(full)
        XCTAssertEqual(outline?.items.map(\.title), ["Write a strategy document"])
        XCTAssertNil(outline?.name)
        XCTAssertEqual(outline?.questions, [.name(isProject: true)])
    }

    func testListOutlineReadsANameAndSeveralTasks() {
        let said = "I'm working on the website redesign project. The first task is to write a brief, the second task is to book a venue, third is review the budget."
        let outline = ListOutline.parse(said)
        XCTAssertEqual(outline?.name, "website redesign")
        XCTAssertEqual(outline?.items.map(\.title), ["Write a brief", "Book a venue", "Review the budget"])
        XCTAssertEqual(outline?.questions, [])
        XCTAssertEqual(ListOutline.parse("I have a project called Goa trip. First task is book flights and second task is find a hotel")?.name, "Goa trip")
    }

    func testOrdinalsWithoutAProjectAreLeftToTheModel() {
        XCTAssertNil(ListOutline.parse("The first task is to buy milk"))
    }

    func testTheProjectNameAnswerIsCleaned() {
        XCTAssertEqual(ListOutline.name(fromAnswer: "It's called the Website relaunch."), "Website relaunch")
        XCTAssertEqual(ListOutline.name(fromAnswer: "Goa trip project"), "Goa trip")
        XCTAssertNil(ListOutline.name(fromAnswer: ""))
    }

    func testWithNoNameKittyAsksForItAndKeepsTheTask() async {
        let engine = ScriptedEngine([])
        let m = manager(engine)
        let r = await m.decide(utterance: full)
        guard case .question(let q) = r else { return XCTFail("\(r)") }
        XCTAssertEqual(q, "What's the project called?")
        XCTAssertEqual(engine.prompts.count, 0, "no model call: the project is understood locally")
        XCTAssertEqual(m.state.pendingList?.items.map(\.title), ["Write a strategy document"])

        let answered = await m.decide(utterance: full + " Website relaunch")
        guard case .proposal(let p) = answered else { return XCTFail("\(answered)") }
        XCTAssertEqual(p.rows.map(\.title), ["Write a strategy document"])
        XCTAssertTrue(p.rows.first?.tags.contains { $0.text.contains("Website relaunch") } ?? false, "\(p.rows.first?.tags.map(\.text) ?? [])")
        XCTAssertNil(m.state.pendingList)
    }

    func testANamedProjectGoesStraightToAPreview() async {
        let engine = ScriptedEngine([])
        let m = manager(engine)
        let r = await m.decide(utterance: "I'm working on the Goa trip project. The first task is to book flights and the second task is to find a hotel.")
        guard case .proposal(let p) = r else { return XCTFail("\(r)") }
        XCTAssertEqual(p.rows.map(\.title), ["Book flights", "Find a hotel"])
    }


    // MARK: Not asking about what was already said

    func testAQuestionAboutTheKindOfAnActionableTaskBecomesASave() async {
        let q = "What kind of strategy document do you want to write?"
        XCTAssertTrue(ClarificationStateManager.asksForDetail(q))
        XCTAssertTrue(ClarificationStateManager.asksForDetail("What is the context?"))
        XCTAssertFalse(ClarificationStateManager.asksForDetail("How often should it repeat?"))
        XCTAssertFalse(ClarificationStateManager.asksForDetail("Which task do you mean?"))
        XCTAssertTrue(VoiceTurnManager.isActionableTitle("Write a strategy document"))
        XCTAssertFalse(VoiceTurnManager.isActionableTitle("Strategy"))

        let decision = AgentDecisionValue(wait: false, action: "clarify", title: "Write a strategy document", category: "", dueDate: "", priority: "",
                                          assignee: "", frequency: "", playbookName: "", playbookSteps: [], clarifyingQuestion: q, moreTasks: [])
        let m = manager(ScriptedEngine([decision]))
        let r = await m.decide(utterance: "Write a strategy document")
        if case .question = r { XCTFail("it should save, not ask what kind of document") }
    }
}

// MARK: Accurate spoken task lists

@MainActor
final class SpokenListAccuracyTests: XCTestCase {
    /// What the recogniser gave for the user's real utterance: no full stops, capitals in the middle.
    private let spoken = "I want to create list of tasks for kitty project Number one I would say Create a strategy document, full strategy document Number two Make task management Hands-free mode Robust and bring a closure Number three Validate with user"

    private func manager(_ engine: ScriptedEngine? = nil, people: [String] = []) -> VoiceTurnManager {
        let m = VoiceTurnManager(engine: engine ?? ScriptedEngine([]), sink: InMemorySaveSink(), knownCategories: { [] }, knownAssignees: { people })
        m.ruleFallbackEnabled = false
        return m
    }

    private func titles(_ o: ListOutline.Outline?) -> [String] { (o?.items.map(\.title) ?? []).map { $0.lowercased() } }

    // MARK: The exact utterance

    func testTheRealUtteranceMakesThreeTasksAndNoIntroTask() {
        let o = ListOutline.parse(spoken)
        XCTAssertEqual(titles(o), ["create a strategy document", "make task management hands-free mode robust and bring a closure", "validate with user"])
        XCTAssertEqual(o?.items.first?.notes?.lowercased(), "full strategy document")
        XCTAssertEqual(o?.name?.lowercased(), "kitty")
        XCTAssertEqual(o?.questions, [])
        XCTAssertNil(o?.assignee)
        XCTAssertTrue(o?.context.first?.lowercased().contains("list of tasks") ?? false, "the intro is context, not a task")
    }

    func testTheRealUtteranceGoesToAPreviewOfThreeWithoutAnAssignee() async {
        let engine = ScriptedEngine([])
        let r = await manager(engine).decide(utterance: spoken)
        guard case .proposal(let p) = r else { return XCTFail("\(r)") }
        XCTAssertEqual(p.rows.map { $0.title.lowercased() }, ["create a strategy document", "make task management hands-free mode robust and bring a closure", "validate with user"])
        XCTAssertEqual(engine.prompts.count, 0, "understood locally: the model is not asked to guess")
        for row in p.rows {
            XCTAssertTrue(row.tags.contains { $0.text.lowercased().contains("kitty") }, "list name: \(row.tags.map(\.text))")
            XCTAssertFalse(row.tags.contains { $0.text.lowercased().contains("assign") }, "Kitty is a project, not a person: \(row.tags.map(\.text))")
        }
    }

    // MARK: Other ways of numbering

    func testOtherWaysToNumberTheTasks() {
        let said = [
            "Make a list of tasks for the Garden project. Task one, buy soil. Task two, plant tomatoes. Task three, water the plants.",
            "Make a list of tasks for the Garden project. 1. Buy soil. 2. Plant tomatoes. 3. Water the plants.",
            "Make a list of tasks for the Garden project. First, buy soil. Second, plant tomatoes. Third, water the plants.",
            "Make a list of tasks for the Garden project. Number 1 buy soil number 2 plant tomatoes number 3 water the plants",
            "Make a list of tasks for the Garden project. Step one buy soil. Step two plant tomatoes. Step three water the plants.",
        ]
        for s in said {
            let o = ListOutline.parse(s)
            XCTAssertEqual(titles(o), ["buy soil", "plant tomatoes", "water the plants"], s)
            XCTAssertEqual(o?.name, "Garden", s)
            XCTAssertEqual(o?.questions, [], s)
        }
    }

    // MARK: Unclear: ask, never assume

    func testAGapInTheNumbersIsAskedAbout() async {
        let engine = ScriptedEngine([])
        let m = manager(engine)
        let r = await m.decide(utterance: "A list of tasks for the Garden project. Number one buy soil. Number two plant tomatoes. Number four water the plants.")
        guard case .question(let q) = r else { return XCTFail("\(r)") }
        XCTAssertEqual(q, "I heard numbers one, two and four. Is there a number three?")
        XCTAssertEqual(engine.prompts.count, 0)
        XCTAssertNotNil(m.state.pendingList)
    }

    func testTheMissingTaskIsAddedInItsPlace() async {
        let m = manager()
        let first = "A list of tasks for the Garden project. Number one buy soil. Number two plant tomatoes. Number four water the plants."
        _ = await m.decide(utterance: first)
        let r = await m.decide(utterance: first + " Yes, number three is prune the roses")
        guard case .proposal(let p) = r else { return XCTFail("\(r)") }
        XCTAssertEqual(p.rows.map { $0.title.lowercased() }, ["buy soil", "plant tomatoes", "prune the roses", "water the plants"])
    }

    func testSayingThereIsNoMissingNumberKeepsTheThree() async {
        let m = manager()
        let first = "A list of tasks for the Garden project. Number one buy soil. Number two plant tomatoes. Number four water the plants."
        _ = await m.decide(utterance: first)
        let r = await m.decide(utterance: first + " No, that's all")
        guard case .proposal(let p) = r else { return XCTFail("\(r)") }
        XCTAssertEqual(p.rows.count, 3)
    }

    func testAnEmptyMarkerIsAskedAbout() {
        let o = ListOutline.parse("A list of tasks for the Garden project. Number one buy soil. Number two. Number three water the plants.")
        XCTAssertEqual(o?.questions, [.empty(label: "number two", index: 1)])
        XCTAssertEqual(o?.questions.first?.text, "What is number two?")
    }

    func testANameThatIsAlsoAPersonIsAskedAbout() async {
        let m = manager(people: ["Kitty"])
        let r = await m.decide(utterance: spoken)
        guard case .question(let q) = r else { return XCTFail("\(r)") }
        XCTAssertEqual(q, "Is Kitty the project, or a person?")
        let a = await m.decide(utterance: spoken + " The project")
        guard case .proposal(let p) = a else { return XCTFail("\(a)") }
        XCTAssertEqual(p.rows.count, 3)
    }

    func testALongItemWithTwoActionsIsAskedAbout() {
        let o = ListOutline.parse("A list of tasks for the Garden project. Number one buy soil and fertiliser from the nursery on the main road and then dig the whole back bed. Number two plant tomatoes.")
        XCTAssertEqual(o?.questions, [.split(index: 0)])
    }

    func testAnActionInsideANumberedItemIsAskedAbout() {
        let o = ListOutline.parse("A list of tasks for the Garden project. Number one buy soil. Call the nursery. Number two plant tomatoes.")
        XCTAssertEqual(o?.questions, [.separate(text: "Call the nursery", after: 0)])
        XCTAssertEqual(titles(o), ["buy soil", "plant tomatoes"], "not added until the user says so")
    }

    // MARK: What is an intro

    func testSentencesAreClassifiedByWhatTheySay() {
        XCTAssertEqual(ListOutline.role(of: "I want to create a list of tasks for the Kitty project"), .context)
        XCTAssertEqual(ListOutline.role(of: "I'm working on the website redesign project"), .context)
        XCTAssertEqual(ListOutline.role(of: "Create a strategy document"), .task)
        XCTAssertEqual(ListOutline.role(of: "I want to create a strategy document"), .task)
        XCTAssertEqual(ListOutline.role(of: "Validate with user"), .task)
        XCTAssertEqual(ListOutline.role(of: "That's all"), .outro)
        XCTAssertEqual(ListOutline.role(of: "Strategy document"), .unsure)
    }

    func testAListWithNoIntroStillWorks() {
        let o = ListOutline.parse("Number one buy soil. Number two plant tomatoes. Number three water the plants for the garden project.")
        XCTAssertEqual(o?.items.count, 3)
        XCTAssertEqual(o?.context, [])
    }

    func testAnUnnumberedListUsesEachActionSentenceAndIgnoresTheIntro() {
        let o = ListOutline.parse("I'm planning the Garden project and here are the tasks. Buy soil. Plant tomatoes. Water the plants.")
        XCTAssertEqual(titles(o), ["buy soil", "plant tomatoes", "water the plants"])
        XCTAssertEqual(o?.name, "Garden")
    }

    func testAnAsideInTheMiddleIsNotATask() {
        let o = ListOutline.parse("A list of tasks for the Garden project. Number one buy soil. I think the nursery opens at nine. Number two plant tomatoes.")
        XCTAssertEqual(titles(o), ["buy soil", "plant tomatoes"])
        XCTAssertTrue(o?.context.contains { $0.contains("nursery") } ?? false)
    }

    func testANounOnlySentenceInAnUnnumberedListIsAsked() {
        let o = ListOutline.parse("A list of tasks for the Garden project. Buy soil. Tomato plants. Water the plants.")
        XCTAssertEqual(o?.questions.first?.text, "Is “Tomato plants” a task, or just context?")
    }

    // MARK: Names are not assignees

    func testAProjectNameIsNeverAnAssignee() {
        XCTAssertNil(TaskValidator.resolveAssignee("Kitty", utterance: "Add a task for Kitty project to ship it"))
        XCTAssertEqual(TaskValidator.resolveAssignee("Rani", utterance: "Ask Rani to call the plumber"), "Rani")
    }

    func testAPlainRequestIsNotAList() {
        XCTAssertNil(ListOutline.parse("Buy milk"))
        XCTAssertNil(ListOutline.parse("Remind me to call mom at five"))
    }

    // MARK: The model path never adds the intro

    func testTheIntroSegmentIsNotAddedBackAsATask() {
        XCTAssertTrue(ListOutline.isContext("I want to create a list of tasks for the Kitty project"))
        XCTAssertFalse(ListOutline.isContext("Validate with user"))
        XCTAssertTrue(ListOutline.covered("Create a strategy document", by: [(title: "Create a strategy doc", notes: "Full strategy document")]))
        XCTAssertFalse(ListOutline.covered("Validate with user", by: [(title: "Create a strategy doc", notes: nil)]))
    }
}
