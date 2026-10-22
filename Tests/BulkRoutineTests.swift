import XCTest
@testable import Kitty

// Bulk routines: several repeating chores in one breath ("every morning water the plants, every evening lock the doors and
// every Sunday clean the fridge"). They have to reach the bulk path, show every routine with its own schedule, time of day and
// person, and save as routines. Nothing here touches the real task store: every manager uses an InMemorySaveSink.

@MainActor
final class BulkRoutineTests: XCTestCase {
    private struct WaitingEngine: DecisionProviding {
        func decide(prompt: String) async -> AgentDecisionValue? { AgentDecisionValue(wait: true, action: "wait") }
        func decideBulk(prompt: String) async -> BulkDecisionValue? { BulkDecisionValue(action: "wait") }
    }
    private static let now = LongTurnAnalyzerTests.now

    static let morningEveningSunday = "Every morning water the plants, every evening lock the doors and every Sunday clean the fridge"
    static let dailyWeeklyMonthly = "Daily take out the trash, weekly mop the floors, monthly pay the electricity bill"
    static let maid = "The maid should sweep every day and mop every Saturday"

    private func manager(_ engine: DecisionProviding, sink: InMemorySaveSink? = nil) -> VoiceTurnManager {
        let m = VoiceTurnManager(engine: engine, sink: sink ?? InMemorySaveSink(), knownCategories: { [] }, knownAssignees: { [] })
        m.ruleFallbackEnabled = true
        return m
    }

    private func routines(_ titles: [String], frequency: String, schedule: String) -> BulkDecisionValue {
        BulkDecisionValue(action: "create_routines",
                          routines: titles.map { RoutineDraftValue(title: $0, frequency: frequency, schedule: schedule) })
    }

    /// Says yes the way the screen does: through the one-shot guard.
    private func save(_ m: VoiceTurnManager, _ r: TurnResult, file: StaticString = #filePath, line: UInt = #line) async -> String? {
        // Only drafts built by the bulk path write to the manager's in-memory sink. Anything else (the single-task rule planner)
        // would write to the real task store, so it is never applied here.
        let bulkRoutes = ["model-bulk", "bulk-rules", "model-bulk-long", "long-turn-rules", "edit"]
        guard case .proposal(let p) = r, bulkRoutes.contains(m.lastTrace.route), m.state.confirmation.consume(p.id) else {
            XCTFail("nothing to save (route \(m.lastTrace.route)): \(r)", file: file, line: line)
            return nil
        }
        return await p.apply().message
    }

    private func rows(_ r: TurnResult) -> [String] {
        guard case .proposal(let p) = r else { return [] }
        return p.rows.map { $0.title + " | " + $0.tags.map(\.text).joined(separator: ", ") }
    }

    // MARK: Detection

    func testASchedulePutFirstIsStillAList() {
        let a = BulkDetector.analyze(Self.morningEveningSunday, now: Self.now)
        XCTAssertEqual(a.kind, .routines)
        XCTAssertEqual(a.segments, ["water the plants every morning", "lock the doors every evening", "clean the fridge every sunday"])
        let b = BulkDetector.analyze(Self.dailyWeeklyMonthly, now: Self.now)
        XCTAssertEqual(b.kind, .routines)
        XCTAssertEqual(b.segments, ["take out the trash daily", "mop the floors weekly", "pay the electricity bill monthly"])
    }

    func testAScheduleThatHoldsForTwoActionsIsKeptOnBoth() {
        let a = BulkDetector.analyze("Every morning water the plants and sweep the porch", now: Self.now)
        XCTAssertEqual(a.kind, .routines)
        XCTAssertEqual(a.segments, ["water the plants every morning", "sweep the porch every morning"])
    }

    func testAPersonAndAModalComeOffAShortRoutineList() {
        let a = BulkDetector.analyze(Self.maid, now: Self.now)
        XCTAssertEqual(a.kind, .routines)
        XCTAssertEqual(a.segments, ["sweep every day", "mop every saturday"])
    }

