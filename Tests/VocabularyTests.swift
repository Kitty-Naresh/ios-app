import XCTest
@testable import Kitty

/// The names Kitty expects to hear, matching sound-alikes against them, and the "Did you say Rani?" read-back.
@MainActor
final class VocabularyTests: XCTestCase {

    // MARK: Vocabulary for the recogniser

    func testTheVocabularyKeepsPeopleFirstDedupesAndCaps() {
        let v = VocabularyProvider.build(assignees: ["Rani", "rani", "Suresh"], profiles: ["Blinkit order"], categories: ["Bathroom", "Groceries"],
                                         playbooks: ["Cook biryani"], routines: ["Water the plants"])
        XCTAssertEqual(Array(v.prefix(3)), ["Rani", "Suresh", "Blinkit order"])
        XCTAssertEqual(v.filter { $0.lowercased() == "rani" }.count, 1)
        XCTAssertTrue(v.contains("Cook biryani"))

        let many = (0..<300).map { "Name\($0)" }
        XCTAssertEqual(VocabularyProvider.build(assignees: many).count, VocabularyProvider.limit)
    }

    func testLongPhrasesAndBlanksAreLeftOut() {
        let v = VocabularyProvider.build(routines: ["", "  ", "Water the plants in the garden every single morning before work", "Sweep"])
        XCTAssertEqual(v, ["Sweep"])
    }

    func testNamesInTheHouseholdNotesAreFound() {
        let notes = "Our maid Rani comes every morning. Driver Suresh drops the kids on Monday. We love Kitty."
        let names = VocabularyProvider.capitalisedNames(in: notes)
        XCTAssertEqual(names, ["Rani", "Suresh"])
    }

    func testTheEnglishIndiaSettingChoosesTheLocale() {
        let before = SpeechLocalePreference.isIndianEnglish
        defer { SpeechLocalePreference.isIndianEnglish = before }
        SpeechLocalePreference.isIndianEnglish = true
        XCTAssertEqual(SpeechLocalePreference.locale.identifier, "en-IN")
        SpeechLocalePreference.isIndianEnglish = false
        XCTAssertNotEqual(SpeechLocalePreference.locale.identifier, "en-IN")
    }

    // MARK: Matching

    func testSoundAlikesMatchKnownNames() {
        typealias M = VocabularyMatcher.Match
        let cases: [(String, [String], M)] = [
            ("Rani", ["Rani"], .exact("Rani")),
            ("rani", ["Rani", "Suresh"], .exact("Rani")),
            ("Rainy", ["Rani"], .medium(["Rani"])),
            ("Rannie", ["Rani"], .medium(["Rani"])),
            ("Priyah", ["Priya"], .strong("Priya")),
            ("Suresh", ["Suresh", "Ramesh"], .exact("Suresh")),
            ("Sureshh", ["Suresh", "Ramesh"], .strong("Suresh")),
            ("Ravi", ["Rani"], .none),
            ("Mohan", ["Rohan"], .none),
            ("Priyanka", ["Priya"], .none),
            ("Meena", [], .none)
        ]
        for (heard, known, expected) in cases {
            XCTAssertEqual(VocabularyMatcher.match(heard, in: known), expected, "\(heard) vs \(known)")
        }
    }

    func testTwoCloseNamesAreAskedAboutNotGuessed() {
        // "Rina" sounds like both Rani and Rena: no silent pick.
        if case .medium(let names) = VocabularyMatcher.match("Rina", in: ["Rani", "Rena"]) {
            XCTAssertEqual(Set(names), ["Rani", "Rena"])
        } else {
            XCTFail("two look-alikes must be asked about")
        }
    }

    func testSoundKeysAndDistances() {
        XCTAssertEqual(VocabularyMatcher.phoneticKey("Rani"), VocabularyMatcher.phoneticKey("Rainy"))
        XCTAssertEqual(VocabularyMatcher.phoneticKey("Philip"), VocabularyMatcher.phoneticKey("Filip"))
        XCTAssertNotEqual(VocabularyMatcher.phoneticKey("Rani"), VocabularyMatcher.phoneticKey("Ravi"))
        XCTAssertEqual(VocabularyMatcher.editDistance("kitten", "sitting"), 3)
        XCTAssertEqual(VocabularyMatcher.editDistance("", "abc"), 3)
    }

    // MARK: When to read back

