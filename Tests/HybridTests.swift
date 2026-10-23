import XCTest
import AVFoundation
@testable import Kitty

private nonisolated enum HAudio {
    static func tone(_ seconds: Double, rate: Double = 16_000, amplitude: Float = 0.3) -> [Float] {
        (0..<Int(seconds * rate)).map { Float(sin(2 * Double.pi * 220 * Double($0) / rate)) * amplitude }
    }
    static func quiet(_ seconds: Double, rate: Double = 16_000) -> [Float] {
        [Float](repeating: 0, count: Int(seconds * rate))
    }
}

private func word(_ text: String, at t: Double = 0, for d: Double = 0) -> SpokenWord {
    SpokenWord(text: text, confidence: 0.5, timestamp: t, duration: d)
}

// MARK: - Putting settled phrases into Apple's words

final class HybridTranscriptTests: XCTestCase {

    private let timedApple = [word("buy", at: 0.2, for: 0.3), word("milk", at: 0.5, for: 0.3), word("and", at: 0.9, for: 0.2),
                              word("bread", at: 1.1, for: 0.4), word("then", at: 3.2, for: 0.3), word("call", at: 3.5, for: 0.3)]

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
        let wrong = HybridTranscript.merge(phrases: [phrase], apple: timedApple, origin: 0)
        XCTAssertEqual(wrong.text, "buy milk and bread then call Buy milk and bread.", "without the origin the words are not found")
    }

    func testWithoutAnyTimesTheWordCountAtThePauseDecidesWhichWordsAreCovered() {
        let untimed = ["buy", "milk", "and", "bread", "then", "call"].map { word($0) }
        let phrase = SettledPhrase(id: 1, start: 0, end: 1.8, appleCountAtEnd: 4, text: "Buy milk and bread.")
        XCTAssertEqual(HybridTranscript.merge(phrases: [phrase], apple: untimed, origin: 0).text, "Buy milk and bread. then call")

        let second = SettledPhrase(id: 2, start: 3, end: 4, appleCountAtEnd: 6, text: "Then call.")
        XCTAssertEqual(HybridTranscript.merge(phrases: [phrase, second], apple: untimed, origin: 0).text, "Buy milk and bread. Then call.")

        let blank = SettledPhrase(id: 2, start: 3, end: 4, appleCountAtEnd: 6, text: nil)
        XCTAssertEqual(HybridTranscript.merge(phrases: [phrase, blank], apple: untimed, origin: 0).text, "Buy milk and bread. then call")
    }

    func testACountThatIsLargerThanTheWordsHeardIsHarmless() {
        let untimed = ["buy", "milk"].map { word($0) }
        let phrase = SettledPhrase(id: 1, start: 0, end: 1, appleCountAtEnd: 9, text: "Buy milk.")
        XCTAssertEqual(HybridTranscript.merge(phrases: [phrase], apple: untimed, origin: 0).text, "Buy milk.")
    }

    func testNothingAtAllIsEmpty() {
        XCTAssertEqual(HybridTranscript.merge(phrases: [], apple: [], origin: 0), .init(text: "", words: []))
    }
}

// MARK: - Where each stretch of speech sat

final class TurnBufferPositionTests: XCTestCase {

    func testAStretchIsPlacedOnTheAudioClock() {
        var buffer = WhisperTurnBuffer()
        var events: [WhisperTurnBuffer.Event] = []
        events += buffer.append(HAudio.quiet(1))
        events += buffer.append(HAudio.tone(1))
        events += buffer.append(HAudio.quiet(1.5))
        XCTAssertEqual(events.filter { if case .ended = $0 { return true } else { return false } }.count, 1)
        let ranges = buffer.takeRanges()
        XCTAssertEqual(ranges.count, 1)
        // The voice ran from 1.0 s to 2.0 s; the stretch keeps 0.3 s before it and 0.25 s after.
        XCTAssertEqual(Double(ranges[0].lowerBound) / 16_000, 0.78, accuracy: 0.1)
        XCTAssertEqual(Double(ranges[0].upperBound) / 16_000, 2.25, accuracy: 0.1)
        XCTAssertTrue(buffer.takeRanges().isEmpty, "taking them clears the list")
    }

