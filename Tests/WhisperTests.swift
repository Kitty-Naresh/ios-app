import XCTest
import AVFoundation
@testable import Kitty

// MARK: - Test audio

private nonisolated enum Audio {
    /// A steady 220 Hz tone: loud enough to count as speech.
    static func tone(_ seconds: Double, rate: Double = 16_000, amplitude: Float = 0.3) -> [Float] {
        (0..<Int(seconds * rate)).map { amplitude * Float(sin(2 * Double.pi * 220 * Double($0) / rate)) }
    }

    static func quiet(_ seconds: Double, rate: Double = 16_000) -> [Float] {
        [Float](repeating: 0, count: Int(seconds * rate))
    }

    static func chunks(_ samples: [Float], size: Int) -> [[Float]] {
        stride(from: 0, to: samples.count, by: size).map { Array(samples[$0..<min($0 + size, samples.count)]) }
    }
}

// MARK: - 16 kHz mono

final class StreamResamplerTests: XCTestCase {

    func testFortyEightKilohertzBecomesSixteen() {
        let out = StreamResampler(inputRate: 48_000).process(Audio.tone(1, rate: 48_000))
        XCTAssertEqual(out.count, 16_000)
    }

    func testFortyFourOneBecomesAboutSixteen() {
        let out = StreamResampler(inputRate: 44_100).process(Audio.tone(1, rate: 44_100))
        XCTAssertEqual(Double(out.count), 16_000, accuracy: 2)
    }

    func testSixteenKilohertzPassesThroughUnchanged() {
        let input = Audio.tone(0.5)
        XCTAssertEqual(StreamResampler(inputRate: 16_000).process(input), input)
    }

    func testChunksGiveTheSameResultAsOneBlock() {
        let input = Audio.tone(1, rate: 44_100)
        let whole = StreamResampler(inputRate: 44_100).process(input)
        let resampler = StreamResampler(inputRate: 44_100)
        let pieces = Audio.chunks(input, size: 1_000).flatMap { resampler.process($0) }
        XCTAssertEqual(pieces.count, whole.count)
        for (a, b) in zip(pieces, whole) { XCTAssertEqual(a, b, accuracy: 1e-5) }
    }

    func testALevelIsKeptWhenAveraging() {
        let out = StreamResampler(inputRate: 48_000).process([Float](repeating: 0.5, count: 4_800))
        XCTAssertEqual(out.count, 1_600)
        for x in out { XCTAssertEqual(x, 0.5, accuracy: 1e-5) }
    }

    func testAToneKeepsItsLoudnessAfterTheDownSample() {
        let out = StreamResampler(inputRate: 48_000).process(Audio.tone(1, rate: 48_000, amplitude: 0.3))
        let rms = (out.reduce(0) { $0 + $1 * $1 } / Float(out.count)).squareRoot()
        XCTAssertEqual(Double(rms), 0.3 / 2.0.squareRoot(), accuracy: 0.03)
    }
}

// MARK: - Where speech starts and stops

final class WhisperTurnBufferTests: XCTestCase {

    private func events(_ pieces: [[Float]], config: WhisperTurnBuffer.Config = .init()) -> (events: [WhisperTurnBuffer.Event], buffer: WhisperTurnBuffer) {
        var buffer = WhisperTurnBuffer(config: config)
        var out: [WhisperTurnBuffer.Event] = []
        for p in pieces { out += buffer.append(p) }
        return (out, buffer)
    }

    func testSilenceNeverStartsAnything() {
        let (e, buffer) = events([Audio.quiet(5)])
        XCTAssertTrue(e.isEmpty)
        XCTAssertFalse(buffer.inSpeech)
    }

    func testAQuietRoomIsNotSpeech() {
        let hiss = (0..<80_000).map { _ in Float.random(in: -0.004...0.004) }
        XCTAssertTrue(events([hiss]).events.isEmpty)
    }

