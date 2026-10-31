import XCTest
@testable import Kitty

/// The hybrid merge (`HybridTranscript.merge`), SYNTHETIC: made-up Apple words, timings and settled phrases, no audio and no
/// recogniser. It shows how the Swift side behaves for those inputs. It does not say what Apple Speech really reports on a device
/// (whether partial words carry timestamps, how late they arrive); `HybridRecognizer` traces that when the console trace is on.

private func word(_ text: String, at t: Double = 0, for d: Double = 0) -> SpokenWord {
    SpokenWord(text: text, confidence: 0.5, timestamp: t, duration: d)
}

private func untimed(_ text: String) -> [SpokenWord] { text.split(separator: " ").map { word(String($0)) } }

// MARK: - Putting settled phrases into Apple's words

final class HybridTranscriptTests: XCTestCase {

    private let timedApple = [word("buy", at: 0.2, for: 0.3), word("milk", at: 0.5, for: 0.3), word("and", at: 0.9, for: 0.2),
                              word("bread", at: 1.1, for: 0.4), word("then", at: 3.2, for: 0.3), word("call", at: 3.5, for: 0.3)]

    // The cases that worked before the change.

    func testASettledPhraseReplacesTheWordsAppleHeardForIt() {
        let phrase = SettledPhrase(id: 1, start: 0, end: 1.8, appleCountAtEnd: 4, text: "Buy milk and bread.")
        let m = HybridTranscript.merge(phrases: [phrase], apple: timedApple, origin: 0)
        XCTAssertEqual(m.text, "Buy milk and bread. then call", "the words after the phrase stay Apple's live tail")
        XCTAssertEqual(m.words.map(\.text), ["Buy", "milk", "and", "bread.", "then", "call"])
    }

    func testTheAccurateWordsKeepTheirConfidence() {
        let accurateWords = [SpokenWord(text: "Buy", confidence: 0.9), SpokenWord(text: "bread.", confidence: 0.4)]
        let phrase = SettledPhrase(id: 1, start: 0, end: 1.8, appleCountAtEnd: 4, text: "Buy bread.", words: accurateWords)
        let m = HybridTranscript.merge(phrases: [phrase], apple: timedApple, origin: 0)
        XCTAssertEqual(m.words.prefix(2).map(\.confidence), [0.9, 0.4])
        XCTAssertEqual(m.words.dropFirst(2).map(\.confidence), [0.5, 0.5])
    }

    func testAPhraseThatIsNotSettledYetLeavesAppleSpeechsWords() {
        let waiting = SettledPhrase(id: 1, start: 0, end: 1.8, appleCountAtEnd: 4, text: nil)
        XCTAssertEqual(HybridTranscript.merge(phrases: [waiting], apple: timedApple, origin: 0).text, "buy milk and bread then call")
    }

    func testAPhraseTheModelCalledNoiseDropsItsWords() {
        let noise = SettledPhrase(id: 1, start: 0, end: 1.8, appleCountAtEnd: 4, text: "")
        XCTAssertEqual(HybridTranscript.merge(phrases: [noise], apple: timedApple, origin: 0).text, "then call")
    }

    func testTwoPhrasesAndAnUnsettledOneBetweenThemStayInOrder() {
        let first = SettledPhrase(id: 1, start: 0, end: 1.8, appleCountAtEnd: 4, text: "Buy milk and bread.")
        let middle = SettledPhrase(id: 2, start: 3.1, end: 3.9, appleCountAtEnd: 6, text: nil)
        let apple = timedApple + [word("pay", at: 6.0, for: 0.3), word("rent", at: 6.3, for: 0.3)]
        let last = SettledPhrase(id: 3, start: 5.9, end: 6.8, appleCountAtEnd: 8, text: "Pay the rent.")
        let m = HybridTranscript.merge(phrases: [last, first, middle], apple: apple, origin: 0)
        XCTAssertEqual(m.text, "Buy milk and bread. then call Pay the rent.")
    }

    func testAppleTimesAreRelativeToWhenItsRecognitionBegan() {
        let phrase = SettledPhrase(id: 1, start: 10, end: 11.8, appleCountAtEnd: 4, text: "Buy milk and bread.")
        let m = HybridTranscript.merge(phrases: [phrase], apple: timedApple, origin: 10)
        XCTAssertEqual(m.text, "Buy milk and bread. then call")
    }

