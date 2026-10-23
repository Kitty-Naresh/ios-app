import XCTest
import AVFoundation
@testable import Kitty

// MARK: - Brand fixer

final class BrandFixerTests: XCTestCase {

    private func fixed(_ text: String, protectedNames: [String] = []) -> String {
        BrandFixer.fix(text, protectedNames: protectedNames).text
    }

    func testASplitBrandIsJoinedBack() {
        XCTAssertEqual(fixed("order it from blink it tonight"), "order it from Blinkit tonight")
        XCTAssertEqual(fixed("get biscuits, parle g and maggi"), "get biscuits, Parle-G and maggi")   // a case-only difference is left alone
        XCTAssertEqual(fixed("check Urban Company for a plumber"), "check Urban Company for a plumber")
    }

    func testANearMissOfOneClearBrandIsRepaired() {
        XCTAssertEqual(fixed("buy Maggie noodles"), "buy Maggi noodles")
        XCTAssertEqual(fixed("order from zip tow"), "order from Zepto")
        XCTAssertEqual(fixed("get Haldirams namkeen"), "get Haldiram's namkeen")
        XCTAssertEqual(fixed("order from big basket."), "order from BigBasket.")
    }

    func testPunctuationAroundARepairedBrandIsKept() {
        XCTAssertEqual(fixed("Order from blink it, then call Rani."), "Order from Blinkit, then call Rani.")
        XCTAssertEqual(fixed("(blink it)"), "(Blinkit)")
    }

    func testOrdinaryPhrasesAreNeverTouched() {
        for phrase in ["pay them tomorrow", "pay the bill on Friday", "buy a blank page", "book a taxi to the airport",
                       "call the plumber", "bake a cake for the party", "we need a new driver", "add a task for the project",
                       "sweep and mop the floor", "take the dog to the vet", "pick up the groceries"] {
            XCTAssertEqual(fixed(phrase), phrase, "changed: \(phrase)")
        }
    }

    func testAShortWordIsNeverRepaired() {
        XCTAssertEqual(fixed("buy some dal and ola"), "buy some dal and ola")
        XCTAssertEqual(fixed("a mule is not Amul"), "a mule is not Amul")
    }

    func testAHouseholdNameIsProtected() {
        XCTAssertEqual(fixed("ask Maggie to cook", protectedNames: ["Maggie"]), "ask Maggie to cook")
        XCTAssertEqual(fixed("ask Maggie to cook"), "ask Maggi to cook", "without the household name it is the brand")
    }

    func testAnAmbiguousNearMissIsLeftAlone() {
        // One edit from two different terms: not a clear match.
        XCTAssertEqual(BrandFixer.fix("get some sooji", terms: ["Soojia", "Soojib"]).text, "get some sooji")
    }

    func testAnExactBrandIsNotRewritten() {
        let r = BrandFixer.fix("order from Blinkit and Zepto")
        XCTAssertTrue(r.changes.isEmpty)
        XCTAssertEqual(r.text, "order from Blinkit and Zepto")
    }

    func testTheChangesAreReported() {
        let r = BrandFixer.fix("blink it and parle g")
        XCTAssertEqual(r.changes, [.init(from: "blink it", to: "Blinkit"), .init(from: "parle g", to: "Parle-G")])
    }

    func testAnEmptyTextIsFine() {
        XCTAssertEqual(fixed(""), "")
    }
}

// MARK: - Key terms

final class KeyTermsTests: XCTestCase {

    func testHouseholdNamesComeFirstThenBrands() {
        let terms = KeyTerms.build(household: ["Rani", "Suresh"])
        XCTAssertEqual(Array(terms.prefix(2)), ["Rani", "Suresh"])
        XCTAssertTrue(terms.contains("Blinkit"))
        XCTAssertTrue(terms.contains("Aashirvaad"))
    }