    func testSpeechThenQuietStartsAndEndsOnce() {
        let (e, buffer) = events([Audio.quiet(0.5), Audio.tone(2), Audio.quiet(1.5)])
        XCTAssertEqual(e.count, 2)
        XCTAssertEqual(e.first, .started)
        guard case .ended(let samples, let voiced) = e.last else { return XCTFail("no end event: \(e)") }
        XCTAssertTrue(voiced)
        // 2 s of voice, a little pre-roll from before it, and the short tail after it: well under the 1.5 s of quiet that followed.
        let seconds = Double(samples.count) / 16_000
        XCTAssertGreaterThan(seconds, 2.0)
        XCTAssertLessThan(seconds, 2.8)
        XCTAssertFalse(buffer.inSpeech)
        XCTAssertTrue(buffer.samples.isEmpty)
    }

    func testTheEndNeedsTheWholePause() {
        let (e, buffer) = events([Audio.tone(1), Audio.quiet(0.5), Audio.tone(1), Audio.quiet(0.4)])
        XCTAssertEqual(e, [.started], "a short pause in the middle of a sentence does not end it")
        XCTAssertTrue(buffer.inSpeech)
    }

    func testACoughIsNotVoiced() {
        let (e, _) = events([Audio.quiet(0.3), Audio.tone(0.15), Audio.quiet(1.5)])
        XCTAssertEqual(e.count, 2)
        guard case .ended(_, let voiced) = e.last else { return XCTFail("no end event") }
        XCTAssertFalse(voiced)
    }

    func testAClickShorterThanTheStartWindowIsIgnored() {
        XCTAssertTrue(events([Audio.quiet(0.3), Audio.tone(0.05), Audio.quiet(2)]).events.isEmpty)
    }

    func testThePreRollKeepsTheStartOfTheFirstWord() {
        let (e, _) = events([Audio.quiet(1), Audio.tone(1), Audio.quiet(1.5)])
        guard case .ended(let samples, _) = e.last else { return XCTFail("no end event") }
        let lead = Array(samples.prefix(Int(0.2 * 16_000)))
        XCTAssertTrue(lead.contains { $0 == 0 }, "the stretch begins with a little quiet from before the voice")
    }

    func testALongTurnIsCappedAndContinues() {
        var config = WhisperTurnBuffer.Config()
        config.maxTurnSeconds = 2
        let (e, buffer) = events([Audio.tone(5)], config: config)
        let capped = e.filter { if case .capped = $0 { return true } else { return false } }
        XCTAssertEqual(capped.count, 2)
        XCTAssertTrue(buffer.inSpeech, "the turn goes on after a cap")
        if case .capped(let samples) = capped[0] { XCTAssertGreaterThanOrEqual(samples.count, 2 * 16_000) }
    }

    func testTheSizeOfTheChunksDoesNotChangeWhatIsFound() {
        let audio = Audio.quiet(0.5) + Audio.tone(1.5) + Audio.quiet(1.5)
        let whole = events([audio]).events
        let odd = events(Audio.chunks(audio, size: 1_237)).events
        XCTAssertEqual(whole.count, odd.count)
        XCTAssertEqual(whole.first, odd.first)
    }

    func testDrainHandsOverAnUnfinishedTurn() {
        var buffer = WhisperTurnBuffer()
        _ = buffer.append(Audio.tone(1.5))
        XCTAssertTrue(buffer.inSpeech)
        let (samples, voiced) = buffer.drain()
        XCTAssertTrue(voiced)
        XCTAssertGreaterThan(samples.count, 20_000)
        XCTAssertFalse(buffer.inSpeech)
        XCTAssertTrue(buffer.samples.isEmpty)
    }
}

// MARK: - Whisper's habits on weak audio

final class WhisperTextTests: XCTestCase {

    func testTextPassesThroughAsSpoken() {
        XCTAssertEqual(WhisperText.clean("Buy milk and bread, then call the plumber."), "Buy milk and bread, then call the plumber.")
    }

