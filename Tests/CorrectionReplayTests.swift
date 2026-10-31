import XCTest
#if canImport(FoundationModels)
import FoundationModels
#endif
@testable import Kitty

// A replay of the supplied Cipcal correction sequence on the real on-device model. It is skipped unless
//   TEST_RUNNER_KITTY_REAL_MODEL=1
// is set. Like ExtractionExperimentTests it MEASURES: the checks below are made by the test, the app applies none of them.
//   TEST_RUNNER_KITTY_REAL_RUNS=10                    runs per profile and mode (default 10)
//   TEST_RUNNER_KITTY_REPLAY_PROFILES=current,...     which profiles (default: all that exist)
//   TEST_RUNNER_KITTY_REPLAY_MODES=pinned,free        which modes (default both)
//   TEST_RUNNER_KITTY_REPLAY_OUT=/tmp/x.md            where the report is written
//
// Two modes, both driving the real VoiceTurnManager.decide with the real DecisionEngine and an in-memory SaveSink:
//   free   R1..R6 in order from an empty draft; the end state is compared with the three expected tasks.
//   pinned the draft the trace had at turn 7 (d6 "Get Cetaphil body lotion", d7 "Get sip curl") is seeded; R5, then R6 if needed.
// The replay is text: it measures the model and the Swift path, not the speech recogniser. The recogniser's misreadings are
// already in the text.

#if canImport(FoundationModels)

// MARK: - The sequence

enum CipcalReplay {
    /// What the user said, one chunk per turn, in the words of the trace.
    static let chunks: [String] = [
        "Pharmacy list - cetaphil body lotion - cipcal - tedibar soap",
        "Okay, so the first one, get pharmacy list. Is not needed. Deleted. Now, get body lotion, get Cetaphil, those are now two different things. That is one thing. Get Cetaphil Body Lotion.",
        "The first one, get pharmacy list, Cetaphil body lotion, Cipca and Teddy Bar soap. Let's say single task. I don't want, delete it.",
        "I said, I need those individual tasks. You have one single combined task. Get pharmacy list, Cetaphil, Body lotion, SitCal, Teddy Bar soap. That single task, I don't want. Delete those. and create individual tasks. Get Cetaphil body lotion, Get sip curl, Get teddy bar soup.",
        "SIPCAL, you heard that correct earlier.",
        "It's Cipcal, C-I-P-C-A-L, Get Cipcal, not Ciccal.",
    ]

    /// What the app hears of a turn: everything said so far, as the recogniser keeps it. The app finds the new words itself.
    static func cumulative(upTo n: Int) -> String { chunks.prefix(n).joined(separator: " ") }

    /// Words that must never come back once the user corrected them.
    static let misreadings = ["sip curl", "sipcal", "sit cal", "ciccal", "cipca ", "teddy bar", "teddybar"]
    static let products = ["cetaphil", "cipcal", "tedibar"]
}

// MARK: - What was seen after a turn

struct ItemPrint: Equatable {
    var title: String
    var category: String
    var due: Date?
    var time: Int?
    var priority: String
    var assignee: String
    var notes: String
    var routine: Bool
    var slot: String
    var unreadableRepeat: Bool

    init(_ i: DraftItem) {
        title = i.title; category = i.categoryName ?? ""; due = i.due; time = i.timeMinutes
        priority = i.priority ?? ""; assignee = i.assignee ?? ""; notes = i.notes ?? ""
        routine = i.kind == .routine || i.recurrence != nil; slot = i.slot?.rawValue ?? ""; unreadableRepeat = !i.unparsed.isEmpty
    }

    /// Metadata nobody said anywhere in this sequence: a day, a time, a person, a priority, a schedule, notes, a category.
    var hasInventedMetadata: Bool {
        due != nil || time != nil || !priority.isEmpty || !assignee.isEmpty || !notes.isEmpty || routine || !slot.isEmpty || unreadableRepeat
    }
}