    func testATrailingScheduleStillWorksAndOneRoutineIsNotAList() {
        XCTAssertEqual(BulkDetector.analyze("Water the plants every morning and lock the doors every night", now: Self.now).kind, .routines)
        XCTAssertFalse(BulkDetector.analyze("Every morning water the plants", now: Self.now).isBulk)
        XCTAssertFalse(BulkDetector.analyze("Water the plants every morning", now: Self.now).isBulk)
    }

    func testTheGateLetsTheMaidSentenceThrough() {
        XCTAssertEqual(VoiceTurnManager.gate(utterance: Self.maid, silence: 2, lastActed: ""), .evaluate(Self.maid))
        let held = ["The bathroom", "The maid", "The maid should"]
        for said in held {
            if case .evaluate = VoiceTurnManager.gate(utterance: said, silence: 2, lastActed: "") { XCTFail("“\(said)” is unfinished") }
        }
    }

    // MARK: A long turn reads "every Sunday" as a schedule

    func testEverySundayIsNotADueDayInALongTurn() {
        let said = "Um so it has been a crazy week you know but water the plants every morning and clean the fridge every Sunday"
        let t = BulkDetector.analyze(said, now: Self.now).turn
        XCTAssertEqual(t?.actions.map(\.text), ["water the plants every morning", "clean the fridge every sunday"])
        XCTAssertEqual(t?.actions.map(\.scheduled), [true, true])
        XCTAssertEqual(t?.actions.map { $0.due }, [nil, nil], "a routine repeats, it has no day")
    }

    func testARoutineBesideAOneOffKeepsTheOneOffsOwnDayOnly() async {
        let said = "Okay so honestly it has been a long week but I need to buy flowers tomorrow and water the plants every Sunday"
        let m = manager(BulkQueueEngine([]))
        let r = await m.decide(utterance: said, now: Self.now)
        guard case .proposal = r else { return XCTFail("\(r)") }
        let items = m.state.drafts.items
        XCTAssertEqual(items.map(\.kind), [.task, .routine])
        XCTAssertEqual(items.map(\.due), [LongTurnAnalyzerTests.day(23), nil])
        XCTAssertEqual(items[1].recurrence?.scheduleText, "every Sunday")
    }

    func testAContextDayIsOnlyOfferedToTasksNeverToRoutines() async {
        let said = "Okay so we have my in-laws coming this Saturday and honestly the house is a mess, so I need to buy flowers, call the caterer and water the plants every morning"
        let m = manager(BulkQueueEngine([]))
        let r = await m.decide(utterance: said, now: Self.now)
        guard case .proposal(let p) = r else { return XCTFail("\(r)") }
        XCTAssertEqual(m.state.drafts.items.map(\.kind), [.task, .task, .routine])
        XCTAssertEqual(p.prompt, "I picked these because of Saturday, for in-laws. Should I tag the ones without a date as due Saturday?")
        XCTAssertEqual(m.state.pendingContextDue?.keys.count, 2, "the routine is not one of the undated tasks")
        let yes = await m.decide(utterance: said + " yes", now: Self.now)
        guard case .proposal = yes else { return XCTFail("\(yes)") }
        XCTAssertNil(m.state.drafts.items[2].due)
        XCTAssertEqual(m.state.drafts.items.prefix(2).map(\.due), [LongTurnAnalyzerTests.day(24), LongTurnAnalyzerTests.day(24)])
    }

    // MARK: The three failing utterances, with no model, a model that waits, and a model that answers