    func testNoiseLabelsAreRemoved() {
        XCTAssertEqual(WhisperText.clean("[BLANK_AUDIO]"), "")
        XCTAssertEqual(WhisperText.clean("(music) Buy milk *sigh* please"), "Buy milk please")
        XCTAssertEqual(WhisperText.clean("♪ ♪"), "")
    }

    func testPhantomClosersAreDroppedOnlyOnAShortSound() {
        XCTAssertEqual(WhisperText.clean("Thanks for watching!", voicedSeconds: 0.8), "")
        XCTAssertEqual(WhisperText.clean("Thank you for watching.", voicedSeconds: 1.0), "")
        XCTAssertEqual(WhisperText.clean("Thank you.", voicedSeconds: 0.8), "Thank you.", "a real thank you is kept")
        XCTAssertEqual(WhisperText.clean("Thanks for watching the kids.", voicedSeconds: 0.8), "Thanks for watching the kids.")
        XCTAssertEqual(WhisperText.clean("Thanks for watching!", voicedSeconds: 6), "Thanks for watching!", "long speech is trusted")
    }

    func testAShortAnswerSurvives() {
        for word in ["Yes.", "No.", "Okay.", "Stop."] { XCTAssertEqual(WhisperText.clean(word, voicedSeconds: 0.6), word) }
    }

    func testNotSpeechAndNotSureIsDropped() {
        XCTAssertEqual(WhisperText.clean("I need milk", noSpeech: 0.8, meanConfidence: 0.3), "")
        XCTAssertEqual(WhisperText.clean("I need milk", noSpeech: 0.8, meanConfidence: 0.9), "I need milk")
        XCTAssertEqual(WhisperText.clean("I need milk", noSpeech: 0.1, meanConfidence: 0.3), "I need milk")
    }

    func testALoopedWordIsCollapsed() {
        XCTAssertEqual(WhisperText.collapseLoops("I need the the the the the the the milk"), "I need the milk")
        XCTAssertEqual(WhisperText.collapseLoops("buy milk buy milk buy milk buy milk buy milk then stop"), "buy milk then stop")
    }

    func testRealRepeatsAreLeftAlone() {
        XCTAssertEqual(WhisperText.collapseLoops("no no no it is fine"), "no no no it is fine")
        XCTAssertEqual(WhisperText.collapseLoops("buy milk and buy milk"), "buy milk and buy milk")
    }
}

// MARK: - The prompt

final class WhisperPromptTests: XCTestCase {

    func testTheNamesComeFirstAsAPlainList() {
        let prompt = WhisperPrompt.build(from: ["Rani", "Suresh", "Blinkit"])
        XCTAssertEqual(prompt, "Rani, Suresh, Blinkit.")
    }

    func testNoTermsMeansNoPrompt() {
        XCTAssertEqual(WhisperPrompt.build(from: []), "")
    }

    func testThePromptIsCappedAndKeepsTheFirstTerms() {
        let terms = (0..<200).map { "Brandname\($0)" }
        let prompt = WhisperPrompt.build(from: terms)
        XCTAssertLessThanOrEqual(prompt.count, WhisperPrompt.maxCharacters)
        XCTAssertTrue(prompt.hasPrefix("Brandname0, Brandname1,"))
        XCTAssertTrue(prompt.hasSuffix("."))
        XCTAssertFalse(prompt.contains("Brandname199"))
    }

    func testTheHouseholdAndTheBundledBrandsReachThePrompt() {
        let prompt = WhisperPrompt.build(from: KeyTerms.build(household: ["Rani"]))
        XCTAssertTrue(prompt.hasPrefix("Rani, "))
        XCTAssertTrue(prompt.contains("Blinkit") || prompt.contains("Amul") || prompt.contains("Maggi"))
    }
}

// MARK: - A session with a fake model