    func testASoundAlikeIsReadBackButAnExactOrRoleNameIsNot() {
        let known = ["Rani", "Suresh"]
        XCTAssertEqual(ReadBackCheck.assignee("Rainy", utterance: "ask Rainy to sweep the floor", known: known),
                       .ask(heard: "Rainy", suggestion: "Rani"))
        XCTAssertEqual(ReadBackCheck.assignee("Rani", utterance: "ask Rani to sweep the floor", known: known), .none)
        XCTAssertEqual(ReadBackCheck.assignee("Househelp", utterance: "ask the maid to sweep", known: known), .none)
        XCTAssertEqual(ReadBackCheck.assignee("Rainy", utterance: "sweep the floor", known: known), .none)     // not said: dropped elsewhere
        XCTAssertEqual(ReadBackCheck.assignee("Priyah", utterance: "ask Priyah to sweep", known: ["Priya"]), .none)  // strong: used silently
    }

    func testAnUnknownNameIsKeptUnlessTheRecogniserWasUnsure() {
        let utterance = "ask Meena to sweep the floor"
        XCTAssertEqual(ReadBackCheck.assignee("Meena", utterance: utterance, known: ["Rani"]), .none)
        XCTAssertEqual(ReadBackCheck.assignee("Meena", utterance: utterance, known: ["Rani"], words: [SpokenWord(text: "Meena", confidence: 0.9)]), .none)
        XCTAssertEqual(ReadBackCheck.assignee("Meena", utterance: utterance, known: ["Rani"], words: [SpokenWord(text: "Meena", confidence: 0)]), .none)   // 0 means unknown
        XCTAssertEqual(ReadBackCheck.assignee("Meena", utterance: utterance, known: ["Rani"], words: [SpokenWord(text: "Meena", confidence: 0.3)]),
                       .ask(heard: "Meena", suggestion: "Meena"))
    }

    func testDoubtfulNumbersAndDaysAreReadBack() {
        XCTAssertEqual(ReadBackCheck.fact(utterance: "call mom on Friday", words: [SpokenWord(text: "Friday", confidence: 0.3)]),
                       .ask(heard: "friday", suggestion: "Friday"))
        XCTAssertEqual(ReadBackCheck.fact(utterance: "buy 12 eggs", words: [SpokenWord(text: "12", confidence: 0.2)]),
                       .ask(heard: "12", suggestion: "12"))
        XCTAssertEqual(ReadBackCheck.fact(utterance: "call mom on Friday", words: [SpokenWord(text: "Friday", confidence: 0)]), .none)
        XCTAssertEqual(ReadBackCheck.fact(utterance: "call mom on Friday", words: [SpokenWord(text: "Friday", confidence: 0.9)]), .none)
        XCTAssertEqual(ReadBackCheck.fact(utterance: "call mom", words: [SpokenWord(text: "call", confidence: 0.1)]), .none)   // not a name, number or date
    }

    func testReplacingAndPullingANameOutOfAnAnswer() {
        XCTAssertEqual(ReadBackCheck.replacing("Rainy", with: "Rani", in: "ask rainy to sweep, Rainy knows"), "ask Rani to sweep, Rani knows")
        XCTAssertEqual(ReadBackCheck.replacing("Ran", with: "Rani", in: "ask Rani to run"), "ask Rani to run")      // whole words only
        XCTAssertEqual(ReadBackCheck.name(in: "it's Priya"), "Priya")
        XCTAssertEqual(ReadBackCheck.name(in: "I meant Priya."), "Priya")
        XCTAssertEqual(ReadBackCheck.name(in: "Mary Ann"), "Mary Ann")
    }

    // MARK: The question in a conversation

    private func decision(_ title: String, assignee: String, action: String = "create_task") -> AgentDecisionValue {
        AgentDecisionValue(wait: false, action: action, title: title, category: "", dueDate: "", dueTime: "", priority: "",
                           assignee: assignee, frequency: "", notes: "", playbookName: "", playbookSteps: [],
                           clarifyingQuestion: "", spokenResponse: "", moreTasks: [])
    }

    private func manager(_ engine: ScriptedEngine, sink: InMemorySaveSink? = nil, known: [String] = ["Rani", "Suresh"]) -> VoiceTurnManager {
        let m = VoiceTurnManager(engine: engine, sink: sink ?? InMemorySaveSink(), knownCategories: { [] }, knownAssignees: { known })
        m.ruleFallbackEnabled = false
        return m
    }

    private func asked(_ r: TurnResult) -> String? {
        if case .question(let q) = r { return q }
        return nil
    }