    func testACappedStretchIsFollowedByAnotherThatStartsWhereItEnded() {
        var config = WhisperTurnBuffer.Config()
        config.maxTurnSeconds = 1.0
        var buffer = WhisperTurnBuffer(config: config)
        let events = buffer.append(HAudio.tone(2.6))
        let capped = events.filter { if case .capped = $0 { return true } else { return false } }
        let ranges = buffer.takeRanges()
        XCTAssertGreaterThanOrEqual(capped.count, 2)
        XCTAssertEqual(ranges.count, capped.count, "one range for each capped or ended event")
        for pair in zip(ranges, ranges.dropFirst()) { XCTAssertEqual(pair.0.upperBound, pair.1.lowerBound) }
    }

    func testTheClockKeepsRunningThroughASilence() {
        var buffer = WhisperTurnBuffer()
        _ = buffer.append(HAudio.quiet(3))
        XCTAssertEqual(buffer.position, 48_000)
        _ = buffer.append(HAudio.tone(0.5))
        XCTAssertEqual(buffer.position, 56_000)
    }
}

// MARK: - The pause detector with a fake accurate model

nonisolated private final class EventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _all: [TurboSettler.Event] = []
    func add(_ e: TurboSettler.Event) { lock.lock(); _all.append(e); lock.unlock() }
    var all: [TurboSettler.Event] { lock.lock(); defer { lock.unlock() }; return _all }
    var settled: [(id: Int, text: String)] {
        all.compactMap { if case .settled(let id, let text, _, _) = $0 { return (id, text) } else { return nil } }
    }
    var ended: [(id: Int, start: Double, end: Double)] {
        all.compactMap { if case .phraseEnded(let id, let s, let e) = $0 { return (id, s, e) } else { return nil } }
    }
}

final class TurboSettlerTests: XCTestCase {

    private let turbo = FakeTranscriber()
    private let events = EventBox()

    private func settler(accurate: WhisperTranscribing?, timeout: Double = 6) -> TurboSettler {
        TurboSettler(accurate: { accurate }, prompt: "Rani.", finalTimeout: timeout) { [events] in events.add($0) }
    }

    private func feed(_ s: TurboSettler, _ samples: [Float]) throws { try s.add(samples, sampleRate: 16_000) }

    private func waitFor(_ seconds: Double = 3, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { if condition() { return true }; Thread.sleep(forTimeInterval: 0.01) }
        return condition()
    }

    func testNothingRunsWhileYouTalk() throws {
        let s = settler(accurate: turbo)
        try feed(s, HAudio.tone(3))
        XCTAssertTrue(turbo.calls.isEmpty, "the model runs once per pause, not while you talk")
        XCTAssertTrue(events.all.isEmpty)
    }

    func testAPhraseIsPlacedAndThenSettledWhenYouPause() throws {
        turbo.respond = { _ in FakeTranscriber.result("Buy milk and bread.") }
        let s = settler(accurate: turbo)
        try feed(s, HAudio.quiet(1)); try feed(s, HAudio.tone(1.5)); try feed(s, HAudio.quiet(1.2))
        XCTAssertTrue(waitFor { !events.settled.isEmpty })
        XCTAssertEqual(events.ended.count, 1)
        XCTAssertEqual(events.ended[0].id, 1)
        XCTAssertEqual(events.ended[0].start, 0.78, accuracy: 0.1)
        XCTAssertEqual(events.ended[0].end, 2.75, accuracy: 0.1)
        XCTAssertEqual(events.settled.map(\.text), ["Buy milk and bread."])
        XCTAssertEqual(turbo.calls.count, 1)
        XCTAssertEqual(Double(turbo.calls[0]) / 16_000, 2.0, accuracy: 0.3, "the whole phrase goes in one pass")
        XCTAssertEqual(turbo.prompts, ["Rani."])
        if case .phraseEnded = events.all.first {} else { XCTFail("the phrase is placed before its text arrives") }
    }