nonisolated final class FakeTranscriber: WhisperTranscribing, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [Int] = []
    private var _prompts: [String] = []
    /// Text for the nth call (1-based); the default is "call n".
    var respond: @Sendable (Int) -> WhisperResult? = { n in FakeTranscriber.result("call \(n)") }

    static func result(_ text: String, noSpeech: Float = 0, confidence: Float = 0.9) -> WhisperResult {
        WhisperResult(text: text, words: text.split(separator: " ").map { SpokenWord(text: String($0), confidence: confidence) },
                      noSpeech: noSpeech, meanConfidence: confidence)
    }

    var calls: [Int] { lock.lock(); defer { lock.unlock() }; return _calls }
    var prompts: [String] { lock.lock(); defer { lock.unlock() }; return _prompts }

    func transcribe(_ samples: [Float], prompt: String) -> WhisperResult? {
        lock.lock(); _calls.append(samples.count); _prompts.append(prompt); let n = _calls.count; lock.unlock()
        return respond(n)
    }
}

nonisolated private final class LineLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _updates: [TranscriptLineUpdate] = []
    func add(_ u: TranscriptLineUpdate) { lock.lock(); _updates.append(u); lock.unlock() }
    var updates: [TranscriptLineUpdate] { lock.lock(); defer { lock.unlock() }; return _updates }
}

final class WhisperSessionTests: XCTestCase {

    private let transcriber = FakeTranscriber()
    private let log = LineLog()

    private func session(prompt: String = "Rani.", config: WhisperTurnBuffer.Config = .init()) -> WhisperSession {
        WhisperSession(transcriber: transcriber, prompt: prompt, config: config) { [log] in log.add($0) }
    }

    /// Feeds 48 kHz audio in 100 ms pieces, the way the microphone does.
    private func feed(_ s: WhisperSession, _ samples16k: [Float]) throws {
        let at48 = samples16k.flatMap { [Float](repeating: $0, count: 3) }
        for piece in Audio.chunks(at48, size: 4_800) { try s.add(piece, sampleRate: 48_000) }
    }

    func testSilenceNeverReachesTheModel() throws {
        let s = session()
        try feed(s, Audio.quiet(5))
        s.flushAndClose()
        XCTAssertTrue(transcriber.calls.isEmpty)
        XCTAssertTrue(log.updates.isEmpty)
    }

    func testSpeechGrowsALiveLineAndASettledOneWhenTheSpeakerStops() throws {
        let s = session()
        try feed(s, Audio.tone(2.2))
        let partials = log.updates
        XCTAssertGreaterThanOrEqual(partials.count, 2, "a pass about every 0.6 s of speech")
        XCTAssertTrue(partials.allSatisfy { $0.id == 1 && !$0.isComplete })

        try feed(s, Audio.quiet(1.5))
        let last = try XCTUnwrap(log.updates.last)
        XCTAssertEqual(last.id, 1)
        XCTAssertTrue(last.isComplete)
        XCTAssertEqual(last.text, "call \(transcriber.calls.count)", "the settled text comes from the last pass")
        XCTAssertEqual(last.words.map(\.text), ["call", "\(transcriber.calls.count)"])
        XCTAssertGreaterThan(log.updates.count, partials.count)
    }

    func testTheModelGetsSixteenKilohertzAndOnlyWhileSomeoneTalks() throws {
        let s = session()
        try feed(s, Audio.quiet(2))
        try feed(s, Audio.tone(1.8))
        try feed(s, Audio.quiet(2))
        XCTAssertFalse(transcriber.calls.isEmpty)
        let seconds = transcriber.calls.map { Double($0) / 16_000 }
        XCTAssertTrue(seconds.allSatisfy { $0 > 0.4 && $0 < 3 }, "never the 4 s of quiet: \(seconds)")
        XCTAssertEqual(seconds.last ?? 0, 1.8 + 0.25, accuracy: 0.45, "the last pass is the whole stretch")
        let partials = Array(transcriber.calls.dropLast())     // the last call is the settled pass, which drops the trailing quiet
        XCTAssertEqual(partials, partials.sorted(), "each live pass covers at least as much as the one before")
    }