struct TurnSeen {
    var kind: String            // wait, reply, proposal, question
    var text: String            // the reply, the question, or the preview's prompt
    var savePrompt: Bool        // the card asks "Should I save these?" or similar
    var items: [(id: UUID, ref: String, print: ItemPrint)]
    var version: Int
    var seconds: Double
    var calls: Int
    var tokens: Int
    var callOutcome: String     // finished, guard stop, cancelled, failed, none
    var prompt = ""             // what the model was sent in this turn (the last call)
    var raw = ""                // what the model wrote in its last call, as the app recorded it
    var recovered = false       // the card says the words were not applied and nothing changed
}

struct ReplayRun {
    var turns: [TurnSeen] = []
    var passedAtTurn: Int?      // 1-based number of correction turns needed, nil = never
    var notes: [String] = []
}

// MARK: - The checks (measurements only)

enum ReplayChecks {
    /// The state after a correction is right when exactly one item is Cipcal, no old misreading is back, no other item changed,
    /// and nothing was invented.
    static func cipcalFixed(before: [(id: UUID, ref: String, print: ItemPrint)], after: [(id: UUID, ref: String, print: ItemPrint)], said: String) -> (ok: Bool, why: [String]) {
        var why: [String] = []
        let titles = after.map { $0.print.title.lowercased() }
        let cip = titles.filter { $0.contains("cipcal") }
        if cip.count != 1 { why.append("\(cip.count) Cipcal item(s)") }
        for bad in ReplayChecks.misreadingsFound(in: titles.joined(separator: " | ")) { why.append("old misreading back: \(bad)") }
        // Items that were not about Cipcal must be exactly as they were.
        for b in before where !b.print.title.lowercased().contains("sip") && !b.print.title.lowercased().contains("cipcal") {
            guard let a = after.first(where: { $0.id == b.id }) else { why.append("unrelated item gone: \(b.print.title)"); continue }
            if a.print != b.print { why.append("unrelated item changed: \(b.print.title) -> \(a.print.title)") }
        }
        for item in after where item.print.hasInventedMetadata { why.append("invented metadata on \(item.print.title)") }
        return (why.isEmpty, why)
    }

    static func misreadingsFound(in text: String) -> [String] { CipcalReplay.misreadings.filter { text.lowercased().contains($0) } }

    /// The end state of the free replay: the three individual tasks, no combined one, nothing invented.
    static func freeEndOK(_ items: [(id: UUID, ref: String, print: ItemPrint)]) -> (ok: Bool, why: [String]) {
        var why: [String] = []
        if items.count != 3 { why.append("\(items.count) items instead of 3") }
        for p in CipcalReplay.products where !items.contains(where: { $0.print.title.lowercased().contains(p) }) { why.append("no task for \(p)") }
        for item in items {
            let t = item.print.title.lowercased()
            if CipcalReplay.products.filter({ t.contains($0) }).count > 1 { why.append("combined task: \(item.print.title)") }
            if t.contains("pharmacy list") { why.append("the list's name is still a task: \(item.print.title)") }
            if item.print.hasInventedMetadata { why.append("invented metadata on \(item.print.title)") }
        }
        let all = items.map { $0.print.title }.joined(separator: " | ")
        for bad in misreadingsFound(in: all) { why.append("misreading kept: \(bad)") }
        return (why.isEmpty, why)
    }
}

// MARK: - The test

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
@MainActor
final class CorrectionReplayTests: XCTestCase {
    struct Profile {
        var name: String
        var what: String
        var make: () -> VoiceTurnManager
    }

    static let now = ExperimentSetup.now

    private static func manager() -> VoiceTurnManager {
        VoiceTurnManager(engine: DecisionEngine(), sink: InMemorySaveSink(),
                         knownCategories: { ExperimentSetup.categories },
                         knownAssignees: { ExperimentSetup.people },
                         savedTasks: { [] })
    }

    private func profiles() -> [Profile] {
        var all = [Profile(name: "full-fixed", what: "the production path after the schema, context and invalid-output fixes", make: { Self.manager() })]
        all.append(contentsOf: extraProfiles())
        return all
    }

    // MARK: Running one turn