    func testTheListIsCappedAndHasNoDuplicatesOrCommas() {
        let household = (0..<100).map { "Name\($0)" } + ["rani", "Rani", "blinkit", "Has, comma"]
        let terms = KeyTerms.build(household: household)
        XCTAssertLessThanOrEqual(terms.count, KeyTerms.limit)
        XCTAssertEqual(terms.count, Set(terms.map { $0.lowercased() }).count)
        XCTAssertFalse(terms.contains { $0.contains(",") })
        XCTAssertEqual(terms.filter { $0.hasPrefix("Name") }.count, KeyTerms.householdLimit, "households cannot crowd the brands out")
    }

    func testTheBundledListHasTheBrandsTheUserNamed() {
        for brand in ["Blinkit", "Zepto", "Swiggy", "Zomato", "BigBasket", "Flipkart", "Paytm", "PhonePe", "Urban Company", "Amul",
                      "Maggi", "Aashirvaad", "Haldiram's", "atta", "paneer", "kirana", "bai"] {
            XCTAssertTrue(IndianVocabulary.terms.contains(brand), brand)
        }
        XCTAssertFalse(IndianVocabulary.terms.contains { $0.contains(",") })
    }
}

// MARK: - A fake engine: line events without a model

nonisolated final class FakeSession: EngineSession, @unchecked Sendable {
    let onLine: @Sendable (TranscriptLineUpdate) -> Void
    private let lock = NSLock()
    private var _samples = 0
    private var _closed = false
    init(onLine: @escaping @Sendable (TranscriptLineUpdate) -> Void) { self.onLine = onLine }
    var samples: Int { lock.lock(); defer { lock.unlock() }; return _samples }
    var closed: Bool { lock.lock(); defer { lock.unlock() }; return _closed }
    func add(_ samples: [Float], sampleRate: Int32) throws { lock.lock(); _samples += samples.count; lock.unlock() }
    func flushAndClose() { lock.lock(); _closed = true; lock.unlock() }
}

nonisolated final class FakeEngine: StreamingEngine, @unchecked Sendable {
    private let lock = NSLock()
    var loadError: Error?
    private(set) var sessions: [FakeSession] = []
    private(set) var keyTerms: [[String]] = []
    func load(keyTerms: [String], boost: Double) throws {
        if let loadError { throw loadError }
        lock.lock(); self.keyTerms.append(keyTerms); lock.unlock()
    }
    func setKeyTerms(_ terms: [String]) throws { lock.lock(); keyTerms.append(terms); lock.unlock() }
    func openSession(onLine: @escaping @Sendable (TranscriptLineUpdate) -> Void) throws -> EngineSession {
        let s = FakeSession(onLine: onLine)
        lock.lock(); sessions.append(s); lock.unlock()
        return s
    }
    func unload() {}
}

// MARK: - The microphone sink

@MainActor
final class AudioSinkTests: XCTestCase {

