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