    private func describe(_ r: TurnResult) -> (kind: String, text: String, savePrompt: Bool, recovered: Bool) {
        switch r {
        case .wait: return ("wait", "", false, false)
        case .handled: return ("handled", "", false, false)
        case .question(let q): return ("question", q, false, false)
        case .reply(let a): return ("reply", a.message, false, false)
        case .proposal(let p):
            let text = [p.reply, p.prompt].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " | ")
            // "Should I save these?" beside a draft that did not take the words reads as if it worked; a recovery card does not.
            return ("proposal", text, p.recovery == nil && (p.prompt ?? "").lowercased().contains("save"), p.recovery != nil)
        }
    }

    private func turn(_ turns: VoiceTurnManager, said: String) async -> TurnSeen {
        let before = Date()
        let result = await turns.decide(utterance: said, now: Self.now, final: true)
        let seconds = Date().timeIntervalSince(before)
        let calls = TurnCapture.shared.snapshot.calls
        let tokens = calls.map { Trace.estimatedTokens(($0.detail?.partialReply ?? "").count) }.reduce(0, +)
        let outcome: String = {
            guard let last = calls.last else { return "none" }
            let o = last.detail?.outcome ?? "no record"
            if o.hasPrefix("finished") { return "finished" }
            if o.hasPrefix("stopped by the output guard") { return "guard stop" }
            if o.hasPrefix("cancelled") { return "cancelled" }
            return "failed"
        }()
        let d = describe(result)
        let items = turns.state.drafts.ordered.map { (id: $0.id, ref: $0.ref, print: ItemPrint($0)) }
        return TurnSeen(kind: d.kind, text: d.text, savePrompt: d.savePrompt, items: items, version: turns.state.drafts.version,
                        seconds: seconds, calls: calls.count, tokens: tokens, callOutcome: outcome,
                        prompt: turns.lastTrace.prompt ?? "", raw: calls.last?.detail?.partialReply ?? "", recovered: d.recovered)
    }

    // MARK: Seeding the draft the trace had at turn 7

    /// The trace's draft: d6 "Get Cetaphil body lotion" and d7 "Get sip curl". d1 to d5 were used and gone, so refs start at d6.
    private func seedTurnSeven(_ turns: VoiceTurnManager) {
        let drafts = turns.state.drafts
        var burned: [DraftItem] = []
        for n in 1...5 { var i = DraftItem(title: "burn \(n)"); i.heardAs = "burn"; burned.append(i) }
        drafts.setItems(burned)
        for b in drafts.items { drafts.remove(id: b.id) }
        var a = DraftItem(title: "Get Cetaphil body lotion")
        a.history = [DraftItem.Provenance(line: 4, kind: "created", words: "Get Cetaphil body lotion")]
        var b = DraftItem(title: "Get sip curl")
        b.history = [DraftItem.Provenance(line: 4, kind: "created", words: "Get sip curl")]
        // A probe for position bias: with KITTY_REPLAY_SWAP=1 the misread item is listed first (and is d6).
        if ProcessInfo.processInfo.environment["KITTY_REPLAY_SWAP"] == "1" { drafts.append(b); drafts.append(a) } else { drafts.append(a); drafts.append(b) }
        let said = CipcalReplay.cumulative(upTo: 4)
        drafts.noteSpoken(said)
        turns.log.record(words: CipcalReplay.chunks[3], action: "change",
                         change: "Added get cetaphil body lotion and get sip curl. Removed get a pharmacy list: cetaphil body lotion, cipcal, tedibar soap.",
                         touched: ["d1", "d6", "d7"])
        let p = DraftProposals.bulk(drafts.items, spoken: drafts.spokenText, version: drafts.version, sink: InMemorySaveSink())
        turns.state.record(.proposal(p))
        turns.state.markProcessed(said)
    }

    // MARK: The two modes

    private func pinnedRun(_ profile: Profile) async -> ReplayRun {
        let turns = profile.make()
        seedTurnSeven(turns)
        var run = ReplayRun()
        var cumulativeCount = 4
        for correction in 0..<2 {
            cumulativeCount = 5 + correction
            let before = turns.state.drafts.ordered.map { (id: $0.id, ref: $0.ref, print: ItemPrint($0)) }
            let seen = await turn(turns, said: CipcalReplay.cumulative(upTo: cumulativeCount))
            run.turns.append(seen)
            let verdict = ReplayChecks.cipcalFixed(before: before, after: seen.items, said: CipcalReplay.cumulative(upTo: cumulativeCount))
            run.notes.append(verdict.ok ? "fixed" : verdict.why.joined(separator: "; "))
            if verdict.ok { run.passedAtTurn = correction + 1; break }
        }
        return run
    }

    private func freeRun(_ profile: Profile) async -> ReplayRun {
        let turns = profile.make()
        var run = ReplayRun()
        for n in 1...CipcalReplay.chunks.count {
            let seen = await turn(turns, said: CipcalReplay.cumulative(upTo: n))
            run.turns.append(seen)
            let verdict = ReplayChecks.freeEndOK(seen.items)
            run.notes.append(verdict.ok ? "state ok" : verdict.why.joined(separator: "; "))
            if verdict.ok, run.passedAtTurn == nil, n > 1 { run.passedAtTurn = n }
        }
        // Only the end state counts as a pass; passedAtTurn says when it was first reached.
        if !ReplayChecks.freeEndOK(run.turns.last?.items ?? []).ok { run.passedAtTurn = nil }
        return run
    }

    // MARK: Counting

    private struct Tally {
        var runs: [ReplayRun] = []
        var seconds: [Double] { runs.flatMap { $0.turns.map(\.seconds) } }
        func percentile(_ p: Double) -> Double {
            let s = seconds.sorted()
            guard !s.isEmpty else { return 0 }
            return s[min(s.count - 1, Int(Double(s.count - 1) * p + 0.5))]
        }
        var turnsSeen: [TurnSeen] { runs.flatMap(\.turns) }
        var passed: Int { runs.filter { $0.passedAtTurn != nil }.count }
        var needed1: Int { runs.filter { $0.passedAtTurn == 1 }.count }
        var avgTurnsToPass: Double {
            let p = runs.compactMap(\.passedAtTurn)
            return p.isEmpty ? 0 : Double(p.reduce(0, +)) / Double(p.count)
        }
        var unchangedWithSavePrompt: Int { turnsSeen.filter { $0.savePrompt && $0.kind == "proposal" }.count }
        var noAnswer: Int { turnsSeen.filter { $0.callOutcome != "finished" && $0.callOutcome != "none" }.count }
        var recoveries: Int { turnsSeen.filter(\.recovered).count }
        var guardStops: Int { turnsSeen.filter { $0.callOutcome == "guard stop" }.count }
        var inventedMetadata: Int { turnsSeen.filter { t in t.items.contains { $0.print.hasInventedMetadata } }.count }
        var tokens: Int { turnsSeen.isEmpty ? 0 : turnsSeen.map(\.tokens).reduce(0, +) / turnsSeen.count }
    }

    func testTheCipcalReplayOnTheRealModel() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["KITTY_REAL_MODEL"] == "1", "real-model replay: set TEST_RUNNER_KITTY_REAL_MODEL=1")
        guard case .available = SystemLanguageModel.default.availability else { throw XCTSkip("the on-device model is not available") }
        let runs = max(1, Int(env["KITTY_REAL_RUNS"] ?? "") ?? 10)
        let wantedProfiles = env["KITTY_REPLAY_PROFILES"].map { Set($0.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }) }
        let wantedModes = env["KITTY_REPLAY_MODES"].map { Set($0.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }) }
        let out = env["KITTY_REPLAY_OUT"] ?? NSTemporaryDirectory() + "correction_replay.md"

        var report = "# Cipcal correction replay on the real model\n\n"
        report += "\(runs) runs per profile and mode, the real VoiceTurnManager and DecisionEngine, fresh session per call, no saved tasks. Text replay: speech recognition is not part of it.\n"
        report += "Checks are measurements made by the test, not rules of the app.\n\n"
        report += "| profile | mode | runs passed | passed on 1st correction | avg corrections to pass | median s per turn | p90 s | max s | avg tokens written | turns with no finished answer | guard stops | turns with invented metadata | unchanged-looking save prompts | turns rejected, draft kept |\n"
        report += "|---|---|---|---|---|---|---|---|---|---|---|---|---|---|\n"
        var samples = ""
        for profile in profiles() where wantedProfiles?.contains(profile.name) ?? true {
            for mode in ["pinned", "free"] where wantedModes?.contains(mode) ?? true {
                var tally = Tally()
                for _ in 0..<runs { tally.runs.append(mode == "pinned" ? await pinnedRun(profile) : await freeRun(profile)) }
                report += "| \(profile.name) | \(mode) | \(tally.passed)/\(runs) | \(tally.needed1)/\(runs) | "
                report += String(format: "%.1f | %.1f | %.1f | %.1f | %d | ", tally.avgTurnsToPass, tally.percentile(0.5), tally.percentile(0.9), tally.seconds.max() ?? 0, tally.tokens)
                report += "\(tally.noAnswer) | \(tally.guardStops) | \(tally.inventedMetadata) | \(tally.unchangedWithSavePrompt) | \(tally.recoveries) |\n"
                samples += "### \(profile.name), \(mode): \(profile.what)\n"
                for (n, r) in tally.runs.enumerated() {
                    samples += "- run \(n + 1): " + (r.passedAtTurn.map { "PASS at \($0)" } ?? "FAIL") + "\n"
                    for (t, seen) in r.turns.enumerated() {
                        let titles = seen.items.map { "\($0.ref) \($0.print.title)" }.joined(separator: " | ")
                        samples += "  - turn \(t + 1): \(seen.kind), \(String(format: "%.1f", seen.seconds)) s, \(seen.callOutcome), ~\(seen.tokens) tok; items: \(titles.isEmpty ? "none" : titles)\n"
                        if !seen.text.isEmpty { samples += "    said: \(seen.text.prefix(220))\n" }
                        if n == 0, t < 2, !seen.prompt.isEmpty { samples += "    prompt sent:\n```\n\(seen.prompt)\n```\n" }
                        if !seen.raw.isEmpty { samples += "    model wrote: \(seen.raw.replacingOccurrences(of: "\n", with: " ").prefix(420))\n" }
                        if t < r.notes.count { samples += "    check: \(r.notes[t])\n" }
                    }
                }
                samples += "\n"
                try? (report + "\n## Samples (so far)\n\n" + samples).write(toFile: out, atomically: true, encoding: .utf8)
            }
        }
        report += "\n## Samples\n\n" + samples
        try report.write(toFile: out, atomically: true, encoding: .utf8)
        print("REPLAY REPORT WRITTEN TO \(out)")
        print(report)
    }

    /// Profiles added by later steps (the minimal path).
    private func extraProfiles() -> [Profile] {
        func minimal(_ vocabulary: Bool) -> VoiceTurnManager {
            let m = VoiceTurnManager(engine: MinimalEngine(), sink: InMemorySaveSink(),
                                     knownCategories: { ExperimentSetup.categories }, knownAssignees: { ExperimentSetup.people }, savedTasks: { [] })
            m.profile = .minimal(vocabulary: vocabulary)
            return m
        }
        func flat() -> VoiceTurnManager {
            let m = VoiceTurnManager(engine: FlatExtractionEngine(), sink: InMemorySaveSink(),
                                     knownCategories: { ExperimentSetup.categories }, knownAssignees: { ExperimentSetup.people }, savedTasks: { [] })
            m.profile = .flat
            return m
        }
        return [Profile(name: "flat", what: "flat extraction: the brief's schema, Swift owns dates, repeats and lists; edits use the review call", make: { flat() }),
                Profile(name: "minimal-M0", what: "the minimal path: titles, rename/remove/add by ref, no vocabulary", make: { minimal(false) }),
                Profile(name: "minimal-M1", what: "the minimal path with only the vocabulary the words mention", make: { minimal(true) })]
    }
}

#endif