    func testASlowModelIsNotRunFlatOut() throws {
        transcriber.respond = { n in Thread.sleep(forTimeInterval: 0.2); return FakeTranscriber.result("call \(n)") }
        let s = session()
        try feed(s, Audio.tone(3))        // 3 s of speech arrives at once; a model that takes 0.2 s a pass gets time to rest
        XCTAssertGreaterThanOrEqual(transcriber.calls.count, 1)
        XCTAssertLessThanOrEqual(transcriber.calls.count, 2, "it would be five passes if it ran back to back")
    }

    func testEachStretchIsItsOwnLine() throws {
        let s = session()
        try feed(s, Audio.tone(1.5)); try feed(s, Audio.quiet(1.2))
        try feed(s, Audio.tone(1.5)); try feed(s, Audio.quiet(1.2))
        XCTAssertEqual(Set(log.updates.map(\.id)), [1, 2])
        XCTAssertEqual(log.updates.filter(\.isComplete).map(\.id), [1, 2])
    }

    func testTheNamesAndBrandsGoToTheModelAsThePrompt() throws {
        let s = session(prompt: "Rani, Blinkit.")
        try feed(s, Audio.tone(1.5)); try feed(s, Audio.quiet(1.2))
        XCTAssertFalse(transcriber.prompts.isEmpty)
        XCTAssertTrue(transcriber.prompts.allSatisfy { $0 == "Rani, Blinkit." })
    }

    func testAMadeUpClosingPhraseOnAShortSoundShowsNothing() throws {
        transcriber.respond = { _ in FakeTranscriber.result("Thanks for watching!") }
        let s = session()
        try feed(s, Audio.tone(0.7)); try feed(s, Audio.quiet(1.5))
        XCTAssertTrue(log.updates.isEmpty)
    }

    func testAFinalThatIsNoiseBlanksAnEarlierPartial() throws {
        transcriber.respond = { n in n == 1 ? FakeTranscriber.result("Buy milk") : FakeTranscriber.result("[BLANK_AUDIO]") }
        let s = session()
        try feed(s, Audio.tone(1.4)); try feed(s, Audio.quiet(1.5))
        let last = try XCTUnwrap(log.updates.last)
        XCTAssertEqual(last.text, "")
        XCTAssertTrue(last.isComplete)
    }

    func testIfTheFinalPassFailsTheLastPartialStands() throws {
        transcriber.respond = { n in n == 1 ? FakeTranscriber.result("Buy milk") : nil }
        let s = session()
        try feed(s, Audio.tone(1.4)); try feed(s, Audio.quiet(1.5))
        let last = try XCTUnwrap(log.updates.last)
        XCTAssertEqual(last.text, "Buy milk")
        XCTAssertTrue(last.isComplete)
    }

    func testClosingMidSentenceSettlesTheLine() throws {
        let s = session()
        try feed(s, Audio.tone(1.4))
        let before = transcriber.calls.count
        s.flushAndClose()
        XCTAssertEqual(transcriber.calls.count, before + 1)
        XCTAssertTrue(try XCTUnwrap(log.updates.last).isComplete)
        try feed(s, Audio.tone(1))
        XCTAssertEqual(transcriber.calls.count, before + 1, "nothing is processed after the close")
    }

    func testALongTurnIsSplitIntoLines() throws {
        var config = WhisperTurnBuffer.Config()
        config.maxTurnSeconds = 1.5
        let s = session(config: config)
        try feed(s, Audio.tone(4))
        XCTAssertEqual(Set(log.updates.map(\.id)).count, 3)
        XCTAssertGreaterThanOrEqual(log.updates.filter(\.isComplete).count, 2)
    }

    func testAChangeOfSampleRateIsHandled() throws {
        let s = session()
        for piece in Audio.chunks(Audio.tone(1.0, rate: 44_100), size: 4_410) { try s.add(piece, sampleRate: 44_100) }
        for piece in Audio.chunks(Audio.tone(1.0, rate: 48_000), size: 4_800) { try s.add(piece, sampleRate: 48_000) }
        s.flushAndClose()
        XCTAssertTrue(try XCTUnwrap(log.updates.last).isComplete)
        let seconds = Double(transcriber.calls.last ?? 0) / 16_000
        XCTAssertEqual(seconds, 2.0, accuracy: 0.15)
    }
}