    private func buffer(channels: Int, frames: Int, fill: (Int, Int) -> Float) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: AVAudioChannelCount(channels), interleaved: false)!
        let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        b.frameLength = AVAudioFrameCount(frames)
        for c in 0..<channels { for i in 0..<frames { b.floatChannelData![c][i] = fill(c, i) } }
        return b
    }

    func testStereoIsAveragedToMono() {
        let b = buffer(channels: 2, frames: 4) { c, i in c == 0 ? 0.5 : -0.1 + Float(i) * 0.1 }
        let mono = MonoAudio.samples(from: b)
        XCTAssertEqual(mono.count, 4)
        XCTAssertEqual(mono[0], 0.2, accuracy: 0.0001)
        XCTAssertEqual(mono[3], 0.35, accuracy: 0.0001)
    }

    func testMonoIsPassedThroughAndAnEmptyBufferGivesNothing() {
        let b = buffer(channels: 1, frames: 3) { _, i in Float(i) / 10 }
        XCTAssertEqual(MonoAudio.samples(from: b), [0, 0.1, 0.2])
        XCTAssertEqual(MonoAudio.samples(from: buffer(channels: 1, frames: 0) { _, _ in 0 }), [])
    }

    private final class Spy: AudioSink {
        var received = 0
        var finished = 0
        func append(_ buffer: AVAudioPCMBuffer) { received += 1 }
        func finish() { finished += 1 }
    }

    func testOneTapFeedsWhicheverSinkIsCurrentAndSwapsWithoutLosingTheMic() {
        let capture = AudioCapture()
        let a = Spy(), b = Spy()
        let buf = buffer(channels: 1, frames: 8) { _, _ in 0.1 }
        capture.swap(to: a)
        capture.append(buf); capture.append(buf)
        capture.swap(to: b)
        capture.append(buf)
        capture.swap(to: nil)
        capture.append(buf)
        XCTAssertEqual(a.received, 2)
        XCTAssertEqual(b.received, 1)
        XCTAssertEqual(a.finished, 1, "a sink that is swapped out is told no more audio is coming")
        XCTAssertEqual(b.finished, 1)
    }

    func testTheAudioHopSinkCopiesToMonoAndWorksOnItsOwnQueue() throws {
        let session = FakeSession { _ in }
        let queue = DispatchQueue(label: "test.audiohop")
        let sink = AudioHopSink(session: session, queue: queue, stats: PassStats())
        sink.append(buffer(channels: 2, frames: 480) { _, _ in 0.2 })
        sink.append(buffer(channels: 2, frames: 480) { _, _ in 0.2 })
        queue.sync {}
        XCTAssertEqual(session.samples, 960)
        let closed = expectation(description: "closed")
        sink.close { closed.fulfill() }
        wait(for: [closed], timeout: 2)
        XCTAssertTrue(session.closed)
        sink.append(buffer(channels: 1, frames: 100) { _, _ in 0.2 })
        queue.sync {}
        XCTAssertEqual(session.samples, 960, "nothing is added after close")
    }
}

// MARK: - The gate numbers

@MainActor
final class GateTimingTests: XCTestCase {

    func testTheGateWaitsForALongerPause() {
        XCTAssertEqual(VoiceTurnManager.longPause, 4.0)
        XCTAssertEqual(VoiceTurnManager.quickNudgeAfter, 5.0)
        XCTAssertEqual(VoiceTurnManager.nudgeAfter, 10)
        XCTAssertLessThan(VoiceTurnManager.longPause, VoiceTurnManager.quickNudgeAfter)
    }

    func testTheCapsMoveWithTheBaseAndAreNotClampedToTheOldNumbers() {
        XCTAssertEqual(VoiceTurnManager.normalCap, 5.5, accuracy: 0.0001)
        XCTAssertEqual(VoiceTurnManager.extendedCap, 6.5, accuracy: 0.0001)
        let longOpen = String(repeating: "clean the bathrooms and mop the floor ", count: 4) + "and then"
        let p = VoiceTurnManager.pauseNeeded(for: longOpen)
        XCTAssertGreaterThan(p, 4.2, "the old extended cap would have cut this short")
        XCTAssertLessThanOrEqual(p, VoiceTurnManager.extendedCap)
        XCTAssertLessThanOrEqual(VoiceTurnManager.pauseNeeded(for: String(repeating: "word ", count: 100) + ". a. b."), VoiceTurnManager.normalCap)
    }

    func testAShortFinishedRequestIsReadAfterThePause() {
        XCTAssertEqual(VoiceTurnManager.gate(utterance: "Buy milk", silence: 3.0, lastActed: ""), .keepListening)
        XCTAssertEqual(VoiceTurnManager.gate(utterance: "Buy milk", silence: VoiceTurnManager.longPause + 0.1, lastActed: ""), .evaluate("Buy milk"))
    }

    func testALoneVerbIsNudgedAfterFiveSeconds() {
        if case .hold = VoiceTurnManager.gate(utterance: "clean", silence: VoiceTurnManager.longPause + 0.5, lastActed: "") {} else { XCTFail("held at 4.5 s") }
        XCTAssertEqual(VoiceTurnManager.gate(utterance: "clean", silence: 5.1, lastActed: ""), .nudge)
    }
}

// MARK: - The transcript policy

@MainActor
final class TranscriptPolicyTests: XCTestCase {
    private let said = LongTurnAnalyzerTests.inLaws
    private let now = LongTurnAnalyzerTests.now

    override func tearDown() { TranscriptPolicy.override = nil }

