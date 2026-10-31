import XCTest
@testable import Kitty

/// The flat task extraction (`PathProfile.flat`), SCRIPTED: no model is called, so none of this says the model extracts well; the
/// real-model matrix (`SplitMatrixTests`, `REAL_MODEL_FLAT_EXTRACTION.md`) measures that. What is checked here is the Swift side of the
/// brief: each field the model returns lands in the one place it belongs, Swift (not the model) works out dates, times, repeats and
/// lists, an invalid answer makes nothing, a question can wait beside the tasks, long requests are batched at list boundaries, and
/// nothing is saved without approval.

@MainActor
private final class FlatEngine: DecisionProviding {
    var answers: [ExtractionValue?] = []
    var reviews: [DraftEditValue] = []
    var prompts: [String] = []
    var window: Int?
    var lastFailure: String?
    /// The flat edit call, scripted: used when `flatEdit` is true.
    var edits: [FlatEditValue?] = []
    var editPrompts: [String] = []
    var flatEdit = false
    var usesFlatEdit: Bool { flatEdit }

    var intents: [FlatIntentValue?] = []
    var intentPrompts: [String] = []

    /// The content question, scripted: the model's own words, shown as given.
    var questions: [String?] = []
    var questionPrompts: [String] = []

    func contentQuestion(prompt: String) async -> String? {
        questionPrompts.append(prompt)
        guard !questions.isEmpty else { return nil }
        return questions.removeFirst()
    }

    func intent(prompt: String) async -> FlatIntentValue? {
        intentPrompts.append(prompt)
        guard !intents.isEmpty else { return nil }
        return intents.removeFirst()
    }

    func edit(prompt: String, draftWaits: Bool, recentShown: Bool) async -> FlatEditValue? {
        editPrompts.append(prompt)
        guard !edits.isEmpty else { return nil }
        return edits.removeFirst()
    }

    func extract(prompt: String, fresh: Bool) async -> BulkDecisionValue? {
        prompts.append(prompt)
        guard !answers.isEmpty, let a = answers.removeFirst() else { return nil }
        return BulkDecisionValue(wait: a.outcome == "wait", action: a.outcome, clarifyingQuestion: a.question ?? "", extraction: a)
    }

    func review(prompt: String) async -> DraftEditValue? { reviews.isEmpty ? nil : reviews.removeFirst() }

    func budget(_ kind: CallKind) async -> ContextBudget {
        ContextBudget(window: window ?? 4_096, instructions: window == nil ? 700 : 100, schema: window == nil ? 450 : 100, exact: false, reserve: 1_000, margin: 0)
    }
}

