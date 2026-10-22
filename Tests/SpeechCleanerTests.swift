import XCTest
@testable import Kitty

/// Table-driven checks for SpeechCleaner: what it removes, what it must never touch, and that cleaning twice changes nothing.
final class SpeechCleanerTests: XCTestCase {

    private func check(_ cases: [(String, String)], file: StaticString = #filePath, line: UInt = #line) {
        for (input, expected) in cases {
            let out = SpeechCleaner.clean(input)
            XCTAssertEqual(out.text, expected, "“\(input)”", file: file, line: line)
            XCTAssertEqual(SpeechCleaner.clean(out.text).text, out.text, "not idempotent: “\(input)”", file: file, line: line)
        }
    }

    // MARK: Fillers

    func testHardFillersAreRemovedAnywhere() {
        check([
            ("um add a task to clean the bathroom", "add a task to clean the bathroom"),
            ("Um, add a task to clean the bathroom", "add a task to clean the bathroom"),
            ("add a task uh to clean the bathroom", "add a task to clean the bathroom"),
            ("add a task to clean the bathroom, um", "add a task to clean the bathroom,"),
            ("er, call mom", "call mom"),
            ("erm buy milk hmm and bread", "buy milk and bread"),
            ("uhh umm clean the floor", "clean the floor")
        ])
    }

    func testSoftFillersGoOnlyWhenSetOff() {
        check([
            ("add a task, like, to clean the bathroom", "add a task, to clean the bathroom"),
            ("clean the bathroom, you know, and then the kitchen", "clean the bathroom, and then the kitchen"),
            ("basically, call the plumber", "call the plumber"),
            ("you know, buy milk", "buy milk"),
            ("buy milk, you know", "buy milk,")
        ])
    }

    func testSoftFillersInsideRealSentencesAreKept() {
        check([
            ("I would like to buy milk", "I would like to buy milk"),
            ("it looks like rain", "it looks like rain"),
            ("buy something like milk", "buy something like milk"),
            ("do you know the plumber's number", "do you know the plumber's number"),
            ("I like to run every day", "I like to run every day"),
            ("buy bread basically every week", "buy bread basically every week")
        ])
    }

    // MARK: Repeats

    func testRepeatedWordsCollapse() {
        check([
            ("clean the the bathroom", "clean the bathroom"),
            ("add a a task", "add a task"),
            ("buy buy milk", "buy milk"),
            ("clean the clean the bathroom", "clean the bathroom"),
            ("buy some milk buy some milk", "buy some milk"),
            ("call call mom", "call mom")
        ])
    }

    func testLegitimateRepeatsAreKept() {
        check([
            ("it was very very hot", "it was very very hot"),
            ("I said that that is fine", "I said that that is fine"),
            ("buy 2 2 litre bottles", "buy 2 2 litre bottles")
        ])
    }

    // MARK: Self-repairs

    func testNoWaitReplacesTheClauseWhenTheCorrectionIsAnAction() {
        check([
            ("clean the... no wait, wash the car", "wash the car"),
            ("clean the bathroom, no wait, wash the car", "wash the car"),
            ("add a task to clean the bathroom, no wait, wash the car", "add a task to wash the car"),
            ("clean the bathroom wait no wash the car", "wash the car"),
            ("clean the bathroom or rather wash the car", "wash the car")
        ])
    }

    func testAScratchThatDropsThePreviousClause() {
        check([
            ("buy milk, scratch that, call the plumber", "call the plumber"),
            ("buy milk scratch that", ""),
            ("clean the bathroom, never mind that, wash the car", "wash the car")
        ])
    }

    func testANounCorrectionReplacesTheLastNounPhrase() {
        check([
            ("buy milk, I mean bread", "buy bread"),
            ("clean the bathroom, I mean kitchen", "clean the kitchen"),
            ("clean the master bathroom, no wait, kitchen", "clean the kitchen"),
            ("buy water, I mean juice", "buy juice"),
            ("water the plants in the garden, I mean the balcony", "water the plants in the balcony"),
            ("buy milk, sorry, bread", "buy bread")
        ])
    }

    func testADayCorrectionReplacesThePreviousDay() {
        check([
            ("call mom tomorrow, no wait, Friday", "call mom Friday"),
            ("call mom on Monday, I mean Tuesday", "call mom on Tuesday"),
            ("pay rent at 5, no wait, 6", "pay rent at 6")
        ])
    }