    func testTwoPhrasesAreSettledInOrder() throws {
        turbo.respond = { n in FakeTranscriber.result("phrase \(n)") }
        let s = settler(accurate: turbo)
        for _ in 0..<2 { try feed(s, HAudio.tone(1.2)); try feed(s, HAudio.quiet(1.2)) }
        XCTAssertTrue(waitFor { events.settled.count == 2 })
        XCTAssertEqual(events.settled.map(\.id), [1, 2])
        XCTAssertEqual(events.settled.map(\.text), ["phrase 1", "phrase 2"])
        XCTAssertLessThan(events.ended[0].end, events.ended[1].start)
    }

    func testAModelThatIsNotLoadedLeavesTheEndOfThePhraseOnly() throws {
        let s = settler(accurate: nil)
        try feed(s, HAudio.tone(1.2)); try feed(s, HAudio.quiet(1.2))
        XCTAssertEqual(events.ended.count, 1)
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertTrue(events.settled.isEmpty, "Apple Speech's words stand")
    }

    func testAModelThatFailsLeavesTheEndOfThePhraseOnly() throws {
        turbo.respond = { _ in nil }
        let s = settler(accurate: turbo)
        try feed(s, HAudio.tone(1.2)); try feed(s, HAudio.quiet(1.2))
        XCTAssertTrue(waitFor { turbo.calls.count == 1 })
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertEqual(events.ended.count, 1)
        XCTAssertTrue(events.settled.isEmpty)
    }

    func testANoiseVerdictIsSettledAsAnEmptyPhrase() throws {
        turbo.respond = { _ in FakeTranscriber.result("[BLANK_AUDIO]") }
        let s = settler(accurate: turbo)
        try feed(s, HAudio.tone(1.2)); try feed(s, HAudio.quiet(1.2))
        XCTAssertTrue(waitFor { !events.settled.isEmpty })
        XCTAssertEqual(events.settled.map(\.text), [""])
    }

    func testAClickOrACoughIsNeverSentToTheModel() throws {
        let s = settler(accurate: turbo)
        try feed(s, HAudio.quiet(0.5)); try feed(s, HAudio.tone(0.15)); try feed(s, HAudio.quiet(1.5))
        XCTAssertTrue(turbo.calls.isEmpty)
        XCTAssertTrue(events.all.isEmpty)
    }

    func testClosingSettlesThePhraseBeingSpokenAndWaitsForIt() throws {
        turbo.respond = { _ in Thread.sleep(forTimeInterval: 0.3); return FakeTranscriber.result("Pay the rent.") }
        let s = settler(accurate: turbo)
        try feed(s, HAudio.tone(1.4))
        s.flushAndClose()
        XCTAssertEqual(events.ended.count, 1)
        XCTAssertEqual(events.settled.map(\.text), ["Pay the rent."], "there when the close returns")
    }