    private func save(_ result: TurnResult) async -> String? {
        guard case .proposal(let p) = result else { return nil }
        var go = p
        go.runImmediately = true
        _ = await go.apply()
        return p.title
    }

    func testASoundAlikeNameIsReadBackAndYesUsesTheKnownName() async {
        let engine = ScriptedEngine([decision("Sweep the floor", assignee: "Rainy")])
        let sink = InMemorySaveSink()
        let m = manager(engine, sink: sink)
        let first = await m.decide(utterance: "ask Rainy to sweep the floor")
        XCTAssertEqual(asked(first), "Did you say Rani?")
        XCTAssertTrue(sink.tasks.isEmpty)

        let second = await m.decide(utterance: "ask Rainy to sweep the floor yes")
        _ = await save(second)
        XCTAssertEqual(sink.tasks.first?.assignee, "Rani")
        XCTAssertEqual(engine.prompts.count, 1, "the model is not asked again after the read-back")
    }

    func testNoAsksWhoAndTheAnswerIsUsed() async {
        let engine = ScriptedEngine([decision("Sweep the floor", assignee: "Rainy")])
        let sink = InMemorySaveSink()
        let m = manager(engine, sink: sink)
        _ = await m.decide(utterance: "ask Rainy to sweep the floor")
        let no = await m.decide(utterance: "ask Rainy to sweep the floor no")
        XCTAssertEqual(asked(no), "Who did you mean?")
        let named = await m.decide(utterance: "ask Rainy to sweep the floor no it's Priya")
        _ = await save(named)
        XCTAssertEqual(sink.tasks.first?.assignee, "Priya")
    }

    func testThereIsOneReadBackPerTurn() async {
        // Rani confirmed, and the turn also holds a doubtful day: no second question.
        let engine = ScriptedEngine([decision("Sweep the floor on Friday", assignee: "Rainy")])
        let sink = InMemorySaveSink()
        let m = manager(engine, sink: sink)
        m.heardWords = [SpokenWord(text: "Friday", confidence: 0.2)]
        let first = await m.decide(utterance: "ask Rainy to sweep the floor on Friday")
        XCTAssertEqual(asked(first), "Did you say Rani?")
        let second = await m.decide(utterance: "ask Rainy to sweep the floor on Friday yes")
        if case .question = second { XCTFail("a second read-back in the same turn") }
    }

    func testAClearCloseNameIsUsedSilently() async {
        let engine = ScriptedEngine([decision("Sweep the floor", assignee: "Priyah")])
        let sink = InMemorySaveSink()
        let m = manager(engine, sink: sink, known: ["Priya"])
        let r = await m.decide(utterance: "ask Priyah to sweep the floor")
        if case .question = r { XCTFail("no question for a clear match") }
        _ = await save(r)
        XCTAssertEqual(sink.tasks.first?.assignee, "Priya")
    }

    func testAnUnknownNameIsKeptAsHeardWithoutAQuestion() async {
        let engine = ScriptedEngine([decision("Sweep the floor", assignee: "Meena")])
        let sink = InMemorySaveSink()
        let m = manager(engine, sink: sink)
        let r = await m.decide(utterance: "ask Meena to sweep the floor")
        if case .question = r { XCTFail("no question when nothing is doubtful") }
        _ = await save(r)
        XCTAssertEqual(sink.tasks.first?.assignee, "Meena")
    }

    func testALowConfidenceNameIsReadBackAsHeard() async {
        let engine = ScriptedEngine([decision("Sweep the floor", assignee: "Meena")])
        let sink = InMemorySaveSink()
        let m = manager(engine, sink: sink)
        m.heardWords = [SpokenWord(text: "Meena", confidence: 0.3)]
        let first = await m.decide(utterance: "ask Meena to sweep the floor")
        XCTAssertEqual(asked(first), "Did you say Meena?")
        let yes = await m.decide(utterance: "ask Meena to sweep the floor yes")
        _ = await save(yes)
        XCTAssertEqual(sink.tasks.first?.assignee, "Meena")
    }

    func testTheReadBackDoesNotCountAsAClarificationRound() async {
        let engine = ScriptedEngine([decision("Sweep the floor", assignee: "Rainy")])
        let m = manager(engine)
        _ = await m.decide(utterance: "ask Rainy to sweep the floor")
        XCTAssertEqual(m.state.clarify.rounds, 0)
    }
}