@MainActor
final class TaskExtractionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_793_000_000)      // Monday 26 October 2026

    private var gregorian: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    /// Wednesday 28 October 2026, noon UTC.
    private var wednesday: Date { gregorian.date(from: DateComponents(year: 2026, month: 10, day: 28, hour: 12))! }
    private func day(_ y: Int, _ m: Int, _ d: Int) -> Date { gregorian.date(from: DateComponents(year: y, month: m, day: d))! }

    private func make(_ engine: FlatEngine, sink: SaveSink? = nil) -> VoiceTurnManager {
        let turns = VoiceTurnManager(engine: engine, sink: sink ?? InMemorySaveSink(), knownCategories: { [] }, knownAssignees: { [] }, savedTasks: { [] })
        turns.profile = .flat
        return turns
    }

    private func task(_ title: String, list: String? = nil, schedule: String? = nil, assignee: String? = nil, date: String? = nil,
                      time: String? = nil, purpose: String? = nil, instructions: String? = nil) -> ExtractionTaskValue {
        ExtractionTaskValue(title: title, schedule: schedule, assignee: assignee, dueDate: date, dueTime: time, purpose: purpose,
                            instructions: instructions, listName: list)
    }

    private func create(_ tasks: [ExtractionTaskValue], list: String? = nil) -> ExtractionValue {
        ExtractionValue(outcome: "create", listName: list, question: nil, tasks: tasks, mayHaveMore: tasks.count >= 12)
    }

    private func proposal(_ result: TurnResult, file: StaticString = #filePath, line: UInt = #line) -> Proposal? {
        guard case .proposal(let p) = result else { XCTFail("expected a card, got \(result)", file: file, line: line); return nil }
        return p
    }

    private func save(_ p: Proposal, _ turns: VoiceTurnManager) async -> AgentReply? {
        guard turns.state.confirmation.consume(p.id) else { return nil }
        return await p.apply()
    }

    private func decoded(_ e: ExtractionValue) -> BulkValidated {
        BulkValidator.decode(BulkDecisionValue(action: e.outcome, extraction: e), context: ValidationContext(now: wednesday, calendar: gregorian))
    }

    private func items(_ e: ExtractionValue, file: StaticString = #filePath, line: UInt = #line) -> [DraftItem] {
        guard case .items(let items) = decoded(e) else { XCTFail("expected drafts, got \(decoded(e))", file: file, line: line); return [] }
        return items
    }

    // MARK: Each field lands in one place

    func testEveryFieldTheModelReturnsIsMappedToItsOwnPlace() {
        let drafts = items(create([task("Buy Cipcal tablets", assignee: "Rani", date: "2026-11-02", time: "5 pm",
                                        purpose: "calcium deficiency", instructions: "500 mg, one strip")]))
        XCTAssertEqual(drafts.count, 1)
        let i = drafts[0]
        XCTAssertEqual(i.title, "Buy Cipcal tablets")
        XCTAssertEqual(i.assignee, "Rani")
        XCTAssertEqual(i.due, day(2026, 11, 2))
        XCTAssertEqual(i.timeMinutes, 17 * 60)
        XCTAssertEqual(i.reason, "calcium deficiency", "purpose is the reason")
        XCTAssertEqual(i.instructions, "500 mg, one strip", "instructions have their own place")
        XCTAssertNil(i.notes, "instructions never go into the system notes")
        XCTAssertNil(i.schedule)
        XCTAssertEqual(i.kind, .task)
        XCTAssertTrue(i.unparsed.isEmpty)
        let planned = i.planned()
        XCTAssertEqual(planned.reason, "calcium deficiency")
        XCTAssertEqual(planned.instructions, "500 mg, one strip")
        XCTAssertNil(planned.notes)
    }

    func testAScheduleKeepsTheWordsAndBecomesARoutineSwiftCanRun() {
        let i = items(create([task("Water balcony plants", schedule: "every other week on Monday", assignee: "Househelp")]))[0]
        XCTAssertEqual(i.kind, .routine)
        XCTAssertEqual(i.schedule, "every other week on Monday", "the user's words are kept beside the parsed repeat")
        XCTAssertEqual(i.recurrence, RecurrenceSpec(weekdays: [2], everyNWeeks: 2))
        XCTAssertEqual(i.assignee, Assignee.normalize("Househelp"))
        XCTAssertTrue(i.unparsed.isEmpty)
    }

    func testAbsentFieldsAreNilNeverEmptyStrings() {
        let i = items(create([task("Buy milk", assignee: "  ", date: "", time: " ", purpose: "", instructions: "\n")]))[0]
        XCTAssertNil(i.assignee)
        XCTAssertNil(i.due)
        XCTAssertNil(i.timeMinutes)
        XCTAssertNil(i.reason)
        XCTAssertNil(i.instructions)
        XCTAssertNil(i.schedule)
        XCTAssertNil(i.listName)
        XCTAssertNil(i.softDue)
        XCTAssertTrue(i.unparsed.isEmpty)
    }

    func testAnUnsupportedScheduleIsKeptAsSaidAndFlaggedNotInvented() {
        let i = items(create([task("Take vitamins", schedule: "when I remember", instructions: "after food")]))[0]
        XCTAssertEqual(i.kind, .task, "not a routine: Swift cannot run it")
        XCTAssertNil(i.recurrence)
        XCTAssertEqual(i.schedule, "when I remember")
        XCTAssertEqual(i.unparsed["repeat"], "when I remember")
        XCTAssertTrue(i.needsFix)
        XCTAssertEqual(i.instructions, "after food", "the flag says nothing about the instructions")
        XCTAssertTrue((i.planned().notes ?? "").contains("Repeat not understood"))
        XCTAssertEqual(i.planned().instructions, "after food")
    }

    func testAScheduleThatIsADayIsWhenItIsDueNotHowOften() {
        let a = items(create([task("Order paneer", schedule: "tomorrow evening")]))[0]
        XCTAssertEqual(a.kind, .task)
        XCTAssertNil(a.recurrence)
        XCTAssertNil(a.schedule, "it is not a repeat")
        XCTAssertEqual(a.due, day(2026, 10, 29))
        XCTAssertEqual(a.slot, .evening)
        XCTAssertTrue(a.unparsed.isEmpty)
        let b = items(create([task("Clean the bathroom", schedule: "on Saturday", assignee: "Rani")]))[0]
        XCTAssertEqual(b.kind, .task)
        XCTAssertEqual(b.due, day(2026, 10, 31))
        let c = items(create([task("Pay rent", schedule: "every month on the 5th")]))[0]
        XCTAssertEqual(c.kind, .routine, "a real repeat is still a repeat")
        let d = items(create([task("Call mom", schedule: "when I remember")]))[0]
        XCTAssertEqual(d.unparsed["repeat"], "when I remember", "still flagged, never turned into a day")
        let e = items(create([task("Call mom", schedule: "tomorrow", date: "friday")]))[0]
        XCTAssertEqual(e.due, day(2026, 10, 30), "a day the model gave in the day field is not overwritten")
        XCTAssertEqual(e.unparsed["repeat"], "tomorrow")
    }

    func testAPurposeOrInstructionsTheUserNeverSaidAreNotKept() {
        func decodedWith(_ words: String, _ t: ExtractionTaskValue) -> [DraftItem] {
            let ctx = ValidationContext(now: wednesday, calendar: gregorian, transcript: words)
            guard case .items(let items) = BulkValidator.decode(BulkDecisionValue(action: "create", extraction: create([t])), context: ctx) else { return [] }
            return items
        }
        let invented = decodedWith("Buy milk and bread from Blinkit", task("Buy milk", purpose: "purchase", instructions: "from Blinkit"))
        XCTAssertNil(invented[0].reason, "\"purchase\" was never said")
        XCTAssertEqual(invented[0].instructions, "from Blinkit")
        XCTAssertNil(decodedWith("Water the plants every morning", task("Water the plants", purpose: "maintain plants", instructions: "water plants"))[0].reason)
        XCTAssertNil(decodedWith("Water the plants every morning", task("Water the plants", instructions: "water plants"))[0].instructions, "a repeat of the title is no instruction")
        let said = decodedWith("Buy Cipcal for calcium deficiency. Get 500 mg, one strip.", task("Buy Cipcal tablets", purpose: "calcium deficiency", instructions: "500 mg, one strip"))
        XCTAssertEqual(said[0].reason, "calcium deficiency")
        XCTAssertEqual(said[0].instructions, "500 mg, one strip")
        XCTAssertNil(decodedWith("Buy Cipcal for my bones", task("Buy Cipcal", purpose: "bone health"))[0].reason, "a paraphrase is not kept")
        XCTAssertEqual(decodedWith("Buy Cipcal for my bones", task("Buy Cipcal", purpose: "my bones"))[0].reason, "my bones")
        XCTAssertEqual(decodedWith("anything", task("Buy Cipcal", purpose: "calcium"))[0].reason, nil)
        XCTAssertEqual(items(create([task("Buy Cipcal", purpose: "calcium")]))[0].reason, "calcium", "without a transcript nothing is checked")
    }

    func testADayOrTimeSwiftCannotReadIsKeptAsGivenAndFlagged() {
        let i = items(create([task("Call the plumber", date: "whenever", time: "5")]))[0]
        XCTAssertNil(i.due, "never guessed")
        XCTAssertNil(i.timeMinutes)
        XCTAssertEqual(i.unparsed["date"], "whenever")
        XCTAssertEqual(i.unparsed["time"], "5")
        let tags = DraftProposals.tags(i).map(\.text)
        XCTAssertTrue(tags.contains { $0.contains("Day needs a fix") && $0.contains("whenever") }, "\(tags)")
        XCTAssertTrue(tags.contains { $0.contains("Time needs a fix") }, "\(tags)")
    }

    func testASoftTimeframeIsKeptAsSaidAndNeverBecomesADate() {
        let i = items(create([task("Plan the trip", date: "next week")]))[0]
        XCTAssertNil(i.due)
        XCTAssertEqual(i.softDue, "next week")
        XCTAssertTrue(i.unparsed.isEmpty)
        XCTAssertEqual(i.planned().softDue, "next week")
    }

    func testAPartOfTheDayInTheDayBecomesTheTimeOfDay() {
        let i = items(create([task("Call mom", date: "tomorrow evening")]))[0]
        XCTAssertEqual(i.due, day(2026, 10, 29))
        XCTAssertEqual(i.slot, .evening)
        XCTAssertNil(i.timeMinutes)
        let n = items(create([task("Lock the gate", date: "tonight")]))[0]
        XCTAssertEqual(n.due, day(2026, 10, 28))
        XCTAssertEqual(n.slot, .night)
    }

    func testAnExactTimeWinsOverAPartOfTheDay() {
        let i = items(create([task("Call mom", date: "tomorrow evening", time: "6:30 pm")]))[0]
        XCTAssertEqual(i.timeMinutes, 18 * 60 + 30)
        XCTAssertNil(i.slot)
    }

    // MARK: Validation, row by row

    func testABlankTitleDropsThatDraftOnly() {
        let drafts = items(create([task("   "), task("Buy milk")]))
        XCTAssertEqual(drafts.map(\.title), ["Buy milk"])
    }

    func testCreateWithNoUsableTaskIsAnInvalidResponse() {
        XCTAssertEqual(decoded(create([])), .clarify(BulkValidator.invalidAnswerQuestion))
        XCTAssertEqual(decoded(create([task("  ")])), .noContent, "a task with no words in its title asks what to add")
    }

    func testClarifyWithoutAQuestionIsAnInvalidResponse() {
        let e = ExtractionValue(outcome: "clarify", listName: nil, question: nil, tasks: [task("Buy Cipcal tablets")])
        XCTAssertEqual(decoded(e), .clarify(BulkValidator.invalidAnswerQuestion))
        let blank = ExtractionValue(outcome: "clarify", listName: nil, question: "  ", tasks: [task("Buy Cipcal tablets")])
        XCTAssertEqual(decoded(blank), .clarify(BulkValidator.invalidAnswerQuestion))
    }

    func testWaitCreatesNothingAndAsksNothing() {
        XCTAssertEqual(decoded(ExtractionValue(outcome: "wait", listName: nil, question: "Anything else?", tasks: [task("Buy milk")])), .wait)
    }

    func testAnUnknownOutcomeIsInvalid() {
        XCTAssertEqual(decoded(ExtractionValue(outcome: "delete", tasks: [task("Buy milk")])), .clarify(BulkValidator.invalidAnswerQuestion))
    }

    func testIdenticalDraftsAreCombinedWithANoteAndDifferentOnesAreNot() {
        let same = items(create([task("Buy milk"), task("Buy milk")]))
        XCTAssertEqual(same.count, 1)
        XCTAssertEqual(same[0].advisories, ["Combined 2 identical items"])
        let differ = items(create([task("Buy milk", instructions: "2 litres"), task("Buy milk", instructions: "1 litre")]))
        XCTAssertEqual(differ.count, 2, "any field that differs makes two requests")
        let lists = items(create([task("Buy milk", list: "Blinkit"), task("Buy milk", list: "Zepto")]))
        XCTAssertEqual(lists.count, 2, "the same title on two lists is two tasks")
    }

    func testAListNamedOnTheResponseBelongsToEveryTaskOfIt() {
        let drafts = items(create([task("Buy A"), task("Buy B")], list: "Pharmacy"))
        XCTAssertEqual(drafts.map(\.listName), ["Pharmacy", "Pharmacy"])
    }

    // MARK: Resolvers

    func testDatesAreWorkedOutBySwiftFromTheDevicesCalendar() {
        func read(_ s: String) -> DateReading { DateResolver.read(s, now: wednesday, calendar: gregorian) }
        XCTAssertEqual(read("today"), .day(day(2026, 10, 28)))
        XCTAssertEqual(read("tomorrow"), .day(day(2026, 10, 29)))
        XCTAssertEqual(read("day after tomorrow"), .day(day(2026, 10, 30)))
        XCTAssertEqual(read("in 3 days"), .day(day(2026, 10, 31)))
        XCTAssertEqual(read("in 2 weeks"), .day(day(2026, 11, 11)))
        XCTAssertEqual(read("friday"), .day(day(2026, 10, 30)))
        XCTAssertEqual(read("next monday"), .day(day(2026, 11, 2)))
        XCTAssertEqual(read("wednesday"), .day(day(2026, 11, 4)), "a bare weekday is the next one, not today")
        XCTAssertEqual(read("this wednesday"), .day(day(2026, 10, 28)))
        XCTAssertEqual(read("2026-11-02"), .day(day(2026, 11, 2)))
        XCTAssertEqual(read("november 2"), .day(day(2026, 11, 2)))
        XCTAssertEqual(read("2nd of November"), .day(day(2026, 11, 2)))
        XCTAssertEqual(read("nov 2 2027"), .day(day(2027, 11, 2)))
        XCTAssertEqual(read("the 5th"), .day(day(2026, 11, 5)))
        XCTAssertEqual(read("next week"), .soft("next week"))
        XCTAssertEqual(read("end of the month"), .soft("end of the month"))
        XCTAssertEqual(read("whenever"), .invalid)
        XCTAssertEqual(read("february 30"), .invalid)
    }

    func testTimesAreWorkedOutBySwift() {
        XCTAssertEqual(TimeResolver.read("5 pm"), .minutes(17 * 60))
        XCTAssertEqual(TimeResolver.read("5:30pm"), .minutes(17 * 60 + 30))
        XCTAssertEqual(TimeResolver.read("17:30"), .minutes(17 * 60 + 30))
        XCTAssertEqual(TimeResolver.read("at 9 am"), .minutes(9 * 60))
        XCTAssertEqual(TimeResolver.read("12 am"), .minutes(0))
        XCTAssertEqual(TimeResolver.read("12 pm"), .minutes(12 * 60))
        XCTAssertEqual(TimeResolver.read("noon"), .minutes(12 * 60))
        XCTAssertEqual(TimeResolver.read("evening"), .slot(.evening))
        XCTAssertEqual(TimeResolver.read("5"), .invalid, "a bare number is not a time")
        XCTAssertEqual(TimeResolver.read("25:00"), .invalid)
        XCTAssertEqual(TimeResolver.read("13 pm"), .invalid)
    }

    func testTheRepeatsSwiftCanRunAreReadAndTheRestAreNot() {
        func spec(_ s: String) -> RecurrenceSpec? { if case .spec(let r, _, _) = RecurrenceParser.read(s) { return r } else { return nil } }
        XCTAssertEqual(spec("daily"), RecurrenceSpec())
        XCTAssertEqual(spec("every day"), RecurrenceSpec())
        XCTAssertEqual(spec("every morning"), RecurrenceSpec())
        XCTAssertEqual(spec("every weekday"), RecurrenceSpec(weekdays: [2, 3, 4, 5, 6]))
        XCTAssertEqual(spec("every weekend"), RecurrenceSpec(weekdays: [1, 7]))
        XCTAssertEqual(spec("every Monday and Thursday"), RecurrenceSpec(weekdays: [2, 5]))
        XCTAssertEqual(spec("mondays and thursdays"), RecurrenceSpec(weekdays: [2, 5]))
        XCTAssertEqual(spec("Monday to Friday except Wednesday"), RecurrenceSpec(weekdays: [2, 3, 5, 6]))
        XCTAssertEqual(spec("every day except Sunday"), RecurrenceSpec(weekdays: [2, 3, 4, 5, 6, 7]))
        XCTAssertEqual(spec("every other day"), RecurrenceSpec(intervalDays: 2))
        XCTAssertEqual(spec("alternate days"), RecurrenceSpec(intervalDays: 2))
        XCTAssertEqual(spec("every 3 days"), RecurrenceSpec(intervalDays: 3))
        XCTAssertEqual(spec("every other week on Saturday"), RecurrenceSpec(weekdays: [7], everyNWeeks: 2))
        XCTAssertEqual(spec("every 2 weeks on Monday"), RecurrenceSpec(weekdays: [2], everyNWeeks: 2))
        XCTAssertEqual(spec("weekly on Friday"), RecurrenceSpec(weekdays: [6]))
        XCTAssertEqual(spec("monthly on the 5th"), RecurrenceSpec(dayOfMonth: 5))
        XCTAssertEqual(spec("on the 5th of every month"), RecurrenceSpec(dayOfMonth: 5))
        XCTAssertEqual(RecurrenceParser.read("once"), .once)

        // A time or a part of the day inside the words is kept for the task.
        if case .spec(_, let slot, _) = RecurrenceParser.read("every morning") { XCTAssertEqual(slot, .morning) } else { XCTFail() }
        if case .spec(let r, _, let minutes) = RecurrenceParser.read("every day at 8 pm") {
            XCTAssertEqual(r, RecurrenceSpec())
            XCTAssertEqual(minutes, 20 * 60)
        } else { XCTFail("every day at 8 pm") }

        for unsupported in ["twice a day", "3 times a week", "when I remember", "every day after lunch", "weekly", "every month",
                            "monday", "every full moon", "every 3rd day", "every weekday except", "every other week"] {
            XCTAssertEqual(RecurrenceParser.read(unsupported), .unsupported, unsupported)
        }
    }

    // MARK: Lists, made once on approval

    private func scratchStore() -> (TaskStore, UserDefaults, String) {
        let suite = "TaskExtractionTests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        return (TaskStore(defaults: defaults), defaults, suite)
    }

    func testAListIsMadeOnceForTheRequestAndItsTasksLiveOnIt() {
        let (store, defaults, suite) = scratchStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let request = UUID()
        func planned(_ title: String, _ list: String?) -> PlannedTask {
            PlannedTask(title: title, category: nil, due: nil, profile: list, utteranceID: request)
        }
        let made = store.addMany([planned("Buy Cetaphil", "Pharmacy"), planned("Buy Teddybar", "Pharmacy"), planned("Buy Cipcal", "pharmacy"),
                                  planned("Call mom", nil)])
        XCTAssertEqual(made.count, 4)
        XCTAssertEqual(store.profiles.map(\.name), ["Pharmacy"], "one list, named as the user said it (no \"list\" added)")
        XCTAssertEqual(store.profiles.first?.requestID, request)
        let list = store.profiles[0]
        XCTAssertEqual(made.filter { $0.profileID == list.id }.map(\.title), ["Buy Cetaphil", "Buy Teddybar", "Buy Cipcal"])
        XCTAssertTrue(made.filter { $0.profileID == list.id }.allSatisfy { $0.dueDate == nil && $0.isListItem && $0.group == "Pharmacy" })
        XCTAssertNil(made.first { $0.title == "Call mom" }?.profileID)
        XCTAssertNil(made.first { $0.title == "Call mom" }?.dueDate, "a day nobody said is not made up: the task is undated")
        XCTAssertNil(made.first { $0.title == "Call mom" }?.category, "a category nobody said is not guessed")
    }

    func testAnExistingListIsJoinedNotMadeAgain() {
        let (store, defaults, suite) = scratchStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        store.ensureProfile("Pharmacy list")
        let made = store.addMany([PlannedTask(title: "Buy Cipcal", category: .health, due: nil, profile: "Pharmacy")])
        XCTAssertEqual(store.profiles.count, 1)
        XCTAssertEqual(made.first?.profileID, store.profiles.first?.id)
        XCTAssertEqual(store.profiles.first?.name, "Pharmacy list", "the stored name is not rewritten")
    }

    func testNothingIsMadeForADraft() async {
        let (store, defaults, suite) = scratchStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let engine = FlatEngine(), sink = InMemorySaveSink()
        engine.answers = [create([task("Buy Cipcal", list: "Pharmacy")])]
        let turns = make(engine, sink: sink)
        guard proposal(await turns.decide(utterance: "Pharmacy list: buy Cipcal", now: now, final: true)) != nil else { return }
        XCTAssertTrue(store.profiles.isEmpty, "a list is made when the draft is approved, never while it is a draft")
        XCTAssertTrue(sink.tasks.isEmpty)
    }

    func testTheReviewCardGroupsTasksByListAndSaysWhichListIsNew() async {
        let engine = FlatEngine()
        engine.answers = [create([task("Buy Cetaphil", list: "Pharmacy"), task("Buy Teddybar", list: "Pharmacy"), task("Call mom")])]
        let turns = make(engine)
        guard let p = proposal(await turns.decide(utterance: "Pharmacy list: Cetaphil, Teddybar. Also call mom", now: now, final: true)) else { return }
        XCTAssertEqual(p.sections.count, 2)
        XCTAssertEqual(p.sections[0].listName, "Pharmacy")
        XCTAssertEqual(p.sections[0].subtitle, "New list · 2 tasks")
        XCTAssertTrue(p.sections[0].isNew)
        XCTAssertEqual(p.sections[0].rows.map(\.title), ["Buy Cetaphil", "Buy Teddybar"])
        XCTAssertNil(p.sections[1].listName)
        XCTAssertEqual(p.sections[1].rows.map(\.title), ["Call mom"])
        XCTAssertEqual(p.title, "Save 3 tasks in 1 list")
        XCTAssertEqual(p.rows.count, 3, "the flat rows stay for voice and the tests")
    }

    func testAFlatCardStaysFlatWhenNoTaskNamesAList() async {
        let engine = FlatEngine()
        engine.answers = [create([task("Buy milk"), task("Call mom")])]
        let turns = make(engine)
        guard let p = proposal(await turns.decide(utterance: "Buy milk and call mom", now: now, final: true)) else { return }
        XCTAssertTrue(p.sections.isEmpty)
        XCTAssertEqual(p.title, "Save 2 tasks")
    }

    // MARK: The five examples of the brief

    func testExampleOneTimeList() async {
        let engine = FlatEngine(), sink = InMemorySaveSink()
        engine.answers = [create([task("Buy Cetaphil body lotion"), task("Buy Teddybar soap"), task("Buy Cipcal tablets")], list: "Pharmacy")]
        let turns = make(engine, sink: sink)
        guard let p = proposal(await turns.decide(utterance: "Pharmacy list: buy Cetaphil body lotion, Teddybar soap, and Cipcal tablets.", now: now, final: true)) else { return }
        XCTAssertEqual(engine.prompts.count, 1)
        XCTAssertEqual(turns.state.drafts.items.count, 3)
        XCTAssertTrue(turns.state.drafts.items.allSatisfy { $0.kind == .task && $0.schedule == nil && $0.recurrence == nil && $0.listName == "Pharmacy" })
        XCTAssertTrue(sink.tasks.isEmpty)
        _ = await save(p, turns)
        XCTAssertEqual(sink.tasks.count, 3)
        XCTAssertTrue(sink.tasks.allSatisfy { $0.profile == "Pharmacy" && $0.recurrence == nil })
    }

    func testARepeatTheModelLeftOutIsReadFromTheWords() async {
        let engine = FlatEngine()
        engine.answers = [create([task("Water the plants")])]
        let turns = make(engine, sink: InMemorySaveSink())
        _ = proposal(await turns.decide(utterance: "water the plants every morning", now: now, final: true))
        XCTAssertEqual(turns.state.drafts.items.first?.kind, .routine)
        XCTAssertEqual(turns.state.drafts.items.first?.title, "Water the plants")
    }

    func testARepeatLeftInTheTitleIsCutOutOfIt() async {
        let engine = FlatEngine()
        engine.answers = [create([task("Water the plants every day")])]
        let turns = make(engine, sink: InMemorySaveSink())
        _ = proposal(await turns.decide(utterance: "Water the plants every day", now: now, final: true))
        XCTAssertEqual(turns.state.drafts.items.first?.kind, .routine)
        XCTAssertEqual(turns.state.drafts.items.first?.title, "Water the plants")

        let unreadable = FlatEngine()
        unreadable.answers = [create([task("RO service every three months")])]
        let other = make(unreadable, sink: InMemorySaveSink())
        _ = proposal(await other.decide(utterance: "RO service every three months", now: now, final: true))
        XCTAssertNotEqual(other.state.drafts.items.first?.kind, .routine, "a repeat the parser cannot read is never turned into a daily one")
    }

    func testOnlyTheTaskWhoseWordsSayHowOftenBecomesARoutine() async {
        let engine = FlatEngine()
        engine.answers = [create([task("Clean the baby mat"), task("Wash clothes"), task("Buy diapers")])]
        let turns = make(engine, sink: InMemorySaveSink())
        _ = proposal(await turns.decide(utterance: "household list clean the baby mat every day, wash clothes, buy diapers", now: now, final: true))
        let items = turns.state.drafts.items
        XCTAssertEqual(items.map(\.kind), [.routine, .task, .task])
    }

    func testExampleRecurringTask() async {
        let engine = FlatEngine(), sink = InMemorySaveSink()
        engine.answers = [create([task("Water balcony plants", schedule: "every morning", assignee: "Househelp")])]
        let turns = make(engine, sink: sink)
        guard let p = proposal(await turns.decide(utterance: "Every morning, have the househelp water the balcony plants.", now: now, final: true)) else { return }
        XCTAssertEqual(turns.state.drafts.items.count, 1, "one task, not copies for each day")
        XCTAssertEqual(turns.state.drafts.items[0].kind, .routine)
        _ = await save(p, turns)
        XCTAssertEqual(sink.routines.count, 1)
        XCTAssertEqual(sink.routines[0].schedule, "every morning")
        XCTAssertEqual(sink.routines[0].recurrence, RecurrenceSpec())
        XCTAssertEqual(sink.routines[0].slot, .morning)
    }

    func testExamplePurposeAndInstructions() async {
        let engine = FlatEngine(), sink = InMemorySaveSink()
        engine.answers = [create([task("Buy Cipcal tablets", purpose: "calcium deficiency", instructions: "500 mg, one strip")])]
        let turns = make(engine, sink: sink)
        guard let p = proposal(await turns.decide(utterance: "Buy Cipcal for calcium deficiency. Get 500 mg, one strip.", now: now, final: true)) else { return }
        _ = await save(p, turns)
        XCTAssertEqual(sink.tasks.count, 1)
        XCTAssertEqual(sink.tasks[0].title, "Buy Cipcal tablets")
        XCTAssertEqual(sink.tasks[0].reason, "calcium deficiency")
        XCTAssertEqual(sink.tasks[0].instructions, "500 mg, one strip")
        XCTAssertNil(sink.tasks[0].schedule)
        XCTAssertNil(sink.tasks[0].notes)
    }

    func testExampleEssentialClarificationShowsTheTaskBesideTheQuestionAndAnAnswerUpdatesIt() async {
        let engine = FlatEngine(), sink = InMemorySaveSink()
        let question = "What dosage and how many Cipcal tablets should I add?"
        engine.answers = [ExtractionValue(outcome: "clarify", listName: nil, question: question, tasks: [task("Buy Cipcal tablets")])]
        let turns = make(engine, sink: sink)
        let first = "Buy Cipcal."
        guard let p = proposal(await turns.decide(utterance: first, now: now, final: true)) else { return }
        XCTAssertEqual(p.rows.map(\.title), ["Buy Cipcal tablets"], "the task is shown, not held back")
        XCTAssertEqual(p.prompt, question)
        XCTAssertNil(p.recovery)
        XCTAssertTrue(turns.state.questionBesidePreview, "the question stays open beside the task")
        XCTAssertTrue(sink.tasks.isEmpty)

        // The answer changes the preview through the review call; the extraction is not asked again.
        engine.reviews = [DraftEditValue(action: "change", edits: [DraftEditOpValue(refs: ["d1"], instructions: "500 mg, one strip")])]
        guard let again = proposal(await turns.decide(utterance: first + " 500 mg, one strip", now: now, final: true)) else { return }
        XCTAssertEqual(engine.prompts.count, 1)
        XCTAssertEqual(turns.state.drafts.items.first?.instructions, "500 mg, one strip")
        XCTAssertTrue(sink.tasks.isEmpty, "answering does not save")
        _ = await save(again, turns)
        XCTAssertEqual(sink.tasks.first?.instructions, "500 mg, one strip")
    }

    func testClarifyingTasksCanBeSavedWithoutAnswering() async {
        let engine = FlatEngine(), sink = InMemorySaveSink()
        engine.answers = [ExtractionValue(outcome: "clarify", listName: nil, question: "How many tablets?", tasks: [task("Buy Cipcal tablets")])]
        let turns = make(engine, sink: sink)
        guard let p = proposal(await turns.decide(utterance: "Buy Cipcal.", now: now, final: true)) else { return }
        let reply = await save(p, turns)
        XCTAssertNotNil(reply)
        XCTAssertEqual(sink.tasks.map(\.title), ["Buy Cipcal tablets"], "Save stays available beside the question")
    }

    func testExampleNoUnnecessaryClarificationResolvesTomorrowInSwift() async {
        let engine = FlatEngine(), sink = InMemorySaveSink()
        engine.answers = [create([task("Buy milk", date: "tomorrow")])]
        let turns = make(engine, sink: sink)
        guard let p = proposal(await turns.decide(utterance: "Buy milk tomorrow.", now: now, final: true)) else { return }
        let expected = Calendar.current.startOfDay(for: Calendar.current.date(byAdding: .day, value: 1, to: now)!)
        XCTAssertEqual(turns.state.drafts.items.first?.due, expected)
        XCTAssertNil(p.prompt.flatMap { $0.contains("?") && !$0.lowercased().contains("save") ? $0 : nil }, "no question")
        XCTAssertFalse(engine.prompts[0].contains("2026"), "the model is never given a date to calculate from")
    }

    // MARK: The prompt, the budget and the batches

    func testTheModelIsSentTheWordsAndNothingElse() async {
        let engine = FlatEngine()
        engine.answers = [create([task("Buy milk")])]
        let turns = make(engine)
        let said = "Buy milk and bread from Blinkit"
        _ = await turns.decide(utterance: said, now: now, final: true)
        XCTAssertEqual(engine.prompts, [FlatPrompt.build(words: said)])
        XCTAssertEqual(FlatPrompt.build(words: said), "Request:\n" + said)
    }

    func testAnOrdinaryThreeItemRequestIsNeverSplit() async {
        let engine = FlatEngine()
        engine.answers = [create([task("Buy milk"), task("Buy bread"), task("Buy eggs")])]
        let turns = make(engine)
        _ = await turns.decide(utterance: "Buy milk, bread and eggs", now: now, final: true)
        XCTAssertEqual(engine.prompts.count, 1)
        XCTAssertEqual(turns.state.drafts.items.count, 3)
    }

    func testTwoExplicitListsAreTwoCallsAndOneReview() async {
        let engine = FlatEngine(), sink = InMemorySaveSink()
        let pharmacy = ["Buy Cetaphil", "Buy Teddybar", "Buy Cipcal"]
        let grocery = (1...10).map { "Buy item \($0)" }
        engine.answers = [create(pharmacy.map { task($0) }, list: "Pharmacy"), create(grocery.map { task($0) }, list: "Grocery")]
        let turns = make(engine, sink: sink)
        let said = "Pharmacy list: Cetaphil, Teddybar, Cipcal. Grocery list: " + (1...10).map { "item \($0)" }.joined(separator: ", ") + "."
        guard let p = proposal(await turns.decide(utterance: said, now: now, final: true)) else { return }
        XCTAssertEqual(engine.prompts.count, 2, "one call per list")
        XCTAssertTrue(engine.prompts[0].contains("Pharmacy list") && !engine.prompts[0].contains("Grocery"))
        XCTAssertTrue(engine.prompts[1].contains("Grocery list") && !engine.prompts[1].contains("Pharmacy"))
        XCTAssertEqual(turns.state.drafts.items.count, 13)
        XCTAssertEqual(p.sections.map(\.listName), ["Pharmacy", "Grocery"])
        XCTAssertEqual(p.sections.map { $0.rows.count }, [3, 10])
        XCTAssertEqual(p.title, "Save 13 tasks in 2 lists")
        XCTAssertTrue(sink.tasks.isEmpty, "one review, then one save")
        _ = await save(p, turns)
        XCTAssertEqual(sink.tasks.count, 13)
        XCTAssertEqual(Set(sink.tasks.compactMap(\.profile)), ["Pharmacy", "Grocery"])
    }

    func testAListNamedInASentenceIsNotABoundary() {
        XCTAssertTrue(FlatBatcher.listSegments("Add milk to my grocery list and bread to my shopping list").isEmpty)
        XCTAssertEqual(FlatBatcher.perList("Pharmacy list: a, b. Grocery list: c, d."), ["Pharmacy list: a, b. ", "Grocery list: c, d."])
        XCTAssertEqual(FlatBatcher.perList("Pharmacy list: a, b. Grocery list: c, d.").joined(), "Pharmacy list: a, b. Grocery list: c, d.", "nothing is cut")
    }

    func testTwelveTasksBackMeansThereMayBeMoreAndTheCardSaysSo() async {
        let engine = FlatEngine()
        engine.answers = [create((1...12).map { task("Buy thing \($0)") })]
        let turns = make(engine)
        guard let p = proposal(await turns.decide(utterance: "A long list of things to do", now: now, final: true)) else { return }
        XCTAssertEqual(turns.state.drafts.items.count, 12)
        XCTAssertTrue(p.rows.last?.tags.contains { $0.text.contains("most I read at once") } ?? false)
    }

    func testWordsThatDoNotFitTheWindowAreReadInWholeSentences() async {
        let engine = FlatEngine()
        engine.window = 1_300
        let sentences = (1...8).map { "Please remember to buy number \($0) item for the house and put it away." }
        engine.answers = (1...8).map { create([task("Buy thing \($0)")]) }
        let turns = make(engine)
        let said = sentences.joined(separator: " ")
        guard proposal(await turns.decide(utterance: said, now: now, final: true)) != nil else { return }
        XCTAssertGreaterThan(engine.prompts.count, 1, "too long for one call: read in parts")
        XCTAssertLessThanOrEqual(engine.prompts.count, 8)
        XCTAssertEqual(turns.state.drafts.items.count, engine.prompts.count)
        let words = engine.prompts.map { $0.replacingOccurrences(of: "Request:\n", with: "") }.joined(separator: " ")
        func squash(_ t: String) -> String { t.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ") }
        XCTAssertEqual(squash(words), squash(said), "nothing is cut and nothing is left out")
    }

    func testWhenNothingFitsTheUserIsAskedToContinueAndNothingIsSent() async {
        let engine = FlatEngine()
        engine.window = 1_150           // the instructions, schema and answer reserve alone fill it
        let turns = make(engine)
        let result = await turns.decide(utterance: "Buy milk and bread", now: now, final: true)
        guard case .reply(let r) = result else { return XCTFail("\(result)") }
        XCTAssertTrue(r.message.contains("more than I can read"), r.message)
        XCTAssertTrue(engine.prompts.isEmpty)
        XCTAssertTrue(turns.state.drafts.items.isEmpty)
    }

    func testTheBudgetIsTheWholeCallAgainstTheWindow() {
        let b = TokenBudgetService(contextSize: 4_096, instructions: 500, schema: 450, tools: 0, exact: true)
        XCTAssertEqual(b.reserve, 1_000)
        XCTAssertEqual(b.projected(prompt: 200, transcript: 50), 500 + 200 + 0 + 450 + 50 + 1_000)
        XCTAssertEqual(b.promptRoom, 4_096 - 500 - 450 - 1_000)
        XCTAssertTrue(b.fits(prompt: b.promptRoom))
        XCTAssertFalse(b.fits(prompt: b.promptRoom + 1))
    }

    func testTheModelNeverGetsASchemaFieldItMustNotWrite() {
        let text = TaskExtractionInstructions.text
        XCTAssertTrue(text.contains("Return only context the user provided"))
        for forbidden in ["UUID", "timestamp", "category", "labels"] {
            XCTAssertFalse(text.replacingOccurrences(of: "Do not ask for category, labels", with: "").contains(forbidden), forbidden)
        }
    }

    // MARK: Approval, replay, failure

    func testNothingIsSavedWithoutApprovalAndReplayIsRejected() async {
        let engine = FlatEngine(), sink = InMemorySaveSink()
        engine.answers = [create([task("Buy milk")])]
        let turns = make(engine, sink: sink)
        guard let p = proposal(await turns.decide(utterance: "Buy milk", now: now, final: true)) else { return }
        XCTAssertTrue(sink.tasks.isEmpty)
        let first = await save(p, turns)
        XCTAssertNotNil(first)
        XCTAssertEqual(sink.tasks.count, 1)
        let second = await save(p, turns)
        XCTAssertNil(second, "the same approval cannot be used twice")
        let replay = await p.apply()
        XCTAssertEqual(replay.message, "Already saved.")
        XCTAssertEqual(sink.tasks.count, 1)
    }

    func testNoAnswerFromTheModelCreatesNothing() async {
        let engine = FlatEngine(), sink = InMemorySaveSink()
        engine.answers = [nil]
        let turns = make(engine, sink: sink)
        let result = await turns.decide(utterance: "Buy milk", now: now, final: true)
        guard case .reply(let r) = result else { return XCTFail("\(result)") }
        XCTAssertTrue(r.message.contains("didn't add anything"), r.message)
        XCTAssertTrue(sink.tasks.isEmpty)
    }

    func testInvalidCreateMakesNoDraft() async {
        let engine = FlatEngine(), sink = InMemorySaveSink()
        engine.answers = [create([])]
        let turns = make(engine, sink: sink)
        let result = await turns.decide(utterance: "Buy milk", now: now, final: true)
        if case .proposal = result { XCTFail("an invalid response must not become a card") }
        XCTAssertTrue(turns.state.drafts.items.isEmpty)
        XCTAssertTrue(sink.tasks.isEmpty)
    }

    // MARK: Edits keep the draft and add purpose and instructions

    func testAnEditCanSetAndClearPurposeAndInstructions() async {
        let engine = FlatEngine()
        engine.answers = [create([task("Buy Cipcal tablets", purpose: "calcium", instructions: "500 mg")])]
        let turns = make(engine)
        _ = await turns.decide(utterance: "Buy Cipcal", now: now, final: true)
        engine.reviews = [DraftEditValue(action: "change", edits: [DraftEditOpValue(refs: ["d1"], purpose: "bone health", instructions: "one strip")])]
        _ = await turns.decide(utterance: "Buy Cipcal it is for bone health, one strip", now: now, final: true)
        XCTAssertEqual(turns.state.drafts.items.first?.reason, "bone health")
        XCTAssertEqual(turns.state.drafts.items.first?.instructions, "one strip")
        engine.reviews = [DraftEditValue(action: "change", edits: [DraftEditOpValue(refs: ["d1"], clear: ["instructions"])])]
        _ = await turns.decide(utterance: "Buy Cipcal it is for bone health, one strip no instructions", now: now, final: true)
        XCTAssertNil(turns.state.drafts.items.first?.instructions)
        XCTAssertEqual(turns.state.drafts.items.first?.reason, "bone health", "a field the edit does not mention stays")
    }

    func testSettingAndClearingTheSameInstructionsIsRejected() {
        XCTAssertTrue(BulkDraftManager.contradicts(DraftEditOpValue(refs: ["d1"], instructions: "x", clear: ["instructions"])))
        XCTAssertTrue(BulkDraftManager.contradicts(DraftEditOpValue(refs: ["d1"], purpose: "x", clear: ["purpose"])))
        XCTAssertFalse(BulkDraftManager.contradicts(DraftEditOpValue(refs: ["d1"], purpose: "x", clear: ["instructions"])))
    }

    // MARK: Conversational edits of a draft that waits (flat path)

    func testAnItemAddedToAWaitingListJoinsThatList() async {
        let engine = FlatEngine(), sink = InMemorySaveSink()
        engine.answers = [create([task("Buy milk", list: "Blinkit order"), task("Buy bread", list: "Blinkit order")], list: "Blinkit order")]
        let turns = make(engine, sink: sink)
        _ = await turns.decide(utterance: "Add milk and bread to the Blinkit order", now: now, final: true)
        engine.reviews = [DraftEditValue(action: "change", add: [TaskDraftValue(title: "Buy eggs")])]
        _ = await turns.decide(utterance: "Add milk and bread to the Blinkit order and add eggs", now: now, final: true)
        let eggs = turns.state.drafts.items.first { $0.title == "Buy eggs" }
        XCTAssertNotNil(eggs, "the new item is in the draft")
        XCTAssertEqual(eggs?.listName, "Blinkit order", "an item added while one list waits belongs to that list")
    }

    // MARK: The flat edit of a draft that waits (scripted: nothing here says the model understands an edit)

    private func waiting(_ tasks: [ExtractionTaskValue], list: String? = nil, said: String = "Add milk and bread to the Blinkit order") async -> (FlatEngine, VoiceTurnManager) {
        let engine = FlatEngine()
        engine.flatEdit = true
        engine.answers = [create(tasks, list: list)]
        let turns = make(engine)
        _ = await turns.decide(utterance: said, now: now, final: true)
        return (engine, turns)
    }

    func testAnEditAddsAnItemToTheOnlyListOfTheDraft() async {
        let (engine, turns) = await waiting([task("Buy milk", list: "Blinkit order"), task("Buy bread", list: "Blinkit order")], list: "Blinkit order")
        engine.edits = [FlatEditValue(add: [task("Buy eggs", purpose: "breakfast", instructions: "two dozen")])]
        _ = await turns.decide(utterance: "Add milk and bread to the Blinkit order and add two dozen eggs for breakfast", now: now, final: true)
        let eggs = turns.state.drafts.items.first { $0.title == "Buy eggs" }
        XCTAssertEqual(eggs?.listName, "Blinkit order", "an item added while one list waits joins that list")
        XCTAssertEqual(eggs?.instructions, "two dozen", "an added item can carry instructions")
        XCTAssertEqual(eggs?.reason, "breakfast")
        XCTAssertEqual(turns.state.drafts.items.count, 3)
        XCTAssertEqual(engine.prompts.count, 1, "the edit is its own call, not another extraction")
        XCTAssertTrue(engine.editPrompts[0].contains("d1.") && engine.editPrompts[0].contains("Buy milk"), "the draft is shown by ref")
        XCTAssertFalse(engine.editPrompts[0].contains("Today:"), "the model is given no date")
    }

    func testAnAddedItemMayNameAnotherList() async {
        let (engine, turns) = await waiting([task("Buy milk", list: "Blinkit order")], list: "Blinkit order")
        engine.edits = [FlatEditValue(listName: "Pharmacy", add: [task("Buy Cipcal")])]
        _ = await turns.decide(utterance: "also add Cipcal to the pharmacy list", now: now, final: true)
        XCTAssertEqual(turns.state.drafts.items.first { $0.title == "Buy Cipcal" }?.listName, "Pharmacy")
    }

    func testAnEditResolvesTheDayAndTheTimeInSwift() async {
        let (engine, turns) = await waiting([task("Buy milk")], said: "Buy milk")
        engine.edits = [FlatEditValue(update: [FlatEditUpdateValue(target: "d1", dueDate: "Friday", dueTime: "5 pm")])]
        _ = await turns.decide(utterance: "make that Friday at 5 pm", now: now, final: true)
        let item = turns.state.drafts.items[0]
        XCTAssertEqual(item.due.map { Calendar.current.component(.weekday, from: $0) }, 6, "Friday, worked out by Swift")
        XCTAssertEqual(item.timeMinutes, 17 * 60)
        XCTAssertTrue(item.unparsed.isEmpty)
    }

    func testAnEditWithAPartOfTheDayAndASoftTimeframe() async {
        let (engine, turns) = await waiting([task("Buy milk"), task("Call Rani")], said: "Buy milk and call Rani")
        engine.edits = [FlatEditValue(update: [FlatEditUpdateValue(target: "d1", dueDate: "tomorrow evening"),
                                               FlatEditUpdateValue(target: "d2", dueDate: "next week")])]
        _ = await turns.decide(utterance: "milk tomorrow evening and call Rani next week", now: now, final: true)
        XCTAssertNotNil(turns.state.drafts.items[0].due)
        XCTAssertEqual(turns.state.drafts.items[0].slot, .evening)
        XCTAssertNil(turns.state.drafts.items[1].due, "a timeframe is not turned into a date")
        XCTAssertEqual(turns.state.drafts.items[1].softDue, "next week")
    }

    func testAnEditCanSetAndFlagARepeat() async {
        let (engine, turns) = await waiting([task("Take vitamins"), task("Water plants")], said: "Take vitamins and water plants")
        engine.edits = [FlatEditValue(update: [FlatEditUpdateValue(target: "d1", schedule: "every morning"),
                                               FlatEditUpdateValue(target: "d2", schedule: "when I remember")])]
        _ = await turns.decide(utterance: "vitamins every morning, water the plants when I remember", now: now, final: true)
        XCTAssertEqual(turns.state.drafts.items[0].kind, .routine)
        XCTAssertNotNil(turns.state.drafts.items[0].recurrence)
        XCTAssertEqual(turns.state.drafts.items[1].kind, .task)
        XCTAssertEqual(turns.state.drafts.items[1].unparsed["repeat"], "when I remember", "kept as said and flagged, not guessed")
    }

    func testAnEditCanMoveAnItemToAListAndTakeItOffAgain() async {
        let (engine, turns) = await waiting([task("Buy milk")], said: "Buy milk")
        engine.edits = [FlatEditValue(update: [FlatEditUpdateValue(target: "d1", listName: "Blinkit order")])]
        _ = await turns.decide(utterance: "put that on the Blinkit order", now: now, final: true)
        XCTAssertEqual(turns.state.drafts.items[0].listName, "Blinkit order")
        engine.edits = [FlatEditValue(update: [FlatEditUpdateValue(target: "d1", clear: ["list"])])]
        _ = await turns.decide(utterance: "take that off the list", now: now, final: true)
        XCTAssertNil(turns.state.drafts.items[0].listName)
    }

    func testAnEditUpdatesTitlePersonPurposeAndInstructionsAndKeepsTheRest() async {
        let (engine, turns) = await waiting([task("Buy Cipcal", date: "2026-11-02")], said: "Buy Cipcal on 2 November")
        engine.edits = [FlatEditValue(update: [FlatEditUpdateValue(target: "d1", title: "Buy Cipcal tablets", assignee: "Rani",
                                                                  purpose: "calcium", instructions: "500 mg")])]
        _ = await turns.decide(utterance: "buy Cipcal tablets for Rani, calcium, 500 mg", now: now, final: true)
        let i = turns.state.drafts.items[0]
        XCTAssertEqual(i.title, "Buy Cipcal tablets")
        XCTAssertEqual(i.assignee, "Rani")
        XCTAssertEqual(i.reason, "calcium")
        XCTAssertEqual(i.instructions, "500 mg")
        XCTAssertNotNil(i.due, "a field the edit does not mention stays")
    }

    func testAnEditRemovesAnItemByRef() async {
        let (engine, turns) = await waiting([task("Buy milk"), task("Buy bread")], said: "Buy milk and bread")
        engine.edits = [FlatEditValue(remove: ["d2"])]
        _ = await turns.decide(utterance: "drop the bread", now: now, final: true)
        XCTAssertEqual(turns.state.drafts.items.map(\.title), ["Buy milk"])
    }

    func testAnEditThatOnlyAnswersChangesNothing() async {
        let (engine, turns) = await waiting([task("Buy milk"), task("Buy bread")], said: "Buy milk and bread")
        engine.edits = [FlatEditValue(outcome: "answer", answer: "Two tasks.")]
        let result = await turns.decide(utterance: "how many are there", now: now, final: true)
        XCTAssertEqual(turns.state.drafts.items.count, 2)
        XCTAssertNotNil(proposal(result))
    }

    func testAnEditThatNamesARefThatIsNotThereChangesNothing() async {
        let (engine, turns) = await waiting([task("Buy milk")], said: "Buy milk")
        let version = turns.state.drafts.version
        engine.edits = [FlatEditValue(update: [FlatEditUpdateValue(target: "d9", title: "Nope")])]
        guard let p = proposal(await turns.decide(utterance: "rename the ninth", now: now, final: true)) else { return }
        XCTAssertEqual(turns.state.drafts.items.map(\.title), ["Buy milk"])
        XCTAssertEqual(turns.state.drafts.version, version)
        XCTAssertNotNil(p.recovery, "the card says it could not apply that")
    }

    func testNoAnswerFromTheEditCallKeepsTheDraft() async {
        let (engine, turns) = await waiting([task("Buy milk")], said: "Buy milk")
        engine.edits = [nil, nil]
        guard let p = proposal(await turns.decide(utterance: "make that Friday", now: now, final: true)) else { return }
        XCTAssertEqual(turns.state.drafts.items.map(\.title), ["Buy milk"])
        XCTAssertNotNil(p.recovery)
        XCTAssertEqual(engine.prompts.count, 1, "the whole transcript is not extracted again while a draft waits")
    }

    func testAnUnrelatedEditFallsThroughToTheOrdinaryExtraction() async {
        let (engine, turns) = await waiting([task("Buy milk")], said: "Buy milk")
        engine.edits = [FlatEditValue(outcome: "unrelated")]
        engine.answers = [create([task("Call the plumber")])]
        _ = await turns.decide(utterance: "also call the plumber", now: now, final: true)
        XCTAssertEqual(engine.prompts.count, 2, "the new words went to extraction")
        XCTAssertTrue(engine.prompts[1].contains("Request:\nalso call the plumber"), "the request is the new words")
        XCTAssertFalse(engine.prompts[1].contains("Request:\nBuy milk"), "the earlier words are not the request")
    }

    // MARK: A list named in the words

    func testAListNamedInTheWordsFindsTheListThatExists() {
        let lists = ["Blinkit order", "Pharmacy"]
        XCTAssertEqual(ListMention.existing(in: "Add milk and bread to the Blinkit order", among: lists), "Blinkit order")
        XCTAssertEqual(ListMention.existing(in: "put eggs on my blinkit list", among: lists), "Blinkit order", "the short name finds it")
        XCTAssertEqual(ListMention.existing(in: "add Cipcal to Pharmacy", among: lists), "Pharmacy")
        XCTAssertNil(ListMention.existing(in: "buy milk from Blinkit", among: lists), "not after to, on or in")
        XCTAssertNil(ListMention.existing(in: "add milk to the Zomato order", among: lists), "a list that does not exist is never made here")
        XCTAssertNil(ListMention.existing(in: "add milk", among: lists))
    }

    func testWhenTheModelNamesNoListTheWordsStillFindOneThatExists() {
        let e = create([task("Buy milk"), task("Buy bread")])
        let ctx = ValidationContext(now: wednesday, calendar: gregorian, transcript: "Add milk and bread to the Blinkit order", knownLists: ["Blinkit order"])
        guard case .items(let made) = BulkValidator.decode(BulkDecisionValue(action: "create", extraction: e), context: ctx) else { return XCTFail("expected drafts") }
        XCTAssertEqual(made.map(\.listName), ["Blinkit order", "Blinkit order"])
        let none = ValidationContext(now: wednesday, calendar: gregorian, transcript: "Add milk and bread to the Blinkit order")
        guard case .items(let plain) = BulkValidator.decode(BulkDecisionValue(action: "create", extraction: e), context: none) else { return XCTFail("expected drafts") }
        XCTAssertEqual(plain.map(\.listName), [nil, nil], "with no list that exists, nothing is invented")
    }

    func testAListTheModelInventsIsDroppedAndTheListInTheWordsIsUsed() {
        let e = create([task("Buy milk", list: "Dairy")])
        let ctx = ValidationContext(now: wednesday, calendar: gregorian, transcript: "Add milk to the Blinkit order", knownLists: ["Blinkit order"])
        guard case .items(let made) = BulkValidator.decode(BulkDecisionValue(action: "create", extraction: e), context: ctx) else { return XCTFail("expected drafts") }
        XCTAssertEqual(made.first?.listName, "Blinkit order", "\"Dairy\" is not in the words, so it is not used; the list the words name is")
    }

    // MARK: Evidence for a list, and pieces of one task

    private func decodeSaid(_ e: ExtractionValue, said: String, lists: [String] = []) -> [DraftItem] {
        let ctx = ValidationContext(now: wednesday, calendar: gregorian, transcript: said, knownLists: lists)
        guard case .items(let made) = BulkValidator.decode(BulkDecisionValue(action: "create", extraction: e), context: ctx) else { return [] }
        return made
    }

    func testAnExampleListNameTheModelCopiesIsNotUsed() {
        // The real model wrote "to the Blinkit order" and "my pharmacy list" for sentences with no list, from its own instructions.
        let said = "I want to order food from Swiggy today."
        let made = decodeSaid(create([task("order food from Swiggy", list: "to the Blinkit order")], list: "to the Blinkit order"), said: said,
                              lists: ["Blinkit order", "Pharmacy list"])
        XCTAssertEqual(made.map(\.listName), [nil], "a list that exists is not evidence")
        XCTAssertNil(ListNameGate.rejection("Blinkit order", words: "add milk and bread to the Blinkit order", known: []))
        XCTAssertNil(ListNameGate.rejection("grocery list", words: "for the grocery list atta five kg", known: []))
        XCTAssertNil(ListNameGate.rejection("Goa trip packing list", words: "packing list for the Goa trip sunscreen swimwear", known: []))
        XCTAssertNotNil(ListNameGate.rejection("Swiggy order", words: said, known: []), "the verb \"order\" is not a list cue")
        XCTAssertNotNil(ListNameGate.rejection("Blinkit order", words: "order groceries from Blinkit today", known: ["Blinkit order"]),
                        "a shop named with \"from\" is not a list")
        XCTAssertNotNil(ListNameGate.rejection("my pharmacy list", words: "pay the electricity bill", known: ["Pharmacy list"]))
    }

    func testMeIsTheModelsAnswerAndSwiftOnlyChecksIt() {
        let said = "I want to order food from Swiggy today."
        // The model writes Me, and "I" is in the words: kept, with the words as evidence.
        let kept = decodeSaid(create([task("order food from Swiggy", assignee: "Me")]), said: said)
        XCTAssertEqual(kept.first?.assignee, "Me")
        XCTAssertEqual(kept.first?.evidence["assignee"], "I")
        XCTAssertEqual(kept.first?.due, day(2026, 10, 28))
        // The model writes Me for a sentence that says nothing about the speaker: dropped.
        XCTAssertNil(decodeSaid(create([task("order food from Swiggy", assignee: "Me")]), said: "order food from Swiggy today").first?.assignee)
        // A placeholder is not a person.
        XCTAssertNil(decodeSaid(create([task("order food from Swiggy", assignee: "user")]), said: said).first?.assignee)
        // Swift does not fill a person: the model left it empty, so it stays empty.
        XCTAssertNil(decodeSaid(create([task("order food from Swiggy")]), said: said).first?.assignee)
    }

    func testPiecesOfOneSentenceAreNotTasks() {
        // The real model wrote six "tasks" for "I want to order food from Swiggy today."
        let pieces = ["order food from Swiggy", "today", "food", "order", "Swiggy", "today"].map { task($0) }
        let made = decodeSaid(create(pieces), said: "I want to order food from Swiggy today.")
        XCTAssertEqual(made.map(\.title), ["order food from Swiggy"])
        XCTAssertEqual(made.first?.due, day(2026, 10, 28), "\"today\" is the day of the one real task")
        // Two real tasks stay two.
        XCTAssertEqual(FragmentGuard.filter([task("Buy milk"), task("Buy bread")]).kept.count, 2)
        XCTAssertEqual(FragmentGuard.filter([task("Call the plumber"), task("Pay the electricity bill")]).dropped, [])
    }

    // MARK: Changing the last five saved tasks

    private func savedTurns(_ titles: [String], list: String? = nil) -> (FlatEngine, VoiceTurnManager, TaskStore, UserDefaults, String) {
        let (store, defaults, suite) = scratchStore()
        for title in titles {
            store.addMany([PlannedTask(title: title, category: .guess(from: title), due: nil, profile: list)])
            Thread.sleep(forTimeInterval: 0.002)          // each task gets its own creation time
        }
        let engine = FlatEngine()
        engine.flatEdit = true
        let turns = make(engine)
        turns.savedStore = store
        return (engine, turns, store, defaults, suite)
    }

    func testOnlyTheLastFiveCreatedAreOffered() {
        let (store, defaults, suite) = scratchStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        for n in 1...7 { store.addMany([PlannedTask(title: "Task \(n)", category: .guess(from: "x"), due: nil)]); Thread.sleep(forTimeInterval: 0.002) }
        let recent = TaskToolbox(store: store).recentFive()
        XCTAssertEqual(recent.map(\.ref), ["t1", "t2", "t3", "t4", "t5"])
        XCTAssertEqual(recent.map { $0.task.title }, ["Task 7", "Task 6", "Task 5", "Task 4", "Task 3"], "newest first, by creation time")
    }

    func testTheGateIsClosedForWordsThatCannotBeAboutASavedTask() {
        XCTAssertFalse(SavedEditGate.shouldAsk(words: "Buy bananas tomorrow", hasRecent: true, lists: []))
        XCTAssertFalse(SavedEditGate.shouldAsk(words: "make that Friday", hasRecent: false, lists: []), "nothing is saved")
        XCTAssertFalse(SavedEditGate.shouldAsk(words: "I just said add a task to buy bread and milk", hasRecent: true, lists: []), "just is not a reference")
        XCTAssertTrue(SavedEditGate.shouldAsk(words: "make that Friday", hasRecent: true, lists: []))
        XCTAssertTrue(SavedEditGate.shouldAsk(words: "delete the last one", hasRecent: true, lists: []))
        XCTAssertFalse(SavedEditGate.shouldAsk(words: "Call mom at 6", hasRecent: true, lists: []), "a saved title is not a cue")
        XCTAssertTrue(SavedEditGate.shouldAsk(words: "add bread to the Blinkit", hasRecent: true, lists: ["Blinkit order"]), "a recent list is named")
    }

    func testAClosedGateSpendsNoEditCall() async {
        let (engine, turns, _, defaults, suite) = savedTurns(["Call mom"])
        defer { defaults.removePersistentDomain(forName: suite) }
        engine.answers = [create([task("Buy bananas")])]
        _ = await turns.decide(utterance: "Buy bananas", now: now, final: true)
        XCTAssertTrue(engine.editPrompts.isEmpty)
        XCTAssertTrue(engine.intentPrompts.isEmpty, "no cue, so no intent call either")
        XCTAssertEqual(engine.prompts.count, 1)
    }

    func testAChangeToASavedTaskIsACardAndNeedsAYes() async {
        let (engine, turns, store, defaults, suite) = savedTurns(["Buy milk", "Call mom"])
        defer { defaults.removePersistentDomain(forName: suite) }
        let milk = store.tasks.first { $0.title == "Buy milk" }!
        let before = milk.dueDate
        // t1 is the newest: "Call mom". Buy milk is t2.
        engine.intents = [FlatIntentValue(intent: "change")]
        engine.edits = [FlatEditValue(update: [FlatEditUpdateValue(target: "t2", dueDate: "Friday", purpose: "breakfast")])]
        guard let p = proposal(await turns.decide(utterance: "make the milk for Friday, it is for breakfast", now: now, final: true)) else { return }
        XCTAssertTrue(engine.editPrompts[0].contains("t1. \"Call mom\"") && engine.editPrompts[0].contains("t2. \"Buy milk\""))
        XCTAssertEqual(p.rows.map(\.title), ["Buy milk"], "the card names the real task")
        XCTAssertEqual(store.tasks.first { $0.id == milk.id }?.dueDate, before, "nothing changed before a yes")
        let reply = await save(p, turns)
        XCTAssertNotNil(reply)
        let after = store.tasks.first { $0.id == milk.id }
        XCTAssertEqual(after?.dueDate.map { Calendar.current.component(.weekday, from: $0) }, 6)
        XCTAssertEqual(after?.reason, "breakfast")
        XCTAssertEqual(store.tasks.first { $0.title == "Call mom" }?.dueDate, store.tasks.first { $0.title == "Call mom" }?.dueDate, "the other task is untouched")
    }

    func testDeletingASavedTaskIsDestructiveAndWaitsForAYes() async {
        let (engine, turns, store, defaults, suite) = savedTurns(["Buy milk"])
        defer { defaults.removePersistentDomain(forName: suite) }
        engine.intents = [FlatIntentValue(intent: "change")]
        engine.edits = [FlatEditValue(remove: ["t1"])]
        guard let p = proposal(await turns.decide(utterance: "delete that", now: now, final: true)) else { return }
        XCTAssertTrue(p.destructive)
        XCTAssertEqual(store.tasks.count, 1, "still there")
        _ = await save(p, turns)
        XCTAssertTrue(store.tasks.isEmpty)
    }

    func testASavedTaskCanLoseAFieldOnlyAfterAYes() async {
        let (engine, turns, store, defaults, suite) = savedTurns(["Buy milk"])
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = store.tasks[0].id
        store.applyEditExtras(id, with: { var c = ValidatedTask(title: ""); c.instructions = "two packs"; return c }())
        engine.intents = [FlatIntentValue(intent: "change")]
        engine.edits = [FlatEditValue(update: [FlatEditUpdateValue(target: "t1", clear: ["instructions"])])]
        guard let p = proposal(await turns.decide(utterance: "remove the instructions from that", now: now, final: true)) else { return }
        XCTAssertEqual(store.tasks[0].instructions, "two packs")
        _ = await save(p, turns)
        XCTAssertNil(store.tasks[0].instructions)
    }

    func testANewTaskForASavedTasksListBecomesADraftOnThatList() async {
        let (engine, turns, store, defaults, suite) = savedTurns(["Buy milk"], list: "Blinkit order")
        defer { defaults.removePersistentDomain(forName: suite) }
        engine.intents = [FlatIntentValue(intent: "change")]
        engine.edits = [FlatEditValue(listName: "Blinkit order", add: [task("Buy eggs")])]
        let count = store.tasks.count
        guard proposal(await turns.decide(utterance: "also add eggs to the Blinkit order", now: now, final: true)) != nil else { return }
        XCTAssertEqual(turns.state.drafts.items.map(\.title), ["Buy eggs"])
        XCTAssertEqual(turns.state.drafts.items.first?.listName, "Blinkit order")
        XCTAssertEqual(store.tasks.count, count, "a draft: nothing is saved yet")
    }

    func testASavedEditThatNamesNoRecentTaskChangesNothing() async {
        let (engine, turns, store, defaults, suite) = savedTurns(["Buy milk"])
        defer { defaults.removePersistentDomain(forName: suite) }
        engine.intents = [FlatIntentValue(intent: "change")]
        engine.edits = [FlatEditValue(update: [FlatEditUpdateValue(target: "t9", title: "Nope")])]
        let result = await turns.decide(utterance: "rename that", now: now, final: true)
        if case .proposal = result { XCTFail("no card for a task that is not recent") }
        XCTAssertEqual(store.tasks[0].title, "Buy milk")
    }

    func testAnUnrelatedSavedEditFallsThroughToExtraction() async {
        let (engine, turns, _, defaults, suite) = savedTurns(["Buy milk"])
        defer { defaults.removePersistentDomain(forName: suite) }
        engine.intents = [FlatIntentValue(intent: "change")]
        engine.edits = [FlatEditValue(outcome: "unrelated")]
        engine.answers = [create([task("Make tea")])]
        guard let p = proposal(await turns.decide(utterance: "make tea, that is all", now: now, final: true)) else { return }
        XCTAssertEqual(p.rows.map(\.title), ["Make tea"])
        XCTAssertEqual(engine.prompts.count, 1)
    }

    func testASavedUpdateKeepsOnlyWordsTheUserSaidAndReportsWhatItCouldNotRead() {
        var notes: [String] = []
        let c = SavedEditMapper.changes(FlatEditUpdateValue(target: "t1", dueDate: "Friyay", purpose: "optimise logistics"),
                                        words: "make the milk for Friyay", now: wednesday, calendar: gregorian, notes: &notes)
        XCTAssertNil(c, "an unread day and an unsaid purpose leave nothing to change")
        XCTAssertTrue(notes.contains { $0.contains("Friyay") })
        var more: [String] = []
        let repeating = SavedEditMapper.changes(FlatEditUpdateValue(target: "t1", title: "Buy oat milk", schedule: "every day"),
                                                words: "rename to oat milk every day", now: wednesday, calendar: gregorian, notes: &more)
        XCTAssertEqual(repeating?.title, "Buy oat milk")
        XCTAssertTrue(more.contains { $0.contains("repeat") }, "a saved task is not made to repeat from here")
    }

    // MARK: Playbooks from an approved list

    func testAPlaybookCopiesTheProcedureAndNothingAboutOneRun() {
        let (store, defaults, suite) = scratchStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let list = store.ensureProfile("Biryani night").profile
        var planned = [PlannedTask(title: "Soak the rice", category: .househelp, due: nil, assignee: "Rani", profile: "Biryani night", instructions: "30 minutes"),
                       PlannedTask(title: "Fry the onions", category: .househelp, due: nil, profile: "Biryani night")]
        planned[1].softDue = "after lunch"
        let made = store.addMany(planned)
        store.complete(made[0].id)
        store.setOrdered(true, for: list.id)
        XCTAssertTrue(store.savePlaybook(fromList: store.profiles[0]))
        guard let pb = store.playbooks.first else { return XCTFail("no playbook") }
        XCTAssertEqual(pb.name, "Biryani night")
        XCTAssertEqual(pb.steps.map(\.title), ["Soak the rice", "Fry the onions"], "titles in the list's order")
        XCTAssertEqual(pb.steps.map(\.instructions), ["30 minutes", nil])
        XCTAssertEqual(pb.steps.map(\.assignee), ["Rani", nil])
        XCTAssertEqual(pb.ordered, true)
        let encoded = String(data: try! JSONEncoder().encode(pb), encoding: .utf8) ?? ""
        XCTAssertFalse(encoded.contains("isDone"), "no completion status")
        XCTAssertFalse(encoded.contains("after lunch"), "no one-off timeframe")
        XCTAssertFalse(encoded.contains("completedAt"))
    }

    func testAListIsNotOrderedUnlessTheUserSaysSo() {
        let (store, defaults, suite) = scratchStore()
        defer { defaults.removePersistentDomain(forName: suite) }
        let list = store.ensureProfile("Pharmacy").profile
        XCTAssertFalse(list.isOrdered)
        store.setOrdered(true, for: list.id)
        XCTAssertTrue(store.profiles[0].isOrdered)
        store.setOrdered(false, for: list.id)
        XCTAssertFalse(store.profiles[0].isOrdered)
    }

    // MARK: Old data and labels

    func testOldTaskJSONWithLabelsAndWithoutTheNewFieldsStillDecodes() throws {
        let id = UUID().uuidString
        let json = """
        {"id":"\(id)","title":"Buy milk","isDone":false,"labels":["Zomato","Kitty"],"reason":"breakfast"}
        """
        let item = try JSONDecoder().decode(TaskItem.self, from: Data(json.utf8))
        XCTAssertEqual(item.title, "Buy milk")
        XCTAssertEqual(item.reason, "breakfast")
        XCTAssertNil(item.instructions)
        XCTAssertNil(item.schedule)
        XCTAssertNil(item.softDue)
        XCTAssertEqual(item.labels, ["Zomato", "Kitty"], "still read, never written or shown")
        let again = String(data: try JSONEncoder().encode(TaskItem(title: "x")), encoding: .utf8) ?? ""
        XCTAssertFalse(again.contains("\"labels\""), "labels are never written")
    }

    func testOldRoutineJSONWithoutTheNewFieldsStillDecodes() throws {
        let json = """
        {"id":"\(UUID().uuidString)","title":"Sweep","weekdays":[],"createdAt":null}
        """
        let r = try JSONDecoder().decode(Routine.self, from: Data(json.utf8))
        XCTAssertEqual(r.title, "Sweep")
        XCTAssertNil(r.instructions)
        XCTAssertNil(r.schedule)
    }

    func testTheCardAndTheTaskRowCarryTheNewFields() {
        var i = DraftItem(title: "Buy Cipcal")
        i.instructions = "500 mg"
        i.reason = "calcium"
        i.softDue = "next week"
        let tags = DraftProposals.tags(i).map(\.text)
        XCTAssertTrue(tags.contains("500 mg") && tags.contains("calcium") && tags.contains("next week"), "\(tags)")
    }

    // MARK: A task must have content, and the model words the question

    private let noContentWords = ["create a task", "Can you create a new task? task?", "new task", "please add something"]
    private let asked = "What would you like to add?"

    func testTheShapeCheckSeesNoContentInAppTalk() {
        for words in noContentWords + ["create", "add", "task", "", "   ", "?!", "123", "add a new reminder to the list"] {
            XCTAssertFalse(TaskMeaning.hasContent(words), "\"\(words)\" says nothing about a task")
        }
        for words in ["add a task to call mom", "create presentation", "make dinner", "meditate", "buy milk", "new task for Rani tomorrow", "buy 2 milk"] {
            XCTAssertTrue(TaskMeaning.hasContent(words), "\"\(words)\" is a real request")
        }
    }

    func testASpokenCommandIsNotATitleButARealVerbTitleIs() {
        XCTAssertFalse(TaskMeaning.isMeaningful(title: "Add a task to buy bread and milk", utterance: ""))
        XCTAssertFalse(TaskMeaning.isMeaningful(title: "Add milk to the blanket list", utterance: ""))
        XCTAssertFalse(TaskMeaning.isMeaningful(title: "I just said add a task", utterance: ""))
        XCTAssertFalse(TaskMeaning.isMeaningful(title: "task", utterance: "task"))
        for title in ["Call mom", "Create presentation", "Make dinner", "Meditate", "Buy milk", "New task for Rani"] {
            XCTAssertTrue(TaskMeaning.isMeaningful(title: title, utterance: title), title)
        }
    }

    func testWordsWithNoContentAskTheModelsQuestionAndNeverReachExtraction() async {
        for words in noContentWords {
            let engine = FlatEngine()
            engine.questions = [asked]
            let turns = make(engine)
            let result = await turns.decide(utterance: words, now: now, final: true)
            guard case .question(let q) = result else { XCTFail("\"\(words)\": expected the question, got \(result)"); continue }
            XCTAssertEqual(q, asked, "shown exactly as the model wrote it: Swift adds no wording")
            XCTAssertTrue(engine.prompts.isEmpty, "no extraction call for \"\(words)\"")
            XCTAssertEqual(engine.questionPrompts.count, 1)
            XCTAssertTrue(engine.questionPrompts[0].contains(words.trimmingCharacters(in: .whitespaces)), "the prompt carries the words as heard")
            XCTAssertFalse(turns.state.drafts.hasContent, "no card, nothing saved")
            XCTAssertNil(turns.state.pendingProposal)
        }
    }

    func testTheQuietBeforeTheQuestionIsTheUsualPauseAndMoreWordsCancelIt() async {
        let early = VoiceTurnManager.judge(utterance: "create a task", silence: 1, lastActed: "")
        XCTAssertEqual(early.gate, .keepListening, "a short pause is not the end of the thought")
        let needed = VoiceTurnManager.pauseNeeded(for: "create a task") + VoiceTurnManager.noContentExtraHold
        let late = VoiceTurnManager.judge(utterance: "create a task", silence: needed + 0.1, lastActed: "")
        XCTAssertEqual(late.gate, .evaluate("create a task"))
        let engine = FlatEngine()
        engine.answers = [create([task("Buy milk")])]
        let turns = make(engine)
        guard let p = proposal(await turns.decide(utterance: "create a task buy milk", now: now, final: true)) else { return }
        XCTAssertEqual(p.rows.map(\.title), ["Buy milk"])
        XCTAssertTrue(engine.questionPrompts.isEmpty, "a person who goes on is never asked")
    }

    func testWhenTheQuestionCallGivesNothingTheUserIsLeftListeningWithNoCannedText() async {
        for scripted: [String?] in [[], [nil], ["Sure thing, I added it."]] {
            let engine = FlatEngine()
            engine.questions = scripted
            let turns = make(engine)
            let result = await turns.decide(utterance: "create a task", now: now, final: true)
            if case .handled = result {} else { XCTFail("\(scripted): expected the words to be consumed with nothing shown, got \(result)") }
            XCTAssertTrue(engine.prompts.isEmpty)
            XCTAssertNil(turns.state.pendingProposal)
        }
    }

    func testAfterTheQuestionTheNextWordsAreTheTask() async {
        let engine = FlatEngine()
        engine.questions = [asked]
        let turns = make(engine)
        guard case .question = await turns.decide(utterance: "create a task", now: now, final: true) else { return XCTFail("expected the question") }
        engine.answers = [create([task("Buy milk")])]
        guard let p = proposal(await turns.decide(utterance: "buy milk", now: now, final: true)) else { return }
        XCTAssertEqual(p.rows.map(\.title), ["Buy milk"])
        XCTAssertEqual(engine.prompts.count, 1)
        XCTAssertTrue(engine.prompts[0].contains("create a task"), "the first words travel with the answer")
    }

    func testTheSameQuestionIsNotAskedTwice() async {
        let engine = FlatEngine()
        engine.questions = [asked, asked, asked]
        let turns = make(engine)
        guard case .question = await turns.decide(utterance: "create a task", now: now, final: true) else { return XCTFail("expected the question") }
        engine.answers = [create([task("task")]), create([task("task")])]
        // Not answered: the same question may be shown once more, and never a third time.
        guard case .question = await turns.decide(utterance: "a task", now: now, final: true) else { return XCTFail("expected the question once more") }
        let third = await turns.decide(utterance: "the task", now: now, final: true)
        if case .handled = third {} else { XCTFail("a third showing ends in idle, got \(third)") }
        XCTAssertNil(turns.state.pendingProposal)
    }

    func testAModelTitleThatSaysNothingMakesNoCardAndAsksTheSameWay() async {
        for title in ["create", "add", "task", "new task", "Add a task to buy bread and milk"] {
            let engine = FlatEngine()
            engine.answers = [create([task(title)])]
            engine.questions = [asked]
            let turns = make(engine)
            let result = await turns.decide(utterance: "milk please", now: now, final: true)
            guard case .question(let q) = result else { XCTFail("\"\(title)\": expected the question, got \(result)"); continue }
            XCTAssertEqual(q, asked)
            XCTAssertFalse(turns.state.drafts.hasContent, title)
        }
    }

    func testARealTaskWithNothingElseWrongIsKept() {
        for title in ["Call mom", "Create presentation", "Make dinner", "Meditate", "Buy milk", "New task for Rani"] {
            XCTAssertEqual(items(create([task(title)])).map(\.title), [title])
        }
        // One of two titles says nothing: only that one goes.
        XCTAssertEqual(items(create([task("task"), task("Buy milk")])).map(\.title), ["Buy milk"])
    }

    func testAnEditCannotAddOrRetitleToANonMeaningfulTitle() {
        let draft = [DraftItem(title: "Buy milk")]
        let mapped = FlatEditMapper.map(FlatEditValue(add: [task("task"), task("Buy eggs")]), draft: draft, transcript: "also eggs", words: "also eggs")
        XCTAssertEqual(mapped.addItems.map(\.title), ["Buy eggs"])
        let saved = SavedEditMapper.map(FlatEditValue(add: [task("new task")]), refs: [:], words: "add that", now: wednesday, calendar: gregorian)
        XCTAssertTrue(saved.adds.isEmpty)
        XCTAssertEqual(FlatEditMapper.op(FlatEditUpdateValue(target: "d1", title: "create"), now: wednesday, calendar: gregorian).title, "")
        var notes: [String] = []
        XCTAssertNil(SavedEditMapper.changes(FlatEditUpdateValue(target: "t1", title: "task"), words: "rename that", now: wednesday, calendar: gregorian, notes: &notes))
    }

    func testTheEditSheetRefusesATitleWithNoContent() {
        for title in ["", "   ", "task", "new task", "create"] { XCTAssertFalse(TaskMeaning.isMeaningful(title: title, utterance: ""), title) }
        XCTAssertTrue(TaskMeaning.isMeaningful(title: "Water the plants", utterance: ""))
    }
}