    func testClosingGivesUpOnAPassThatTakesTooLong() throws {
        turbo.respond = { _ in Thread.sleep(forTimeInterval: 1.0); return FakeTranscriber.result("too late") }
        let s = settler(accurate: turbo, timeout: 0.2)
        try feed(s, HAudio.tone(1.4))
        let started = Date()
        s.flushAndClose()
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.7)
        XCTAssertTrue(events.settled.isEmpty)
    }

    func testAResetDropsAPassStillRunning() throws {
        turbo.respond = { _ in Thread.sleep(forTimeInterval: 0.4); return FakeTranscriber.result("old") }
        let s = settler(accurate: turbo)
        try feed(s, HAudio.tone(1.2)); try feed(s, HAudio.quiet(1.2))
        s.reset()
        Thread.sleep(forTimeInterval: 0.8)
        XCTAssertTrue(events.settled.isEmpty, "the result of an old recognition is not wanted")
    }

    func testDiscardingDoesNotWaitAndStopsListening() throws {
        turbo.respond = { _ in Thread.sleep(forTimeInterval: 1.0); return FakeTranscriber.result("unwanted") }
        let s = settler(accurate: turbo)
        try feed(s, HAudio.tone(1.2)); try feed(s, HAudio.quiet(1.2))
        let started = Date()
        s.discard()
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.2)
        let before = events.all.count
        try feed(s, HAudio.tone(1.2)); try feed(s, HAudio.quiet(1.2))
        XCTAssertEqual(events.all.count, before)
    }

    func testTheSinkCountsTheAudioClock() {
        let session = FakeSession { _ in }
        let queue = DispatchQueue(label: "test.clock")
        let sink = AudioHopSink(session: session, queue: queue, stats: PassStats())
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
        let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800)!
        b.frameLength = 4_800
        for i in 0..<4_800 { b.floatChannelData![0][i] = 0.1 }
        sink.append(b); sink.append(b)
        XCTAssertEqual(sink.secondsAppended, 0.2, accuracy: 0.0001)
    }
}

// MARK: - The hybrid recogniser

@MainActor
final class HybridRecognizerTests: XCTestCase {
    private var recognizer: HybridRecognizer!
    private var partials: [String] = []
    private var finished: [String] = []
    private var appleWords: [SpokenWord] = []
    private var appleText = ""

    override func setUp() {
        let accurate = WhisperAccurate(engine: WhisperEngine(accurate: true), available: false)
        recognizer = HybridRecognizer(accurate: accurate)
        partials = []; finished = []; appleWords = []; appleText = ""
        recognizer.appleWords = { [unowned self] in appleWords }
        recognizer.appleText = { [unowned self] in appleText }
        recognizer.onPartial = { [unowned self] in partials.append($0) }
        recognizer.onFinished = { [unowned self] in finished.append($0) }
        recognizer.vocabulary = { ["Rani"] }
        recognizer.beginWithoutAudio()
    }

    private func appleHeard(_ text: String, _ words: [SpokenWord]) {
        appleText = text; appleWords = words
        recognizer.recompute()
    }

    private func send(_ event: TurboSettler.Event, generation: Int? = nil) {
        recognizer.received(event, generation: generation ?? recognizer.generation)
    }

    private let timed = [word("buy", at: 0.2, for: 0.3), word("milk", at: 0.5, for: 0.3), word("and", at: 0.9, for: 0.2),
                         word("bread", at: 1.1, for: 0.4), word("then", at: 3.2, for: 0.3), word("call", at: 3.5, for: 0.3)]

    func testBeforeAnythingIsSettledItIsExactlyWhatAppleSpeechReports() {
        appleHeard("Buy milk.", [word("Buy", at: 0.2, for: 0.3), word("milk.", at: 0.5, for: 0.3)])
        XCTAssertEqual(recognizer.transcript, "Buy milk.")
        XCTAssertEqual(partials, ["Buy milk."])
        appleHeard("Buy milk. And", [word("Buy", at: 0.2, for: 0.3), word("milk.", at: 0.5, for: 0.3), word("And", at: 1.0, for: 0.2)])
        XCTAssertEqual(partials.last, "Buy milk. And")
    }

    func testASettledPhraseReplacesAppleSpeechsWordsAndTheTailStaysLive() {
        appleHeard("buy milk and bread then call", timed)
        send(.phraseEnded(id: 1, start: 0, end: 1.8))
        XCTAssertEqual(recognizer.transcript, "buy milk and bread then call", "waiting for the accurate model changes nothing")
        send(.settled(id: 1, text: "Buy milk and bread.", words: [], latencyMs: 900))
        XCTAssertEqual(recognizer.transcript, "Buy milk and bread. then call")
        XCTAssertEqual(partials.last, "Buy milk and bread. then call")
        XCTAssertEqual(recognizer.words.map(\.text), ["Buy", "milk", "and", "bread.", "then", "call"])
    }

