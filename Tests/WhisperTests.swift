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

nonisolated private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _all: [TurboSettler.Event] = []
    func add(_ e: TurboSettler.Event) { lock.lock(); _all.append(e); lock.unlock() }
    var all: [TurboSettler.Event] { lock.lock(); defer { lock.unlock() }; return _all }
}

nonisolated private final class LineLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _updates: [TranscriptLineUpdate] = []
    func add(_ u: TranscriptLineUpdate) { lock.lock(); _updates.append(u); lock.unlock() }
    var updates: [TranscriptLineUpdate] { lock.lock(); defer { lock.unlock() }; return _updates }
}

final class WhisperSessionTests: XCTestCase {

    private let transcriber = FakeTranscriber()
    private let turbo = FakeTranscriber()
    private let log = LineLog()

    private func session(prompt: String = "Rani.", config: WhisperTurnBuffer.Config = .init()) -> WhisperSession {
        WhisperSession(transcriber: transcriber, prompt: prompt, config: config) { [log] in log.add($0) }
    }

    /// A session whose accurate model is `turbo` (or none, to test the fallback).
    private func hybrid(accurate: WhisperTranscribing?, timeout: Double = 6) -> WhisperSession {
        WhisperSession(transcriber: transcriber, prompt: "Rani.", accurate: { accurate }, finalTimeout: timeout) { [log] in log.add($0) }
    }

    private func waitFor(_ seconds: Double = 3, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { if condition() { return true }; Thread.sleep(forTimeInterval: 0.01) }
        return condition()
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

    // MARK: The accurate model

    func testTheAccurateModelSettlesTheLineAndReplacesTheLiveText() throws {
        turbo.respond = { _ in FakeTranscriber.result("Buy milk and bread, then call the plumber.") }
        let s = hybrid(accurate: turbo)
        try feed(s, Audio.tone(2.2))
        let live = log.updates
        XCTAssertGreaterThanOrEqual(live.count, 2, "the live model still shows text while you talk")
        XCTAssertTrue(live.allSatisfy { !$0.isComplete })
        XCTAssertTrue(live.allSatisfy { $0.text.hasPrefix("call ") })
        XCTAssertTrue(turbo.calls.isEmpty, "the accurate model is not used for live text")

        try feed(s, Audio.quiet(1.5))
        XCTAssertTrue(waitFor { log.updates.contains { $0.isComplete } })
        let settled = try XCTUnwrap(log.updates.last(where: { $0.isComplete }))
        XCTAssertEqual(settled.id, 1, "the same line, so it replaces the live text")
        XCTAssertEqual(settled.text, "Buy milk and bread, then call the plumber.")
        XCTAssertEqual(turbo.calls.count, 1)
        XCTAssertEqual(Double(turbo.calls[0]) / 16_000, 2.2 + 0.25, accuracy: 0.5, "the accurate pass hears the whole phrase")
        XCTAssertEqual(log.updates.filter(\.isComplete).count, 1)
    }

    func testAnAccuratePassNeverBlocksTheNextPhrase() throws {
        turbo.respond = { n in Thread.sleep(forTimeInterval: 0.8); return FakeTranscriber.result("phrase \(n)") }
        let s = hybrid(accurate: turbo)
        try feed(s, Audio.tone(1.5)); try feed(s, Audio.quiet(1.2))      // the first phrase is handed to the slow model
        let started = Date()
        try feed(s, Audio.tone(1.5))                                       // and the next one is listened to at once
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5, "feeding the next phrase does not wait for the accurate pass")
        XCTAssertTrue(log.updates.contains { $0.id == 2 && !$0.isComplete }, "live text for the second phrase appears while the first is still being settled")
        try feed(s, Audio.quiet(1.2))
        XCTAssertTrue(waitFor(5) { log.updates.filter(\.isComplete).count == 2 })
        XCTAssertEqual(Set(log.updates.filter(\.isComplete).map(\.text)), ["phrase 1", "phrase 2"])
        XCTAssertEqual(Set(log.updates.filter(\.isComplete).map(\.id)), [1, 2])
    }