    func testWithoutAnyTimesTheWordCountAtThePauseDecidesWhichWordsAreCovered() {
        let words = untimed("buy milk and bread then call")
        let phrase = SettledPhrase(id: 1, start: 0, end: 1.8, appleCountAtEnd: 4, text: "Buy milk and bread.")
        XCTAssertEqual(HybridTranscript.merge(phrases: [phrase], apple: words, origin: 0).text, "Buy milk and bread. then call")

        let second = SettledPhrase(id: 2, start: 3, end: 4, appleCountAtEnd: 6, text: "Then call.")
        XCTAssertEqual(HybridTranscript.merge(phrases: [phrase, second], apple: words, origin: 0).text, "Buy milk and bread. Then call.")

        let blank = SettledPhrase(id: 2, start: 3, end: 4, appleCountAtEnd: 6, text: nil)
        XCTAssertEqual(HybridTranscript.merge(phrases: [phrase, blank], apple: words, origin: 0).text, "Buy milk and bread. then call")
    }

    func testACountThatIsLargerThanTheWordsHeardIsHarmless() {
        let phrase = SettledPhrase(id: 1, start: 0, end: 1, appleCountAtEnd: 9, text: "Buy milk.")
        XCTAssertEqual(HybridTranscript.merge(phrases: [phrase], apple: untimed("buy milk"), origin: 0).text, "Buy milk.")
    }

    func testNothingAtAllIsEmpty() {
        XCTAssertEqual(HybridTranscript.merge(phrases: [], apple: [], origin: 0), .init(text: "", words: []))
    }

    func testEmptyOrMissingAccurateTextKeepsAppleSpeechsWordsUnlessItIsNoise() {
        let missing = SettledPhrase(id: 1, start: 0, end: 1, appleCountAtEnd: 2, text: nil)
        XCTAssertEqual(HybridTranscript.merge(phrases: [missing], apple: untimed("buy milk"), origin: 0).text, "buy milk")
    }

    // MARK: Apple's words that arrive late (the duplicate: "add a task to buy milk to buy milk")

    private let whole = "Add a task to buy milk."

    /// Apple had reported 3 of the 6 words when the pause was seen, and no word carries a time. The other three arrive afterwards.
    func testUntimedWordsThatArriveAfterThePauseJoinTheirPhraseInsteadOfRepeatingIt() {
        let phrase = SettledPhrase(id: 1, start: 0, end: 2, appleCountAtEnd: 3, text: whole)
        let m = HybridTranscript.merge(phrases: [phrase], apple: untimed("add a task to buy milk"), origin: 0)
        XCTAssertEqual(m.text, whole)
        XCTAssertEqual(m.words.map(\.text), ["Add", "a", "task", "to", "buy", "milk."])
    }

    func testOnlyPartOfTheLateTailHasArrivedYet() {
        let phrase = SettledPhrase(id: 1, start: 0, end: 2, appleCountAtEnd: 3, text: whole)
        XCTAssertEqual(HybridTranscript.merge(phrases: [phrase], apple: untimed("add a task to buy"), origin: 0).text, whole)
    }

    /// The last word is timed 0.3 s after the phrase ended: past the 0.15 s slack, but it is the end of the same phrase.
    func testATimedWordThatDriftsPastThePhraseEndStillJoinsItsPhrase() {
        let apple = [word("add", at: 0.1, for: 0.2), word("a", at: 0.4, for: 0.1), word("task", at: 0.6, for: 0.3),
                     word("to", at: 1.0, for: 0.2), word("buy", at: 1.3, for: 0.3), word("milk", at: 2.15, for: 0.3)]
        let phrase = SettledPhrase(id: 1, start: 0, end: 1.9, appleCountAtEnd: 6, text: whole)
        let m = HybridTranscript.merge(phrases: [phrase], apple: apple, origin: 0)
        XCTAssertEqual(m.text, whole)
    }

    func testAccurateTimesGiveTheSameAnswer() {
        let apple = [word("add", at: 0.1, for: 0.2), word("a", at: 0.4, for: 0.1), word("task", at: 0.6, for: 0.3),
                     word("to", at: 1.0, for: 0.2), word("buy", at: 1.3, for: 0.3), word("milk", at: 1.6, for: 0.3)]
        let phrase = SettledPhrase(id: 1, start: 0, end: 2.0, appleCountAtEnd: 6, text: whole)
        XCTAssertEqual(HybridTranscript.merge(phrases: [phrase], apple: apple, origin: 0).text, whole)
    }

    // MARK: A new phrase must not be taken for a late word

    func testAWordOfTheNextPhraseIsKeptWhenItIsNotTheEndOfTheSettledText_Timed() {
        let apple = [word("add", at: 0.1, for: 0.2), word("a", at: 0.4, for: 0.1), word("task", at: 0.6, for: 0.3),
                     word("to", at: 1.0, for: 0.2), word("buy", at: 1.3, for: 0.3), word("milk", at: 1.6, for: 0.3),
                     word("bread", at: 3.2, for: 0.3)]
        let phrase = SettledPhrase(id: 1, start: 0, end: 2.0, appleCountAtEnd: 6, text: whole)
        XCTAssertEqual(HybridTranscript.merge(phrases: [phrase], apple: apple, origin: 0).text, whole + " bread")
    }