// MARK: - The recogniser with a fake engine

@MainActor
final class WhisperRecognizerTests: XCTestCase {
    private var engine = FakeEngine()
    private var recognizer: WhisperRecognizer!
    private var partials: [String] = []

    override func setUp() {
        engine = FakeEngine()
        recognizer = WhisperRecognizer(engine: engine)
        partials = []
        recognizer.onPartial = { [unowned self] in partials.append($0) }
        recognizer.vocabulary = { ["Rani", "Suresh"] }
    }

    private func line(_ id: UInt64, _ text: String, done: Bool = false, words: [SpokenWord] = []) -> TranscriptLineUpdate {
        TranscriptLineUpdate(id: id, text: text, isComplete: done, words: words)
    }

    private func feed(_ update: TranscriptLineUpdate) { recognizer.received(update, session: recognizer.sessionID) }

    func testLivePartialsThenSettledLinesBuildTheTranscript() throws {
        try recognizer.beginWithoutAudio()
        feed(line(1, "Buy milk"))
        feed(line(1, "Buy milk and bread."))
        feed(line(1, "Buy milk and bread.", done: true))
        feed(line(2, "Then call the plumber."))
        XCTAssertEqual(recognizer.transcript, "Buy milk and bread. Then call the plumber.")
        XCTAssertEqual(partials, ["Buy milk", "Buy milk and bread.", "Buy milk and bread. Then call the plumber."])
    }

    func testWordConfidenceIsPassedOn() throws {
        try recognizer.beginWithoutAudio()
        feed(line(1, "Buy milk.", words: [SpokenWord(text: "Buy", confidence: 0.9), SpokenWord(text: "milk.", confidence: 0.4)]))
        feed(line(2, "Call Rani.", words: [SpokenWord(text: "Call", confidence: 0.8), SpokenWord(text: "Rani.", confidence: 0.7)]))
        XCTAssertEqual(recognizer.words.map(\.text), ["Buy", "milk.", "Call", "Rani."])
        XCTAssertEqual(recognizer.words[1].confidence, 0.4, accuracy: 0.001)
    }

    func testABlankedLineLeavesTheTranscript() throws {
        try recognizer.beginWithoutAudio()
        feed(line(1, "Buy milk."))
        feed(line(1, "", done: true))
        XCTAssertEqual(recognizer.transcript, "")
    }

    func testABrandIsRepairedAndHouseholdNamesAreNot() throws {
        try recognizer.beginWithoutAudio()
        feed(line(1, "Order milk from blink it tonight."))
        XCTAssertEqual(recognizer.transcript, "Order milk from Blinkit tonight.")
        recognizer.vocabulary = { ["Maggie"] }
        try recognizer.beginWithoutAudio()
        feed(line(1, "Ask Maggie to cook."))
        XCTAssertEqual(recognizer.transcript, "Ask Maggie to cook.")
    }

    func testTheHouseholdThenTheBrandsAreHandedToTheEngine() async throws {
        await recognizer.prepare()
        let terms = try XCTUnwrap(engine.keyTerms.first)
        XCTAssertEqual(Array(terms.prefix(2)), ["Rani", "Suresh"])
        XCTAssertTrue(terms.contains("Blinkit"))
    }

    func testARestartDropsLateLinesOfTheOldSession() throws {
        try recognizer.beginWithoutAudio()
        let old = recognizer.sessionID
        feed(line(1, "Buy milk."))
        XCTAssertTrue(recognizer.restartRecognition())
        XCTAssertEqual(recognizer.transcript, "")
        XCTAssertEqual(engine.sessions.count, 2)
        recognizer.received(line(2, "stale words from before"), session: old)
        XCTAssertEqual(recognizer.transcript, "")
        feed(line(1, "Call the plumber."))
        XCTAssertEqual(recognizer.transcript, "Call the plumber.")
    }

