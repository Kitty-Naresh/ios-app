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
        XCTAssertEqual(BargeIn.decide(heard: "only tomorrow", spoken: spoken), .interrupt(rest: "only tomorrow"))
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