    func testTheAccurateTextIsRepairedForBrandsLikeAnyOther() {
        appleHeard("order from blink it", [word("order", at: 0.1, for: 0.3), word("from", at: 0.5, for: 0.2),
                                           word("blink", at: 0.8, for: 0.3), word("it", at: 1.1, for: 0.2)])
        send(.phraseEnded(id: 1, start: 0, end: 1.6))
        send(.settled(id: 1, text: "Order from blink it.", words: [], latencyMs: 500))
        XCTAssertTrue(recognizer.transcript.contains("Blinkit"), recognizer.transcript)
    }

    func testAnEventFromBeforeARestartIsDropped() {
        let old = recognizer.generation
        recognizer.beginWithoutAudio()
        send(.phraseEnded(id: 1, start: 0, end: 1.8), generation: old)
        XCTAssertTrue(recognizer.phrasesForTests.isEmpty)
        send(.phraseEnded(id: 1, start: 0, end: 1.8))
        XCTAssertEqual(recognizer.phrasesForTests.count, 1)
    }

    func testAResultForAnUnknownPhraseIsIgnored() {
        send(.settled(id: 7, text: "ghost", words: [], latencyMs: 1))
        XCTAssertEqual(recognizer.transcript, "")
        XCTAssertTrue(partials.isEmpty)
    }

    func testTheFinalTextIsTheSettledPhrasesAndAppleSpeechsTail() {
        appleHeard("buy milk and bread then call", timed)
        send(.phraseEnded(id: 1, start: 0, end: 1.8))
        send(.settled(id: 1, text: "Buy milk and bread.", words: [], latencyMs: 900))
        recognizer.apple.onFinished?("Buy milk and bread then call.")
        XCTAssertEqual(finished, ["Buy milk and bread. then call"])
        recognizer.apple.onFinished?("again")
        XCTAssertEqual(finished.count, 1, "delivered once")
    }

    func testWithNothingSettledTheFinalTextIsAppleSpeechsOwn() {
        appleHeard("buy milk", [word("buy", at: 0.2, for: 0.3), word("milk", at: 0.5, for: 0.3)])
        recognizer.apple.onFinished?("Buy milk.")
        XCTAssertEqual(finished, ["Buy milk."], "its punctuation and capitals are kept")
    }

    func testAPhraseTheModelCalledNoiseIsNotBroughtBackFromAppleSpeech() {
        appleHeard("hmm hmm", [word("hmm", at: 0.2, for: 0.3), word("hmm", at: 0.6, for: 0.3)])
        send(.phraseEnded(id: 1, start: 0, end: 1.2))
        send(.settled(id: 1, text: "", words: [], latencyMs: 300))
        XCTAssertEqual(recognizer.transcript, "")
        recognizer.apple.onFinished?("Hmm hmm")
        XCTAssertEqual(finished, [""])
    }

    func testCancellingDeliversNothingAndDropsLateEvents() {
        let gen = recognizer.generation
        recognizer.cancel()
        send(.phraseEnded(id: 1, start: 0, end: 1), generation: gen)
        XCTAssertTrue(recognizer.phrasesForTests.isEmpty)
        recognizer.apple.onFinished?("late")
        XCTAssertTrue(finished.isEmpty)
    }

    func testRestartAndSpeakingListenNeedARunningMicrophone() {
        XCTAssertFalse(recognizer.restartRecognition())
        XCTAssertFalse(recognizer.beginSpeakingListen())
    }

    func testTheSettingsAreTheOnesAppleSpeechUses() {
        recognizer.continuous = true
        recognizer.bargeIn = true
        recognizer.errorMessage = "oops"
        XCTAssertTrue(recognizer.apple.continuous)
        XCTAssertTrue(recognizer.apple.bargeIn)
        XCTAssertEqual(recognizer.apple.errorMessage, "oops")
        XCTAssertEqual(recognizer.vocabulary?(), ["Rani"])
        XCTAssertFalse(recognizer.isRecording)
    }
}