    func testWithoutALoadedAccurateModelTheLiveOneSettlesTheLine() throws {
        let s = hybrid(accurate: nil)
        try feed(s, Audio.tone(1.5)); try feed(s, Audio.quiet(1.5))
        let settled = try XCTUnwrap(log.updates.last)
        XCTAssertTrue(settled.isComplete, "no waiting: it is settled as soon as the pause is seen")
        XCTAssertEqual(settled.text, "call \(transcriber.calls.count)")
    }

    func testIfTheAccuratePassFailsTheLiveTextStands() throws {
        turbo.respond = { _ in nil }
        let s = hybrid(accurate: turbo)
        try feed(s, Audio.tone(1.5)); try feed(s, Audio.quiet(1.5))
        XCTAssertTrue(waitFor { log.updates.contains { $0.isComplete } })
        let lastLive = try XCTUnwrap(log.updates.last(where: { !$0.isComplete }))
        let settled = try XCTUnwrap(log.updates.last(where: { $0.isComplete }))
        XCTAssertEqual(settled.text, lastLive.text)
        XCTAssertEqual(settled.id, lastLive.id)
    }

    func testTheAccurateModelCallingItNoiseBlanksTheLine() throws {
        turbo.respond = { _ in FakeTranscriber.result("[BLANK_AUDIO]") }
        let s = hybrid(accurate: turbo)
        try feed(s, Audio.tone(1.5)); try feed(s, Audio.quiet(1.5))
        XCTAssertTrue(waitFor { log.updates.contains { $0.isComplete } })
        XCTAssertEqual(try XCTUnwrap(log.updates.last(where: { $0.isComplete })).text, "")
    }

    func testClosingWaitsForAnAccuratePassStillRunning() throws {
        turbo.respond = { _ in Thread.sleep(forTimeInterval: 0.3); return FakeTranscriber.result("Pay the rent.") }
        let s = hybrid(accurate: turbo)
        try feed(s, Audio.tone(1.4))
        s.flushAndClose()
        let settled = try XCTUnwrap(log.updates.last, "the settled text is there as soon as the close returns")
        XCTAssertTrue(settled.isComplete)
        XCTAssertEqual(settled.text, "Pay the rent.")
    }

    func testClosingGivesUpOnAnAccuratePassThatTakesTooLong() throws {
        turbo.respond = { _ in Thread.sleep(forTimeInterval: 1.0); return FakeTranscriber.result("too late") }
        let s = hybrid(accurate: turbo, timeout: 0.2)
        try feed(s, Audio.tone(1.4))
        let started = Date()
        s.flushAndClose()
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.7)
        XCTAssertFalse(log.updates.contains { $0.text == "too late" })
    }

    func testDiscardingDoesNotWaitForAnything() throws {
        turbo.respond = { _ in Thread.sleep(forTimeInterval: 1.0); return FakeTranscriber.result("unwanted") }
        let s = hybrid(accurate: turbo)
        try feed(s, Audio.tone(1.5)); try feed(s, Audio.quiet(1.2))
        let started = Date()
        s.discard()
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.2)
        let before = transcriber.calls.count
        try feed(s, Audio.tone(1))
        XCTAssertEqual(transcriber.calls.count, before, "nothing is processed after a discard")
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
}

// MARK: - The engine choice

final class SpeechEngineChoiceTests: XCTestCase {

    private func defaults() -> UserDefaults {
        let name = "kitty.test.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    func testTheDefaultIsWhisperTurboUntilYouPickAnother() {
        XCTAssertEqual(SpeechEngineChoice.stored(in: defaults()), .whisperTurbo)
    }