    func testAWordOfTheNextPhraseIsKeptWhenItIsNotTheEndOfTheSettledText_Untimed() {
        let phrase = SettledPhrase(id: 1, start: 0, end: 2, appleCountAtEnd: 6, text: whole)
        XCTAssertEqual(HybridTranscript.merge(phrases: [phrase], apple: untimed("add a task to buy milk bread"), origin: 0).text, whole + " bread")
    }

    /// "Buy milk", a pause, then "milk chocolate": the second "milk" is new speech, even though it equals the last word settled.
    func testASayingThatStartsWithTheLastSettledWordIsNotSwallowed() {
        let phrase = SettledPhrase(id: 1, start: 0, end: 1.5, appleCountAtEnd: 2, text: "Buy milk.")
        let m = HybridTranscript.merge(phrases: [phrase], apple: untimed("buy milk milk chocolate"), origin: 0)
        XCTAssertEqual(m.text, "Buy milk. milk chocolate")
    }

    // MARK: Two settled phrases

    /// Apple lags: phrase 1's last three words are still arriving when phrase 2's pause is seen, so the counts do not line up.
    func testTwoSettledPhrasesWhoseAppleWordsAreAdjacentAndLateEachTakeTheirOwn() {
        let one = SettledPhrase(id: 1, start: 0, end: 2, appleCountAtEnd: 3, text: whole)
        let two = SettledPhrase(id: 2, start: 3, end: 4, appleCountAtEnd: 6, text: "Then call mom.")
        let apple = untimed("add a task to buy milk then call mom")
        XCTAssertEqual(HybridTranscript.merge(phrases: [one, two], apple: apple, origin: 0).text, whole + " Then call mom.")
    }

    func testAnUnsettledPhraseAfterASettledOneKeepsAppleSpeechsWords() {
        let one = SettledPhrase(id: 1, start: 0, end: 2, appleCountAtEnd: 3, text: whole)
        let two = SettledPhrase(id: 2, start: 3, end: 4, appleCountAtEnd: 9, text: nil)
        let apple = untimed("add a task to buy milk then call mom")
        XCTAssertEqual(HybridTranscript.merge(phrases: [one, two], apple: apple, origin: 0).text, whole + " then call mom")
    }

    // MARK: Words said twice on purpose

    func testAWordSaidTwiceInTheSettledTextSurvives() {
        let phrase = SettledPhrase(id: 1, start: 0, end: 2, appleCountAtEnd: 5, text: "No no I said no.")
        XCTAssertEqual(HybridTranscript.merge(phrases: [phrase], apple: untimed("no no i said no"), origin: 0).text, "No no I said no.")
        let very = SettledPhrase(id: 1, start: 0, end: 2, appleCountAtEnd: 3, text: "It is very very good.")
        XCTAssertEqual(HybridTranscript.merge(phrases: [very], apple: untimed("it is very very good"), origin: 0).text, "It is very very good.")
    }

    func testARepeatThatAppleSpeechAloneHeardIsNotTouched() {
        XCTAssertEqual(HybridTranscript.merge(phrases: [], apple: untimed("no no"), origin: 0).text, "no no")
    }

    func testALateWordThatIsTheSecondOfTwoSettledRepeatsIsNotAddedAgain() {
        let phrase = SettledPhrase(id: 1, start: 0, end: 2, appleCountAtEnd: 3, text: "It is very very.")
        XCTAssertEqual(HybridTranscript.merge(phrases: [phrase], apple: untimed("it is very very"), origin: 0).text, "It is very very.")
    }

    // MARK: The safety net

    /// Apple dropped two words, so its count is short and the late words do not line up with the settled text; they still repeat its end.
    func testARunThatRepeatsTheEndOfTheSettledTextIsRemovedAndReported() {
        let phrase = SettledPhrase(id: 1, start: 0, end: 2, appleCountAtEnd: 1, text: whole)
        let m = HybridTranscript.merge(phrases: [phrase], apple: untimed("add to buy milk"), origin: 0)
        XCTAssertEqual(m.text, whole)
        XCTAssertEqual(m.removed, ["to", "buy", "milk"])
    }

    // MARK: Words without a time between words with one

    func testAnUntimedWordBetweenTimedOnesTakesAPlaceBetweenThem() {
        let apple = [word("buy", at: 0.2, for: 0.3), word("milk", at: 0.5, for: 0.3), word("then"), word("call", at: 3.0, for: 0.3)]
        let phrase = SettledPhrase(id: 1, start: 0, end: 1.0, appleCountAtEnd: 2, text: "Buy milk.")
        XCTAssertEqual(HybridTranscript.merge(phrases: [phrase], apple: apple, origin: 0).text, "Buy milk. then call")
    }
}