    func testARepairInTheMiddleOfAListOnlyTouchesItsOwnClause() {
        check([
            ("clean the bathroom, buy milk, no wait, buy bread, call mom", "clean the bathroom, buy bread, call mom"),
            ("wash the car, buy milk, scratch that, call mom", "wash the car, call mom"),
            ("clean the bathroom, buy milk, I mean bread", "clean the bathroom, buy bread")
        ])
    }

    func testARepairWithNoCorrectionYetKeepsListeningAndIsFlagged() {
        let out = SpeechCleaner.clean("clean the bathroom, no wait")
        XCTAssertEqual(out.text, "clean the bathroom,")
        XCTAssertTrue(out.pendingRepair)
        XCTAssertFalse(SpeechCleaner.clean("clean the bathroom").pendingRepair)
    }

    // MARK: Guards: ordinary speech is never edited

    func testOrdinarySentencesAreNeverChanged() {
        check([
            ("say sorry to mom", "say sorry to mom"),
            ("tell dad sorry about the car", "tell dad sorry about the car"),
            ("wait for the plumber", "wait for the plumber"),
            ("I would like to buy milk", "I would like to buy milk"),
            ("it looks like rain", "it looks like rain"),
            ("I mean to call mom tomorrow", "I mean to call mom tomorrow"),
            ("actually make it Friday", "actually make it Friday"),
            ("add a task to clean the bathroom", "add a task to clean the bathroom"),
            ("no wait for me", "no wait for me"),
            ("show me my personal tasks", "show me my personal tasks"),
            ("clean", "clean"),
            ("clean the", "clean the")
        ])
    }

    func testAMarkerAtTheStartHasNothingToReplace() {
        check([
            ("no wait, wash the car", "no wait, wash the car"),
            ("scratch that", "scratch that"),
            ("sorry, call mom", "sorry, call mom")
        ])
    }

    // MARK: Edits and positions

    func testEditsRecordKindAndRemovedWords() {
        let out = SpeechCleaner.clean("um clean the clean the bathroom")
        XCTAssertEqual(out.text, "clean the bathroom")
        XCTAssertEqual(out.edits.map(\.kind), [.filler, .repeated])
        XCTAssertEqual(out.edits.first?.words, ["um"])
        XCTAssertEqual(out.edits.last?.range, 1..<3)
        XCTAssertEqual(out.removed, [0, 1, 2])
    }

    func testARepairRecordsTheWholeRemovedClause() {
        let out = SpeechCleaner.clean("buy milk, no wait, buy bread")
        XCTAssertEqual(out.text, "buy bread")
        XCTAssertEqual(out.edits.map(\.kind), [.repair])
        XCTAssertEqual(out.edits.first?.range, 0..<4)
        XCTAssertEqual(out.removed, [0, 1, 2, 3])
    }

    func testRemovedPositionsMatchTheRawWords() {
        let raw = "Um, buy milk, scratch that, call mom"
        let out = SpeechCleaner.clean(raw)
        let words = SpeechCleaner.words(of: raw)
        let kept = words.indices.filter { !out.removed.contains($0) }.map { words[$0] }.joined(separator: " ")
        XCTAssertEqual(kept, out.text)
        XCTAssertEqual(out.raw, raw)
    }

    func testCleanTextIsLeftAlone() {
        let out = SpeechCleaner.clean("add a task to clean the bathroom")
        XCTAssertFalse(out.changed)
        XCTAssertTrue(out.removed.isEmpty)
        XCTAssertEqual(out.text, out.raw)
    }

    func testEmptyAndFillerOnlySpeech() {
        XCTAssertEqual(SpeechCleaner.clean("").text, "")
        XCTAssertEqual(SpeechCleaner.clean("um, uh").text, "")
    }

    func testCleaningIsIdempotentOnAMessyMix() {
        for s in ["um, clean the... no wait, wash the car, you know, and buy milk buy milk",
                  "buy milk, scratch that, uh, I mean call mom tomorrow, no wait, Friday",
                  "er add a a task to clean the bathroom, I mean kitchen"] {
            let once = SpeechCleaner.clean(s).text
            XCTAssertEqual(SpeechCleaner.clean(once).text, once, s)
        }
    }
}