    func testTheOldMoonshineSwitchOnlyKeepsAnAppleSpeechChoice() {
        let on = defaults(); on.set(true, forKey: SpeechEngineChoice.legacyMoonshineKey)
        XCTAssertEqual(SpeechEngineChoice.stored(in: on), .whisperTurbo, "Moonshine is gone: it becomes the default")
        let off = defaults(); off.set(false, forKey: SpeechEngineChoice.legacyMoonshineKey)
        XCTAssertEqual(SpeechEngineChoice.stored(in: off), .apple)
        let old = defaults(); old.set("moonshine", forKey: SpeechEngineChoice.key)
        XCTAssertEqual(SpeechEngineChoice.stored(in: old), .whisperTurbo)
    }

    func testTheMenuOffersTurboAndAppleAndTheQuickWhisperOnlyIfItsModelIsThere() {
        let choices = SpeechEngineChoice.menuChoices
        XCTAssertTrue(choices.contains(.whisperTurbo))
        XCTAssertTrue(choices.contains(.apple))
        XCTAssertEqual(choices.contains(.whisper), SpeechEngineChoice.whisper.isAvailable)
        XCTAssertFalse(SpeechEngineChoice.whisper.isAvailable, "the app does not bundle the live model any more")
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

    func testTurboFallsBackToTheQuickWhisperThenToAppleSpeech() {
        let d = defaults()
        SpeechEngineChoice.store(.whisperTurbo, in: d)
        XCTAssertEqual(SpeechEngineChoice.effective(in: d, available: { _ in true }), .whisperTurbo)
        XCTAssertEqual(SpeechEngineChoice.effective(in: d, available: { $0 != .whisperTurbo }), .whisper)
        XCTAssertEqual(SpeechEngineChoice.effective(in: d, available: { $0 == .apple }), .apple)
        XCTAssertEqual(SpeechEngineChoice.effective(in: d, available: { $0 == .apple }), .apple)
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
        XCTAssertTrue(VoiceConversation.makeRecognizer(for: .whisperTurbo) is HybridRecognizer)
        XCTAssertEqual((VoiceConversation.makeRecognizer(for: .whisper) as? WhisperRecognizer)?.accurate, false)
        XCTAssertTrue(VoiceConversation.makeRecognizer(for: .apple) is SpeechRecognizer)
        for choice in SpeechEngineChoice.allCases {
            XCTAssertEqual(VoiceConversation.engine(of: VoiceConversation.makeRecognizer(for: choice)), choice)
        }
    }
}

// MARK: - Where the accurate model is

final class WhisperModelLookupTests: XCTestCase {