// MARK: - The recogniser around the merge

@MainActor
final class HybridRecognizerMergeTests: XCTestCase {
    private var recognizer: HybridRecognizer!
    private var appleWords: [SpokenWord] = []
    private var appleText = ""

    override func setUp() async throws {
        let accurate = WhisperAccurate(engine: WhisperEngine(accurate: true), available: false)
        recognizer = HybridRecognizer(accurate: accurate)
        appleWords = []; appleText = ""
        recognizer.appleWords = { [unowned self] in appleWords }
        recognizer.appleText = { [unowned self] in appleText }
        recognizer.beginWithoutAudio()
    }

    private func send(_ event: TurboSettler.Event) { recognizer.received(event, generation: recognizer.generation) }

    func testAPhraseEndedTwiceForTheSameIdIsOnePhrase() {
        appleWords = untimed("buy milk"); appleText = "buy milk"
        send(.phraseEnded(id: 1, start: 0, end: 1.5))
        send(.phraseEnded(id: 1, start: 0, end: 1.5))
        send(.settled(id: 1, text: "Buy milk.", words: [], latencyMs: 400))
        XCTAssertEqual(recognizer.phrasesForTests.count, 1)
        XCTAssertEqual(recognizer.transcript, "Buy milk.")
    }

    func testASettledEventTwiceForTheSamePhraseChangesNothing() {
        appleWords = untimed("buy milk"); appleText = "buy milk"
        send(.phraseEnded(id: 1, start: 0, end: 1.5))
        send(.settled(id: 1, text: "Buy milk.", words: [], latencyMs: 400))
        send(.settled(id: 1, text: "Buy milk.", words: [], latencyMs: 400))
        XCTAssertEqual(recognizer.transcript, "Buy milk.")
    }

    func testLateAppleWordsAfterThePauseDoNotRepeatTheSettledText() {
        appleWords = untimed("add a task"); appleText = "add a task"
        send(.phraseEnded(id: 1, start: 0, end: 2))
        appleWords = untimed("add a task to buy milk"); appleText = "add a task to buy milk"
        send(.settled(id: 1, text: "Add a task to buy milk.", words: [], latencyMs: 400))
        XCTAssertEqual(recognizer.transcript, "Add a task to buy milk.")
    }
}

// MARK: - A replacement is not a restart

final class SettledReplacementTests: XCTestCase {
    /// The accurate text replaces a badly misheard live stretch that shares no word with it. The turn must hold it once.
    func testWhisperReplacingAGarbledStretchIsNotTakenForARecogniserRestart() {
        let live = "a dusk too my milk"
        let settled = "Add a task to buy milk."
        let merged = TurnAccumulator.absorb(carry: "", session: live, partial: settled, replacedBySettle: true)
        XCTAssertFalse(merged.reset)
        XCTAssertEqual(merged.carry, "")
        XCTAssertEqual(merged.session, settled)
        XCTAssertTrue(TurnAccumulator.absorb(carry: "", session: live, partial: settled).reset,
                      "without the hint the replacement looks like a restart, which is why the hint exists")
    }

    func testAStretchWithNoWordInCommonIsStillTakenForARestartWhenAppleSpeechStartsOver() {
        let merged = TurnAccumulator.absorb(carry: "", session: "buy milk and bread", partial: "call the plumber")
        XCTAssertTrue(merged.reset)
        XCTAssertEqual(merged.carry, "buy milk and bread")
    }
}

@MainActor
final class HybridSettleFlagTests: XCTestCase {
    func testOnlyTheAccurateModelsTextIsMarkedAsAReplacement() async throws {
        let accurate = WhisperAccurate(engine: WhisperEngine(accurate: true), available: false)
        let recognizer = HybridRecognizer(accurate: accurate)
        var words = untimed("a dusk too my milk")
        recognizer.appleWords = { words }
        recognizer.appleText = { "a dusk too my milk" }
        recognizer.beginWithoutAudio()
        recognizer.recompute()
        XCTAssertFalse(recognizer.lastChangeWasSettle)
        recognizer.received(.phraseEnded(id: 1, start: 0, end: 2), generation: recognizer.generation)
        recognizer.received(.settled(id: 1, text: "Add a task to buy milk.", words: [], latencyMs: 300), generation: recognizer.generation)
        XCTAssertTrue(recognizer.lastChangeWasSettle)
        words = untimed("a dusk too my milk and")
        recognizer.recompute()
        XCTAssertFalse(recognizer.lastChangeWasSettle)
    }
}