    func testARestartNeedsARunningMicrophone() {
        XCTAssertFalse(recognizer.restartRecognition())
        XCTAssertFalse(recognizer.beginSpeakingListen())
    }

    func testCancelDeliversNothingAndStopDeliversTheSettledTranscript() throws {
        var finished: [String] = []
        recognizer.onFinished = { finished.append($0) }
        try recognizer.beginWithoutAudio()
        feed(line(1, "Buy milk."))
        recognizer.cancel()
        XCTAssertFalse(recognizer.isRecording)
        XCTAssertEqual(finished, [])

        try recognizer.beginWithoutAudio()
        let delivered = expectation(description: "finished")
        recognizer.onFinished = { finished.append($0); delivered.fulfill() }
        feed(line(1, "Pay the rent."))
        recognizer.stop()
        wait(for: [delivered], timeout: 2)
        XCTAssertEqual(finished, ["Pay the rent."])
        XCTAssertTrue(engine.sessions.last?.closed == true)
    }

    func testTheEngineCallbackReachesTheMainActorInOrder() throws {
        try recognizer.beginWithoutAudio()
        let session = try XCTUnwrap(engine.sessions.last)
        let done = expectation(description: "three partials")
        done.expectedFulfillmentCount = 3
        recognizer.onPartial = { [unowned self] in partials.append($0); done.fulfill() }
        DispatchQueue.global().async {
            session.onLine(TranscriptLineUpdate(id: 1, text: "one", isComplete: false))
            session.onLine(TranscriptLineUpdate(id: 1, text: "one two", isComplete: false))
            session.onLine(TranscriptLineUpdate(id: 1, text: "one two three", isComplete: true))
        }
        wait(for: [done], timeout: 2)
        XCTAssertEqual(partials, ["one", "one two", "one two three"])
    }

    func testAModelThatCannotLoadIsReportedSoTheConversationCanFallBack() async {
        engine.loadError = NSError(domain: "test", code: 1)
        await recognizer.prepare()
        XCTAssertTrue(recognizer.modelLoadFailed)
        XCTAssertTrue(recognizer.failureIsPermanent)
        XCTAssertNotNil(recognizer.errorMessage)
    }

    func testTheModelIsInTheApp() {
        // The tests run inside the app, which bundles Whisper/<size>.en (see Whisper/fetch-models.sh).
        XCTAssertTrue(WhisperModel.isAvailable, "run `sh Whisper/fetch-models.sh` and rebuild")
        if let bin = WhisperModel.binaryURL {
            let encoder = bin.deletingLastPathComponent().appendingPathComponent(
                bin.lastPathComponent.replacingOccurrences(of: "-q5_1", with: "").replacingOccurrences(of: ".bin", with: "-encoder.mlmodelc"))
            XCTAssertTrue(FileManager.default.fileExists(atPath: encoder.path), "the CoreML encoder sits next to the model")
        }
    }
}

// MARK: - The engine choice

final class SpeechEngineChoiceTests: XCTestCase {

    private func defaults() -> UserDefaults {
        let name = "kitty.test.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    func testTheDefaultIsMoonshineUntilYouPickAnother() {
        XCTAssertEqual(SpeechEngineChoice.stored(in: defaults()), .moonshine)
    }

    func testTheOldMoonshineSwitchCarriesOver() {
        let on = defaults(); on.set(true, forKey: SpeechEngineChoice.legacyMoonshineKey)
        XCTAssertEqual(SpeechEngineChoice.stored(in: on), .moonshine)
        let off = defaults(); off.set(false, forKey: SpeechEngineChoice.legacyMoonshineKey)
        XCTAssertEqual(SpeechEngineChoice.stored(in: off), .apple)
    }

    func testTheNewChoiceWinsOverTheOldSwitch() {
        let d = defaults()
        d.set(false, forKey: SpeechEngineChoice.legacyMoonshineKey)
        SpeechEngineChoice.store(.whisper, in: d)
        XCTAssertEqual(SpeechEngineChoice.stored(in: d), .whisper)
    }

