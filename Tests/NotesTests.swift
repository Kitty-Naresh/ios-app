import XCTest
@testable import Kitty

/// A1: notes persist. The store (file, order, corruption, delete) and the rule for which words of a turn are a note.
@MainActor
final class NotesTests: XCTestCase {
    private var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("kitty-notes-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private var file: URL { dir.appendingPathComponent("notes.json") }

    // MARK: The store

    func testNotesComeBackAfterARestartInOrderWithTheirLineBreaks() {
        let first = UUID(), second = UUID()
        let store = NotesStore(url: file)
        store.upsert(id: first, text: "Pharmacy list\nDo this that\nAnd this", at: Date(timeIntervalSince1970: 100))
        store.upsert(id: second, text: "Call mom", at: Date(timeIntervalSince1970: 200))

        let reopened = NotesStore(url: file)            // the app was closed and opened again
        XCTAssertEqual(reopened.load().map(\.id), [first, second])
        XCTAssertEqual(reopened.load().first?.text, "Pharmacy list\nDo this that\nAnd this")
    }

    func testSpeakingOnChangesTheSameNoteInsteadOfAddingOne() {
        let id = UUID()
        let store = NotesStore(url: file)
        store.upsert(id: id, text: "buy milk")
        store.upsert(id: id, text: "buy milk and eggs")
        XCTAssertEqual(NotesStore(url: file).load().map(\.text), ["buy milk and eggs"])
    }

    func testEmptyTextIsNeverStored() {
        let store = NotesStore(url: file)
        XCTAssertFalse(store.upsert(id: UUID(), text: "  \n "))
        XCTAssertEqual(store.count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testDeleteRemovesOnlyThatNoteAndStaysDeleted() {
        let keep = UUID(), drop = UUID()
        let store = NotesStore(url: file)
        store.upsert(id: keep, text: "keep me")
        store.upsert(id: drop, text: "delete me")
        store.delete(id: drop)
        XCTAssertEqual(NotesStore(url: file).load().map(\.id), [keep])
    }

    func testOneUnreadableEntryDoesNotHideTheOthers() throws {
        let good = UUID()
        let store = NotesStore(url: file)
        store.upsert(id: good, text: "still here")
        // Break one entry by hand: a note with no text, next to the good one.
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        var notes = try XCTUnwrap(json["notes"] as? [[String: Any]])
        notes.append(["id": "not-a-uuid", "createdAt": "never"])
        json["notes"] = notes
        try JSONSerialization.data(withJSONObject: json).write(to: file)

        let reopened = NotesStore(url: file)
        XCTAssertEqual(reopened.load().map(\.id), [good])
        XCTAssertNil(reopened.movedAside)
    }

    func testAFileThatCannotBeReadIsMovedAsideNotOverwritten() throws {
        try Data("this is not json".utf8).write(to: file)
        let store = NotesStore(url: file)
        XCTAssertEqual(store.load().count, 0)
        let aside = try XCTUnwrap(store.movedAside)
        XCTAssertEqual(try String(contentsOf: aside, encoding: .utf8), "this is not json")      // the user's file is kept

        store.upsert(id: UUID(), text: "a fresh note")                                           // and the store works again
        XCTAssertEqual(NotesStore(url: file).load().count, 1)
    }

    func testTheFileIsProtectedAndKeptOutOfBackups() throws {
        NotesStore(url: file).upsert(id: UUID(), text: "private")
        let values = try file.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
    }

    func testAnInMemoryStoreWritesNoFile() {
        let store = NotesStore(url: nil)
        store.upsert(id: UUID(), text: "only in memory")
        XCTAssertEqual(store.count, 1)
        XCTAssertEqual(NotesStore(url: file).count, 0)
    }

    // MARK: Which words are a note

    private func scratch() -> (NoteCapture, NotesStore) { (NoteCapture(), NotesStore(url: file)) }

    func testANormalTurnIsOneNote() {
        var (turn, store) = scratch()
        XCTAssertNotNil(turn.save("buy milk", from: 0, in: store))
        XCTAssertEqual(store.load().map(\.text), ["buy milk"])
    }

    func testSpeakingOnWhileTheModelWaitsGrowsTheSameNote() {
        var (turn, store) = scratch()
        _ = turn.save("buy milk", from: 0, in: store)
        _ = turn.save("buy milk and eggs", from: 0, in: store)
        XCTAssertEqual(store.load().map(\.text), ["buy milk and eggs"])
    }

    func testAfterAFinishedAnswerTheNextWordsAreAnotherNoteInTheSameGroup() {
        var (turn, store) = scratch()
        _ = turn.save("shopping list for my kid", from: 0, in: store)
        turn.settle()                                                 // the preview appeared
        _ = turn.save("item 1", from: 5, in: store)
        turn.settle()
        _ = turn.save("item 2", from: 7, in: store)
        let notes = store.load()
        XCTAssertEqual(notes.map(\.text), ["shopping list for my kid", "item 1", "item 2"])
        XCTAssertEqual(Set(notes.map(\.groupID)).count, 1)
        XCTAssertNotNil(notes[0].groupID)
    }

    func testEveryMessageSurvivesARestart() {
        var (turn, store) = scratch()
        _ = turn.save("shopping list for my kid", from: 0, in: store)
        turn.settle()
        _ = turn.save("item 1", from: 5, in: store)
        let reopened = NotesStore(url: file)
        XCTAssertEqual(reopened.load().map(\.text), ["shopping list for my kid", "item 1"])
        XCTAssertEqual(reopened.groupText(of: reopened.load()[0].id), "shopping list for my kid\nitem 1")
    }

    func testANewTurnStartsANewGroup() {
        var (turn, store) = scratch()
        _ = turn.save("first", from: 0, in: store)
        turn.reset()
        _ = turn.save("second", from: 0, in: store)
        let notes = store.load()
        XCTAssertEqual(notes.map(\.text), ["first", "second"])
        XCTAssertNotEqual(notes[0].groupID, notes[1].groupID)
    }

    func testTasksAndReviewMarkerGoToTheWholeGroup() {
        var (turn, store) = scratch()
        _ = turn.save("heading", from: 0, in: store)
        turn.settle()
        _ = turn.save("item", from: 1, in: store)
        let first = store.load()[0].id
        store.setReviewPending(groupOf: first, true)
        XCTAssertTrue(store.load().allSatisfy(\.reviewPending))
        let task = UUID()
        store.attach(groupOf: first, taskIDs: [task])
        XCTAssertTrue(store.load().allSatisfy { $0.taskIDs == [task] })
    }

    func testAQuestionAboutSavedTasksLeavesNoNote() {
        var (turn, store) = scratch()
        _ = turn.save("what do I need today", from: 0, in: store)
        turn.dropIfQuestion(created: false, answeredFromTasks: true, in: store)
        XCTAssertEqual(store.count, 0)
    }

    func testANoteThatMadeTasksIsKept() {
        var (turn, store) = scratch()
        _ = turn.save("buy milk", from: 0, in: store)
        turn.dropIfQuestion(created: true, answeredFromTasks: false, in: store)
        XCTAssertEqual(store.count, 1)
    }

    func testANoteWithNoTasksAndNoQuestionIsKept() {
        var (turn, store) = scratch()
        _ = turn.save("mom's birthday is the fifth", from: 0, in: store)
        turn.dropIfQuestion(created: false, answeredFromTasks: false, in: store)
        XCTAssertEqual(store.count, 1)
    }

    func testAQuestionAskedAfterOtherNotesInTheGroupKeepsTheNotes() {
        var (turn, store) = scratch()
        _ = turn.save("buy milk", from: 0, in: store)
        turn.settle()
        _ = turn.save("why did you miss the eggs", from: 2, in: store)
        turn.dropIfQuestion(created: false, answeredFromTasks: true, in: store)
        XCTAssertEqual(store.count, 2)
    }
}

// MARK: - Lists typed one message at a time

@MainActor
final class NoteListReadingTests: XCTestCase {
    func testAHeadingAndBareItemLinesAreAListWithoutTheHeadingAsATask() {
        let r = NoteLists.read("groceries for the week\nmilk\nbread\neggs")
        XCTAssertEqual(r?.heading, "groceries for the week")
        XCTAssertEqual(r?.items, ["milk", "bread", "eggs"])
    }

    func testLinesThatStartWithAVerbAreAllItems() {
        let r = NoteLists.read("buy milk\nbread\neggs")
        XCTAssertNil(r?.heading)
        XCTAssertEqual(r?.items, ["buy milk", "bread", "eggs"])
    }

    func testSentencesAreNotAList() {
        XCTAssertNil(NoteLists.read("Meeting went well.\nsend the quote\nthe client is in Pune"))
    }

    func testAListWordInTheHeadingMakesOneItemEnough() {
        let r = NoteLists.read("shopping list for my kid\nDiapers")
        XCTAssertEqual(r?.heading, "shopping list for my kid")
        XCTAssertEqual(r?.items, ["Diapers"])
    }

    func testAHeadingThatStartsWithAnIngWordIsStillAHeading() {
        let r = NoteLists.read("shopping list for my kid\ndiapers\nwipes")
        XCTAssertEqual(r?.heading, "shopping list for my kid")
        XCTAssertEqual(r?.items, ["diapers", "wipes"])
    }

    func testABareListHeadingWaitsForItsItems() {
        XCTAssertTrue(NoteLists.isBareHeading("shopping list for my kid"))
        XCTAssertTrue(NoteLists.isBareHeading("grocery list"))
        XCTAssertFalse(NoteLists.isBareHeading("create a shopping list for my kid"))
        XCTAssertFalse(NoteLists.isBareHeading("buy milk"))
        XCTAssertFalse(NoteLists.isBareHeading("shopping list for tomorrow"))
    }

    func testTwoLinesAreNotAList() {
        XCTAssertNil(NoteLists.read("groceries\nmilk"))
    }
}