    private func checkMorningEveningSunday(_ m: VoiceTurnManager, _ r: TurnResult, _ sink: InMemorySaveSink,
                                           file: StaticString = #filePath, line: UInt = #line) async {
        XCTAssertEqual(rows(r), ["Water the plants | every day, Morning", "Lock the doors | every day, Evening",
                                 "Clean the fridge | every Sunday"], m.lastTrace.route, file: file, line: line)
        guard case .proposal(let p) = r else { return }
        XCTAssertEqual(p.prompt, "I have 3 routines: water the plants, lock the doors, and clean the fridge. Should I save these?", file: file, line: line)
        XCTAssertFalse(p.autoConfirm, "several items always wait for a yes", file: file, line: line)
        let said = await save(m, r, file: file, line: line)
        XCTAssertEqual(said, "Saved 3 routines: plants, doors, and fridge.", file: file, line: line)
        XCTAssertEqual(sink.tasks.count, 0, "none of them is a one-time task", file: file, line: line)
        XCTAssertEqual(sink.routines.map(\.title), ["Water the plants", "Lock the doors", "Clean the fridge"], file: file, line: line)
        XCTAssertEqual(sink.routines.map { $0.recurrence?.scheduleText }, ["every day", "every day", "every Sunday"], file: file, line: line)
        XCTAssertEqual(sink.routines.map(\.slot), [.morning, .evening, nil], "the time of day said in the schedule is kept", file: file, line: line)
        XCTAssertEqual(sink.routines.map(\.due), [nil, nil, nil], file: file, line: line)
    }

    func testMorningEveningSundayWithNoModel() async {
        let sink = InMemorySaveSink()
        let m = manager(BulkQueueEngine([]), sink: sink)
        let r = await m.decide(utterance: Self.morningEveningSunday, now: Self.now)
        await checkMorningEveningSunday(m, r, sink)
    }

    func testMorningEveningSundayWhenTheModelOnlySaysWait() async {
        let sink = InMemorySaveSink()
        let m = manager(WaitingEngine(), sink: sink)
        let r = await m.decide(utterance: Self.morningEveningSunday, now: Self.now)
        await checkMorningEveningSunday(m, r, sink)
    }

    func testMorningEveningSundayWhenTheModelCreatesRoutines() async {
        let sink = InMemorySaveSink()
        var b = BulkDecisionValue(action: "create_routines")
        b.routines = [RoutineDraftValue(title: "Water the plants", frequency: "daily", schedule: "every morning"),
                      RoutineDraftValue(title: "Lock the doors", frequency: "daily", schedule: "every evening"),
                      RoutineDraftValue(title: "Clean the fridge", frequency: "weekly", schedule: "every Sunday")]
        let m = manager(BulkQueueEngine([b]), sink: sink)
        let r = await m.decide(utterance: Self.morningEveningSunday, now: Self.now)
        XCTAssertEqual(m.lastTrace.route, "model-bulk-long")
        await checkMorningEveningSunday(m, r, sink)
    }

    func testTheModelCallingThemTasksStillMakesRoutines() async {
        let sink = InMemorySaveSink()
        let m = manager(BulkQueueEngine([BulkQueueEngine.tasks(["Water the plants", "Lock the doors", "Clean the fridge"])]), sink: sink)
        let r = await m.decide(utterance: Self.morningEveningSunday, now: Self.now)
        await checkMorningEveningSunday(m, r, sink)
    }

    func testAModelThatSaysWeeklyWithoutADayDoesNotGetToday() async {
        let said = "Water the plants every morning and mop the floors every Saturday"
        var b = BulkDecisionValue(action: "create_routines")
        b.routines = [RoutineDraftValue(title: "Water the plants", frequency: "daily", schedule: "every morning"),
                      RoutineDraftValue(title: "Mop the floors", frequency: "weekly", schedule: "weekly")]
        let sink = InMemorySaveSink()
        let m = manager(BulkQueueEngine([b]), sink: sink)
        let r = await m.decide(utterance: said, now: Self.now)
        XCTAssertEqual(rows(r), ["Water the plants | every day, Morning", "Mop the floors | every Saturday"])
        _ = await save(m, r)
        XCTAssertEqual(sink.routines.map { $0.recurrence?.weekdays }, [[], [7]])
    }

    // MARK: Daily, weekly, monthly: the day that was not said is asked, and the list survives the answer

