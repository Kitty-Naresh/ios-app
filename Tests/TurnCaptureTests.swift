import XCTest
#if canImport(FoundationModels)
import FoundationModels
#endif
@testable import Kitty

/// The five checks that matter most for the trace and the output guard. They use SCRIPTED streams of the model's snapshots, so they
/// are fast and need no model. They show what Kitty keeps, shows and stops; how long the real model writes is read from a real trace.
private final class Counter: @unchecked Sendable { var n = 0 }

nonisolated private func item(_ title: String) -> String {
    "{\"heardAs\":\"\(title)\",\"title\":\"\(title)\"}"
}

/// One snapshot of the answer: `items` are whole, `partial` is an item still being written (it lacks its title).
nonisolated private func snapshot(_ items: [String], partial: Bool = false) -> GeneratedContent {
    var all = items
    if partial { all.append("{\"heardAs\":\"still writ") }
    let json = "{\"wait\":false,\"action\":\"create\",\"items\":[\(all.joined(separator: ","))],\"operations\":[],\"answer\":\"\",\"clarifyingQuestion\":\"\"}"
    return try! GeneratedContent(json: json)
}

@MainActor
final class CriticalTests: XCTestCase {
    override func setUp() async throws {
        TurnCapture.override = nil
        TurnCapture.shared.reset()
        Trace.recordingOverride = false
        _ = ModelTape.drain()
    }

    override func tearDown() async throws {
        Trace.recordingOverride = nil
        TurnCapture.shared.reset()
    }

    private let limits = CallLimits(maxTokens: 1_800, guardTokens: 1_500, maxItems: 40, name: "test")
    private var latest: ModelCallRecord? { TurnCapture.shared.snapshot.calls.last }

    private func call() -> ModelCallRecord {
        var record = ModelCallRecord(kind: "extract", mode: "fresh session", instructions: "THE PERSISTENT INSTRUCTIONS",
                                     prompt: "USER: \"buy milk and bread\"", schema: "BulkAgentDecision")
        var d = CallDetail()
        d.schemaJSON = "{\"title\":\"SCHEMA-JSON-MARK\"}"
        d.tools = [CallDetail.Tool(name: "search_tasks", description: "Search the tasks", parameters: "{}")]
        d.tokens = CallDetail.Tokens(instructions: 900, schema: 1800, tools: 500, prompt: 40, reply: nil, exact: true, window: 8192)
        record.detail = d
        return record
    }

    private func read(_ stream: AsyncThrowingStream<GeneratedContent, Error>) async throws -> ModelAnswer<BulkAgentDecision> {
        try await ModelTape.read(stream, as: BulkAgentDecision.self, call: call(), limits: limits, interval: 0)
    }

    /// 1. A runaway answer is stopped, and none of it is used: it is an error, and what was written stays in the trace only.
    func testAnEndlessRepeatingAnswerIsStoppedAndNothingOfItIsUsed() async throws {
        let counter = Counter()
        let endless = AsyncThrowingStream<GeneratedContent, Error> { c in
            let producer = Task {
                while !Task.isCancelled && counter.n < 400 {
                    counter.n += 1
                    c.yield(snapshot(Array(repeating: item("Buy Milk And Bread"), count: counter.n), partial: true))
                    await Task.yield()
                }
                c.finish()
            }
            c.onTermination = { _ in producer.cancel() }
        }
        do { _ = try await read(endless); XCTFail("a stopped answer must not come back as an answer") }
        catch ModelAnswerError.runaway {}
        XCTAssertLessThan(counter.n, 100, "reading stopped long before the stream would have ended")
        XCTAssertTrue(latest?.detail?.outcome.hasPrefix("stopped by the output guard") == true, latest?.detail?.outcome ?? "")
        XCTAssertTrue(latest?.detail?.partialReply.contains("Buy Milk And Bread") == true, "the trace keeps all that was written")
        XCTAssertNotNil(latest?.error)
    }

    /// 2. What was written before a cancel (the user, a newer turn or the clock) is not lost.
    func testThePartialReplyIsKeptWhenTheCallIsCancelled() async {
        let stream = AsyncThrowingStream<GeneratedContent, Error> { c in
            c.yield(snapshot([item("Buy Milk")], partial: true))
            c.finish(throwing: CancellationError())
        }
        do { _ = try await read(stream); XCTFail("expected a throw") } catch {}
        TurnCapture.shared.setOutcomeOfLatest("stopped by the clock: the model had written nothing after 45 s, so it was stopped")
        XCTAssertTrue(latest?.detail?.partialReply.contains("Buy Milk") == true)
        XCTAssertTrue(latest?.detail?.partialReply.contains("still writ") == true)
        XCTAssertTrue(latest?.detail?.outcome.contains("stopped by the clock") == true)
        XCTAssertNotNil(latest?.error)
    }

    /// 3. The shared text holds what was sent and how it went, and can be built mid-call.
    func testTheSharedTextHoldsEverythingThatWasSent() throws {
        var record = call()
        record.detail?.writing = [.init(at: 0.5, characters: 120, tokens: 35, items: 1)]
        record.detail?.partialReply = "{\"partial\":\"PARTIAL-MARK\""
        record.detail?.outcome = "in progress"
        TurnCapture.shared.begin()
        TurnCapture.shared.upsert(record)
        let text = TurnTraceFormat.text()
        for expected in ["KITTY TRACE", "=== MODEL CALL 1 of 1 ===", "THE PERSISTENT INSTRUCTIONS", "SCHEMA-JSON-MARK",
                         "search_tasks: Search the tasks", "buy milk and bread", "schema 1,800", "sent in total 3,240",
                         "+0.5 s | 120 chars", "--- PARTIAL REPLY", "PARTIAL-MARK", "--- OUTCOME ---", "in progress"] {
            XCTAssertTrue(text.contains(expected), "the shared trace is missing: \(expected)")
        }
    }

    /// 4. The capture is on without "Save task details", is never saved, and is cleared when the next turn starts.
    func testTheCaptureIsAlwaysOnNeverSavedAndClearedAtTheNextTurn() async throws {
        let stream = AsyncThrowingStream<GeneratedContent, Error> { c in c.yield(snapshot([item("Buy Milk")])); c.finish() }
        _ = try await read(stream)
        XCTAssertEqual(TurnCapture.shared.callCount, 1, "captured although Save task details is off")
        XCTAssertTrue(ModelTape.drain().isEmpty, "nothing reaches the saved record unless that switch is on")
        Trace.begin()
        XCTAssertEqual(TurnCapture.shared.callCount, 0, "the next turn starts with an empty capture")
    }

    /// 5. A normal answer, two different items, is not touched by the guard.
    func testAGoodAnswerIsNotTouchedByTheGuard() async throws {
        let ok = AsyncThrowingStream<GeneratedContent, Error> { c in
            c.yield(snapshot([item("Buy Milk")], partial: true))
            c.yield(snapshot([item("Buy Milk"), item("Buy Bread")]))
            c.finish()
        }
        let answer = try await read(ok)
        XCTAssertEqual(answer.content.items.map(\.title), ["Buy Milk", "Buy Bread"])
        XCTAssertEqual(latest?.detail?.outcome, "finished")
    }
}