    func testEveryChoiceRoundTrips() {
        let d = defaults()
        for choice in SpeechEngineChoice.allCases {
            SpeechEngineChoice.store(choice, in: d)
            XCTAssertEqual(SpeechEngineChoice.stored(in: d), choice)
        }
    }

    func testAMissingModelFallsBackToAppleSpeech() {
        let d = defaults()
        SpeechEngineChoice.store(.whisper, in: d)
        XCTAssertEqual(SpeechEngineChoice.effective(in: d, available: { $0 != .whisper }), .apple)
        XCTAssertEqual(SpeechEngineChoice.effective(in: d, available: { _ in true }), .whisper)
        SpeechEngineChoice.store(.apple, in: d)
        XCTAssertEqual(SpeechEngineChoice.effective(in: d, available: { _ in false }), .apple)
    }

    @MainActor
    func testTheConversationBuildsTheRecogniserThatWasPicked() {
        XCTAssertTrue(VoiceConversation.makeRecognizer(for: .whisper) is WhisperRecognizer)
        XCTAssertTrue(VoiceConversation.makeRecognizer(for: .moonshine) is MoonshineRecognizer)
        XCTAssertTrue(VoiceConversation.makeRecognizer(for: .apple) is SpeechRecognizer)
        for choice in SpeechEngineChoice.allCases {
            XCTAssertEqual(VoiceConversation.engine(of: VoiceConversation.makeRecognizer(for: choice)), choice)
        }
    }
}

// MARK: - A real transcription (opt in)

/// Needs the model and a recording:
/// `TEST_RUNNER_KITTY_WHISPER=1 TEST_RUNNER_KITTY_WHISPER_WAV=/path/to/speech.wav xcodebuild test -only-testing:KittyTests/WhisperRealTests …`
/// The recording goes through the same path as the microphone: 16 kHz conversion, speech detection, passes, settled lines.
final class WhisperRealTests: XCTestCase {

    func testTranscribesARecording() throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["KITTY_WHISPER"] == "1", "set KITTY_WHISPER=1 (and KITTY_WHISPER_WAV) to run the real model")
        let path = try XCTUnwrap(env["KITTY_WHISPER_WAV"], "KITTY_WHISPER_WAV is the recording to transcribe")
        try XCTSkipUnless(WhisperModel.isAvailable, "the model is not in the app")

        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let samples = MonoAudio.samples(from: buffer)
        let rate = Int32(file.processingFormat.sampleRate)

        let engine = WhisperEngine()
        let loadStart = Date()
        try engine.load(keyTerms: KeyTerms.build(household: ["Rani", "Suresh"]), boost: 0)
        print("KITTY whisper loaded in", Int(Date().timeIntervalSince(loadStart) * 1000), "ms")
        let log = LineLog()
        let session = try engine.openSession { log.add($0) }
        let started = Date()
        let chunk = Int(rate) / 10
        var i = 0
        while i < samples.count {
            try session.add(Array(samples[i..<min(i + chunk, samples.count)]), sampleRate: rate)
            i += chunk
        }
        try session.add(Audio.quiet(1.5, rate: Double(rate)), sampleRate: rate)
        session.flushAndClose()
        let spent = Date().timeIntervalSince(started)

        var order: [UInt64] = []
        var texts: [UInt64: String] = [:]
        for u in log.updates {
            if texts[u.id] == nil { order.append(u.id) }
            texts[u.id] = u.text
        }
        let text = order.compactMap { texts[$0] }.joined(separator: " ")
        print("KITTY whisper heard:", text)
        print("KITTY whisper: \(log.updates.count) updates, \(order.count) lines, \(String(format: "%.1f", spent)) s for \(String(format: "%.1f", Double(samples.count) / Double(rate))) s of audio")
        XCTAssertFalse(text.isEmpty, "nothing was transcribed")
        engine.unload()
    }
}