    func testWeeklyAndMonthlyAskForTheirDayAndTheOtherRoutinesSurvive() async {
        let sink = InMemorySaveSink()
        let m = manager(BulkQueueEngine([]), sink: sink)
        let first = await m.decide(utterance: Self.dailyWeeklyMonthly, now: Self.now)
        guard case .question(let q1) = first else { return XCTFail("\(first)") }
        XCTAssertEqual(q1, "Which day should I mop the floors each week?")

        var said = Self.dailyWeeklyMonthly + " Saturday"
        let second = await m.decide(utterance: said, now: Self.now)
        guard case .question(let q2) = second else { return XCTFail("\(second)") }
        XCTAssertEqual(q2, "Which day of the month should I pay the electricity bill?")

        said += " the 5th"
        let third = await m.decide(utterance: said, now: Self.now)
        XCTAssertEqual(rows(third), ["Take out the trash | every day", "Mop the floors | every Saturday",
                                     "Pay the electricity bill | monthly on the 5th"])
        _ = await save(m, third)
        XCTAssertEqual(sink.tasks.count, 0)
        XCTAssertEqual(sink.routines.map(\.title), ["Take out the trash", "Mop the floors", "Pay the electricity bill"])
        XCTAssertEqual(sink.routines.map { $0.recurrence?.weekdays }, [[], [7], []])
        XCTAssertEqual(sink.routines.map { $0.recurrence?.dayOfMonth }, [nil, nil, 5])
    }

    func testTheModelPathAsksTheSameQuestionAndKeepsTheListAfterTheAnswer() async {
        let sink = InMemorySaveSink()
        var b = BulkDecisionValue(action: "create_routines")
        b.routines = [RoutineDraftValue(title: "Take out the trash", frequency: "daily", schedule: "daily"),
                      RoutineDraftValue(title: "Mop the floors", frequency: "weekly", schedule: "weekly")]
        var again = b
        again.routines[1].schedule = "Saturday"
        let m = manager(BulkQueueEngine([b, again]), sink: sink)
        let said = "Daily take out the trash and weekly mop the floors"
        let first = await m.decide(utterance: said, now: Self.now)
        guard case .question(let q) = first else { return XCTFail("\(first)") }
        XCTAssertEqual(q, "Which day should I mop the floors each week?")
        let second = await m.decide(utterance: said + " Saturday", now: Self.now)
        XCTAssertEqual(rows(second), ["Take out the trash | every day", "Mop the floors | every Saturday"])
    }

    // MARK: A person, no object, and a list's own schedule

    func testTheMaidShouldSweepEveryDayAndMopEverySaturday() async {
        var maidRoutines = BulkDecisionValue(action: "create_routines")
        maidRoutines.routines = [RoutineDraftValue(title: "Sweep", frequency: "daily", schedule: "every day", assignee: "Househelp"),
                                 RoutineDraftValue(title: "Mop", frequency: "weekly", schedule: "every Saturday", assignee: "Househelp")]
        for engine: DecisionProviding in [BulkQueueEngine([]), WaitingEngine(),
                                          BulkQueueEngine([maidRoutines])] {
            let sink = InMemorySaveSink()
            let m = manager(engine, sink: sink)
            let r = await m.decide(utterance: Self.maid, now: Self.now)
            XCTAssertEqual(m.state.drafts.items.map(\.title), ["Sweep", "Mop"], m.lastTrace.route)
            XCTAssertEqual(m.state.drafts.items.map { $0.recurrence?.scheduleText }, ["every day", "every Saturday"], m.lastTrace.route)
            XCTAssertEqual(m.state.drafts.items.map(\.assignee), [Assignee.househelp, Assignee.househelp], "the maid is Househelp: \(m.lastTrace.route)")
            _ = await save(m, r)
            XCTAssertEqual(sink.routines.map(\.assignee), [Assignee.househelp, Assignee.househelp])
            XCTAssertEqual(sink.tasks.count, 0)
        }
    }