    private func manager(_ engine: DecisionProviding) -> VoiceTurnManager {
        let m = VoiceTurnManager(engine: engine, sink: InMemorySaveSink(), knownCategories: { [] }, knownAssignees: { [] })
        m.ruleFallbackEnabled = false
        return m
    }

    func testItIsOffInUnitTestsSoTheEstablishedBehaviourIsUnchanged() {
        TranscriptPolicy.override = nil
        XCTAssertFalse(TranscriptPolicy.raw)
        XCTAssertEqual(SpeechCleaner.clean("Um, add a task to clean the bathroom").text, "add a task to clean the bathroom")
    }

    func testOnTheCleanerPassesTheWordsThroughUntouched() {
        TranscriptPolicy.override = true
        let r = SpeechCleaner.clean("Um, clean the... no wait, wash the car.")
        XCTAssertEqual(r.text, "Um, clean the... no wait, wash the car.")
        XCTAssertTrue(r.edits.isEmpty)
        XCTAssertTrue(r.removed.isEmpty)
        XCTAssertFalse(r.pendingRepair)
    }

    func testSentencesOfAPunctuatedTurn() {
        XCTAssertEqual(TranscriptPolicy.sentences(of: "Clean the bathrooms. Then call the caterer! Is it ready?"),
                       ["Clean the bathrooms.", "Then call the caterer!", "Is it ready?"])
        XCTAssertEqual(TranscriptPolicy.sentences(of: "Buy milk and bread."), [], "one sentence is not split")
    }

    func testOnALongTurnGoesToTheModelWholeInOnePrompt() async {
        TranscriptPolicy.override = true
        let engine = BulkQueueEngine([BulkQueueEngine.tasks(["Clean bathrooms", "Mop living room", "Buy flowers and snacks", "Call the caterer"])])
        let m = manager(engine)
        let r = await m.decide(utterance: said, now: now)
        XCTAssertEqual(engine.prompts.count, 1)
        let p = engine.prompts[0]
        XCTAssertTrue(p.contains("punctuated transcript"), p)
        XCTAssertTrue(p.contains("honestly"), "the whole turn is sent, chatter included: the model splits it")
        XCTAssertFalse(p.contains("Context: Saturday, for in-laws."), "no clause digest")
        XCTAssertFalse(p.contains("These look like"), "no BulkDetector segments")
        XCTAssertEqual(m.lastTrace.route, "raw-bulk")
        XCTAssertEqual(m.lastTrace.modelCallCount, 1)
        guard case .proposal(let proposal) = r else { return XCTFail("\(r)") }
        XCTAssertEqual(proposal.rows.count, 4)
    }

    func testOffTheSameTurnUsesTheDigest() async {
        TranscriptPolicy.override = false
        let engine = BulkQueueEngine([BulkQueueEngine.tasks(["Clean bathrooms", "Mop living room", "Buy flowers and snacks", "Call the caterer"])])
        let m = manager(engine)
        _ = await m.decide(utterance: said, now: now)
        XCTAssertTrue(engine.prompts[0].contains("Context: Saturday, for in-laws."), engine.prompts[0])
        XCTAssertNotEqual(m.lastTrace.route, "raw-bulk")
    }

    func testOnAShortRequestKeepsTheOrdinaryPath() async {
        TranscriptPolicy.override = true
        let engine = BulkQueueEngine([nil])
        let m = manager(engine)
        _ = await m.decide(utterance: "Buy milk.", now: now)
        XCTAssertNotEqual(m.lastTrace.route, "raw-bulk")
    }

    func testOnTheValidatorsStillGateWhatTheModelMadeUp() async {
        TranscriptPolicy.override = true
        var invented = BulkQueueEngine.tasks(["Clean bathrooms", "Mop living room", "Buy flowers and snacks", "Call the caterer"])
        invented.tasks[2].assignee = "Suresh"               // never said
        let m = manager(BulkQueueEngine([invented]))
        _ = await m.decide(utterance: said, now: now)
        XCTAssertNil(m.state.drafts.items.first { $0.title == "Buy flowers and snacks" }?.assignee, "an assignee nobody said is dropped")
    }
}
