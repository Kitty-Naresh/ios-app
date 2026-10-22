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