    private func folder(with files: [String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kitty-model-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for f in files { FileManager.default.createFile(atPath: dir.appendingPathComponent(f).path, contents: Data([0])) }
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func testTheFirstFolderWithAModelWins() throws {
        let empty = try folder(with: ["notes.txt"])
        let one = try folder(with: ["ggml-small.en-q5_1.bin"])
        let two = try folder(with: ["ggml-base.en.bin"])
        XCTAssertNil(WhisperModel.firstBinary(in: [empty]))
        XCTAssertEqual(WhisperModel.firstBinary(in: [empty, one, two])?.lastPathComponent, "ggml-small.en-q5_1.bin")
    }

    func testThe5BitTurboFileIsPreferredToThe16BitOne() throws {
        let dir = try folder(with: ["ggml-large-v3-turbo.bin", "ggml-large-v3-turbo-q5_0.bin"])
        let env = ["KITTY_WHISPER_TURBO_MODEL": dir.path]
        XCTAssertEqual(WhisperModel.accurateBinaryURL(simulator: false, environment: env)?.lastPathComponent, "ggml-large-v3-turbo-q5_0.bin")
    }

    func testTheSimulatorHasNoAccurateModelUnlessAskedFor() throws {
        let dir = try folder(with: ["ggml-large-v3-turbo-q5_0.bin"])
        XCTAssertNil(WhisperModel.accurateBinaryURL(simulator: true, environment: ["KITTY_WHISPER_TURBO_MODEL": dir.path]))
        XCTAssertNotNil(WhisperModel.accurateBinaryURL(simulator: true, environment: ["KITTY_WHISPER_TURBO_MODEL": dir.path, "KITTY_WHISPER_TURBO_SIM": "1"]))
    }

    func testTheEncoderIsLookedForBesideTheModelWithoutTheQuantSuffix() {
        let turbo = URL(fileURLWithPath: "/m/large-v3-turbo/ggml-large-v3-turbo-q5_0.bin")
        XCTAssertEqual(WhisperEngine.encoderURL(for: turbo).lastPathComponent, "ggml-large-v3-turbo-encoder.mlmodelc")
        let small = URL(fileURLWithPath: "/m/small.en/ggml-small.en-q5_1.bin")
        XCTAssertEqual(WhisperEngine.encoderURL(for: small).lastPathComponent, "ggml-small.en-encoder.mlmodelc")
        let f16 = URL(fileURLWithPath: "/m/x/ggml-large-v3-turbo.bin")
        XCTAssertEqual(WhisperEngine.encoderURL(for: f16).lastPathComponent, "ggml-large-v3-turbo-encoder.mlmodelc")
        XCTAssertEqual(WhisperEngine.encoderURL(for: turbo).deletingLastPathComponent(), turbo.deletingLastPathComponent())
    }

    func testAnEncoderBesideTheModelIsFoundAndNoneIsReported() throws {
        let dir = try folder(with: ["ggml-large-v3-turbo-q5_0.bin"])
        let model = dir.appendingPathComponent("ggml-large-v3-turbo-q5_0.bin")
        XCTAssertFalse(WhisperEngine.hasEncoder(for: model))
        try FileManager.default.createDirectory(at: WhisperEngine.encoderURL(for: model), withIntermediateDirectories: true)
        XCTAssertTrue(WhisperEngine.hasEncoder(for: model))
    }

    /// The reason the app is small: the 1.2 GB CoreML encoder and the live model are not in the bundle.
    func testTheAppShipsTurboWithoutItsCoreMLEncoderOrTheLiveModel() throws {
        let whisper = try XCTUnwrap(Bundle.main.resourceURL).appendingPathComponent("Whisper")
        let turbo = whisper.appendingPathComponent(WhisperModel.accurateFolder)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: turbo.path)) ?? []
        XCTAssertTrue(files.contains { $0.hasSuffix(".bin") }, "run `sh Whisper/fetch-models.sh turbo` and rebuild")
        XCTAssertFalse(files.contains { $0.hasSuffix(".mlmodelc") }, "a CoreML encoder in the app adds 1.2 GB")
        for live in WhisperModel.folders {
            XCTAssertFalse(FileManager.default.fileExists(atPath: whisper.appendingPathComponent(live).path), "\(live) is not bundled")
        }
    }

    func testTheAccurateFolderIsNotOneOfTheLiveOnes() {
        XCTAssertFalse(WhisperModel.folders.contains(WhisperModel.accurateFolder))
        XCTAssertEqual(WhisperModel.accurateFolder, "large-v3-turbo")
    }
}

@MainActor
final class WhisperAccurateTests: XCTestCase {

    func testWithoutTheModelItIsUnavailableAndNothingLoads() async {
        let accurate = WhisperAccurate(engine: WhisperEngine(accurate: true), available: false)
        XCTAssertEqual(accurate.status, .unavailable)
        accurate.prepare(keyTerms: ["Rani"])
        await accurate.waitUntilLoaded()
        XCTAssertEqual(accurate.status, .unavailable)
        XCTAssertNil(accurate.provider())
    }

    func testALoadThatFailsIsReportedAndCanBeTriedAgain() async throws {
        // On the simulator there is no accurate model, so the engine cannot load: the status says so and nothing is offered.
        try XCTSkipIf(WhisperModel.isAccurateAvailable, "this machine has the accurate model")
        let accurate = WhisperAccurate(engine: WhisperEngine(accurate: true), available: true)
        XCTAssertEqual(accurate.status, .notLoaded)
        accurate.prepare(keyTerms: ["Rani"])
        XCTAssertEqual(accurate.status, .loading)
        await accurate.waitUntilLoaded()
        XCTAssertEqual(accurate.status, .failed)
        XCTAssertNil(accurate.provider(), "a model that did not load is never handed to a session")
        accurate.prepare(keyTerms: ["Rani"])
        XCTAssertEqual(accurate.status, .loading, "the next conversation tries again")
        await accurate.waitUntilLoaded()
    }