    func testOneScheduleBeforeTheListHoldsForEveryItem() async {
        let said = "Every day: sweep the floors, wash the dishes, take out the trash"
        for engine: DecisionProviding in [BulkQueueEngine([]), WaitingEngine(),
                                          BulkQueueEngine([BulkQueueEngine.tasks(["Sweep the floors", "Wash the dishes", "Take out the trash"])]),
                                          BulkQueueEngine([routines(["Sweep the floors", "Wash the dishes", "Take out the trash"], frequency: "daily", schedule: "every day")])] {
            let sink = InMemorySaveSink()
            let m = manager(engine, sink: sink)
            let r = await m.decide(utterance: said, now: Self.now)
            XCTAssertEqual(m.state.drafts.items.map(\.kind), [.routine, .routine, .routine], m.lastTrace.route)
            XCTAssertEqual(m.state.drafts.items.map { $0.recurrence?.scheduleText }, ["every day", "every day", "every day"], m.lastTrace.route)
            XCTAssertEqual(DraftSummary.kindText(m.state.drafts.items), "3 daily routines")
            _ = await save(m, r)
            XCTAssertEqual(sink.routines.count, 3)
            XCTAssertEqual(sink.tasks.count, 0)
        }
    }

    func testOneTimeTasksNextToARoutineStayTasks() async {
        let said = "Buy milk tomorrow and water the plants every morning"
        let sink = InMemorySaveSink()
        let m = manager(BulkQueueEngine([BulkQueueEngine.tasks(["Buy milk", "Water the plants"])]), sink: sink)
        let r = await m.decide(utterance: said, now: Self.now)
        XCTAssertEqual(m.state.drafts.items.map(\.kind), [.task, .routine])
        XCTAssertEqual(m.state.drafts.items.map(\.due), [LongTurnAnalyzerTests.day(23), nil])
        XCTAssertEqual(DraftSummary.kindText(m.state.drafts.items), "1 task and 1 routine")
        _ = await save(m, r)
        XCTAssertEqual(sink.tasks.map(\.title), ["Buy milk"])
        XCTAssertEqual(sink.routines.map(\.title), ["Water the plants"])
        XCTAssertEqual(sink.routines.first?.slot, .morning)
    }

    // MARK: The draft can be edited and saves once

    func testAddingARoutineToAPendingDraftKeepsItsSchedule() async {
        let sink = InMemorySaveSink()
        let m = manager(BulkQueueEngine([]), sink: sink)
        let said = "Water the plants every morning and lock the doors every night"
        let first = await m.decide(utterance: said, now: Self.now)
        guard case .proposal = first else { return XCTFail("\(first)") }
        let r = await m.decide(utterance: said + " also add feed the cat every Monday", now: Self.now)
        XCTAssertEqual(m.state.drafts.items.map(\.title), ["Water the plants", "Lock the doors", "Feed the cat"])
        XCTAssertEqual(m.state.drafts.items.last?.kind, .routine)
        XCTAssertEqual(m.state.drafts.items.last?.recurrence?.scheduleText, "every Monday")
        XCTAssertNil(m.state.drafts.items.last?.due)
        _ = await save(m, r)
        XCTAssertEqual(sink.routines.map { $0.recurrence?.scheduleText }, ["every day", "every day", "every Monday"])
    }

    func testSavingTwiceDoesNotDoubleTheRoutines() async {
        let sink = InMemorySaveSink()
        let m = manager(BulkQueueEngine([]), sink: sink)
        let r = await m.decide(utterance: "Water the plants every morning and lock the doors every night", now: Self.now)
        guard case .proposal(let p) = r else { return XCTFail("\(r)") }
        XCTAssertTrue(m.state.confirmation.consume(p.id))
        _ = await p.apply()
        let again = await p.apply()
        XCTAssertEqual(again.message, "Already saved.")
        XCTAssertFalse(m.state.confirmation.consume(p.id), "a second yes or tap does nothing")
        XCTAssertEqual(sink.routines.count, 2)
    }

    func testSavingARoutineYouAlreadyHaveSaysSo() async {
        let sink = InMemorySaveSink()
        _ = sink.saveRoutine(PlannedTask(title: "Water the plants", category: .guess(from: "Water the plants"), due: nil,
                                         recurrence: RecurrenceSpec()))
        let m = manager(BulkQueueEngine([]), sink: sink)
        let r = await m.decide(utterance: "Water the plants every day and lock the doors every night", now: Self.now)
        let said = await save(m, r)
        XCTAssertEqual(said, "Added a daily routine: lock the doors.")
        XCTAssertEqual(sink.routines.count, 2)
    }
}