    func testTheHybridRecogniserKnowsItIsAccurate() {
        let accurate = WhisperAccurate(engine: WhisperEngine(accurate: true), available: false)
        XCTAssertTrue(WhisperRecognizer(engine: FakeEngine(), accurate: accurate).accurate)
        XCTAssertFalse(WhisperRecognizer(engine: FakeEngine()).accurate)
    }

    func testCancellingClosesTheSession() throws {
        let engine = FakeEngine()
        let recognizer = WhisperRecognizer(engine: engine)
        try recognizer.beginWithoutAudio()
        XCTAssertEqual(engine.sessions.count, 1)
        recognizer.cancel()
        XCTAssertTrue(waitUntil { engine.sessions.allSatisfy(\.closed) })
    }

    private func waitUntil(_ seconds: Double = 2, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { if condition() { return true }; Thread.sleep(forTimeInterval: 0.01) }
        return condition()
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

    /// The accurate model on its own, through the pause detector the app uses: each phrase is transcribed once, when you pause. The
    /// simulator does not bundle turbo, so point at it:
    /// `TEST_RUNNER_KITTY_WHISPER_TURBO=1 TEST_RUNNER_KITTY_WHISPER_TURBO_SIM=1
    /// TEST_RUNNER_KITTY_WHISPER_TURBO_MODEL=$PWD/Whisper/large-v3-turbo TEST_RUNNER_KITTY_WHISPER_WAV=…` (the CPU runs the encoder: slow).
    func testTheAccurateModelSettlesEachPhrase() throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["KITTY_WHISPER_TURBO"] == "1", "set KITTY_WHISPER_TURBO=1 to run the real accurate model")
        let path = try XCTUnwrap(env["KITTY_WHISPER_WAV"], "KITTY_WHISPER_WAV is the recording to transcribe")
        try XCTSkipUnless(WhisperModel.isAccurateAvailable, "the accurate model was not found (KITTY_WHISPER_TURBO_MODEL / KITTY_WHISPER_TURBO_SIM)")

        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let samples = MonoAudio.samples(from: buffer)
        let rate = Int32(file.processingFormat.sampleRate)

        let turbo = WhisperEngine(accurate: true)
        let loadStart = Date()
        try turbo.load(keyTerms: KeyTerms.build(household: ["Rani", "Suresh"]), boost: 0)
        print("KITTY whisper-turbo loaded in", Int(Date().timeIntervalSince(loadStart) * 1000), "ms")

        let events = EventLog()
        let settler = TurboSettler(accurate: { turbo }, prompt: WhisperPrompt.build(from: KeyTerms.build(household: ["Rani", "Suresh"])),
                                   finalTimeout: 300) { events.add($0) }
        let chunk = Int(rate) / 10
        var i = 0
        while i < samples.count {
            try settler.add(Array(samples[i..<min(i + chunk, samples.count)]), sampleRate: rate)
            i += chunk
        }
        try settler.add(Audio.quiet(1.5, rate: Double(rate)), sampleRate: rate)
        settler.flushAndClose()

        let settled = events.all.compactMap { event -> String? in
            if case .settled(_, let text, _, _) = event { return text }
            return nil
        }
        for case .phraseEnded(let id, let start, let end) in events.all {
            print("KITTY phrase \(id): \(String(format: "%.1f", start))-\(String(format: "%.1f", end)) s")
        }
        print("KITTY turbo settled:", settled.joined(separator: " "))
        XCTAssertFalse(settled.joined().isEmpty, "nothing was settled")
        turbo.unload()
    }
}
