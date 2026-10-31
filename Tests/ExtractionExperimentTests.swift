import XCTest
#if canImport(FoundationModels)
import FoundationModels
#endif
@testable import Kitty

// A controlled experiment on the real on-device model, not a pass/fail test. It is skipped unless
//   TEST_RUNNER_KITTY_REAL_MODEL=1
// is set, so the normal suite never runs it. Each cell adds ONE thing to the one before it, every run is a fresh session under
// the app's real output guard (`CallLimits.extract`, nothing raised), and what happened is counted, not judged:
//   TEST_RUNNER_KITTY_REAL_RUNS=5          runs per cell and input (default 5)
//   TEST_RUNNER_KITTY_EXPERIMENT_CELLS=C0a,C1   only these cells (default all)
//   TEST_RUNNER_KITTY_EXPERIMENT_OUT=/tmp/x.md  where the table is written
// The checks in this file (leaks, one task, products in the title) only MEASURE the output. The app has no such rule.

#if canImport(FoundationModels)

// MARK: - The schemas of the cells (small to large)

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
@Generable
struct XItem0 {
    @Guide(description: "The user's words this task comes from, copied exactly as said.")
    var heardAs: String
    @Guide(description: "Verb first, Title Case: the action and its object.")
    var title: String
}

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
@Generable
struct XOut0 {
    @Guide(description: "create when the user asks for tasks, clarify when one detail is missing, unrelated otherwise.", .anyOf(["create", "clarify", "unrelated"]))
    var action: String
    @Guide(description: "create: each thing the user asked for, once.")
    var items: [XItem0]
}

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
@Generable
struct XItem1 {
    @Guide(description: "The user's words this task comes from, copied exactly as said.")
    var heardAs: String
    @Guide(description: "Verb first, Title Case: the action and its object.")
    var title: String
    @Guide(description: "Only if the user said why, in their own words. Otherwise omit.")
    var reason: String?
    @Guide(description: "One broad category in Title Case. Omit if unsure.")
    var category: String?
    @Guide(description: "ISO date YYYY-MM-DD, only if the user said a day. Otherwise omit.")
    var dueDate: String?
    @Guide(description: "Clock time HH:mm in 24 hours, only if the user said a clock time. Otherwise omit.")
    var time: String?
    @Guide(description: "morning, afternoon, evening, night or anytime, only if the user said when in the day. Otherwise omit.")
    var timeOfDay: String?
    @Guide(description: "low, medium or high, only if the user said it. Otherwise omit.")
    var priority: String?
    @Guide(description: "A person's name, only if the user said the work is for them. Otherwise omit.")
    var assignee: String?
    @Guide(description: "Only if the user gave notes. Otherwise omit.")
    var notes: String?
}

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
@Generable
struct XOut1 {
    @Guide(description: "create when the user asks for tasks, clarify when one detail is missing, unrelated otherwise.", .anyOf(["create", "clarify", "unrelated"]))
    var action: String
    @Guide(description: "create: each thing the user asked for, once.")
    var items: [XItem1]
}

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
@Generable
struct XItem2 {
    @Guide(description: "The user's words this task comes from, copied exactly as said.")
    var heardAs: String
    @Guide(description: "Verb first, Title Case: the action and its object.")
    var title: String
    @Guide(description: "Only if the user said why, in their own words. Otherwise omit.")
    var reason: String?
    @Guide(description: "One broad category in Title Case. Omit if unsure.")
    var category: String?
    @Guide(description: "ISO date YYYY-MM-DD, only if the user said a day. Otherwise omit.")
    var dueDate: String?
    @Guide(description: "Clock time HH:mm in 24 hours, only if the user said a clock time. Otherwise omit.")
    var time: String?
    @Guide(description: "morning, afternoon, evening, night or anytime, only if the user said when in the day. Otherwise omit.")
    var timeOfDay: String?
    @Guide(description: "low, medium or high, only if the user said it. Otherwise omit.")
    var priority: String?
    @Guide(description: "A person's name, only if the user said the work is for them. Otherwise omit.")
    var assignee: String?
    @Guide(description: "Only if the user gave notes. Otherwise omit.")
    var notes: String?
    @Guide(description: "The project, app, client or trip, only if the user said one. Otherwise omit.")
    var project: String?
    @Guide(description: "Names the user said (brand, vendor, topic, place, event), one or two nouns each. Omit if none.")
    var labels: [String]?
}

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
@Generable
struct XOut2 {
    @Guide(description: "create when the user asks for tasks, clarify when one detail is missing, unrelated otherwise.", .anyOf(["create", "clarify", "unrelated"]))
    var action: String
    @Guide(description: "create: each thing the user asked for, once.")
    var items: [XItem2]
}

/// The recurrence object as it is today (frozen copy): six required fields, "once" allowed, frequency free text.
@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
@Generable
struct XRepeatOld {
    @Guide(description: "once (not repeating), daily, weekly, monthly or custom")
    var frequency: String
    @Guide(description: "Weekly: the days as numbers, 1 = Sunday to 7 = Saturday. Empty otherwise.")
    var weekdays: [Int]
    @Guide(description: "2 for every other week, 3 for every third week. 0 if not said.")
    var everyNWeeks: Int
    @Guide(description: "Custom: days between repeats, 2 for every other day. 0 if not said.")
    var intervalDays: Int
    @Guide(description: "Monthly: the day of the month, 1 to 31. 0 if not said.")
    var dayOfMonth: Int
    @Guide(description: "The repeat exactly as the user said it.")
    var words: String
}

/// The simplified recurrence object: no "once", frequency from a fixed list, everything but the frequency optional.
@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
@Generable
struct XRepeatNew {
    @Guide(description: "How often it repeats.", .anyOf(["daily", "weekly", "monthly", "custom"]))
    var frequency: String
    @Guide(description: "Weekly: the days as numbers, 1 = Sunday to 7 = Saturday. Omit unless the user named days.")
    var weekdays: [Int]?
    @Guide(description: "2 for every other week, 3 for every third week. Omit unless said.")
    var everyNWeeks: Int?
    @Guide(description: "Custom: days between repeats. Omit unless said.")
    var intervalDays: Int?
    @Guide(description: "Monthly: the day of the month, 1 to 31. Omit unless said.")
    var dayOfMonth: Int?
    @Guide(description: "The repeat exactly as the user said it.")
    var words: String?
}

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
@Generable
struct XItem3Old {
    @Guide(description: "The user's words this task comes from, copied exactly as said.")
    var heardAs: String
    @Guide(description: "Verb first, Title Case: the action and its object.")
    var title: String
    @Guide(description: "Only if the user said why, in their own words. Otherwise omit.")
    var reason: String?
    @Guide(description: "One broad category in Title Case. Omit if unsure.")
    var category: String?
    @Guide(description: "ISO date YYYY-MM-DD, only if the user said a day. Otherwise omit.")
    var dueDate: String?
    @Guide(description: "Clock time HH:mm in 24 hours, only if the user said a clock time. Otherwise omit.")
    var time: String?
    @Guide(description: "morning, afternoon, evening, night or anytime, only if the user said when in the day. Otherwise omit.")
    var timeOfDay: String?
    @Guide(description: "low, medium or high, only if the user said it. Otherwise omit.")
    var priority: String?
    @Guide(description: "A person's name, only if the user said the work is for them. Otherwise omit.")
    var assignee: String?
    @Guide(description: "Only if the user gave notes. Otherwise omit.")
    var notes: String?
    @Guide(description: "The project, app, client or trip, only if the user said one. Otherwise omit.")
    var project: String?
    @Guide(description: "Names the user said (brand, vendor, topic, place, event), one or two nouns each. Omit if none.")
    var labels: [String]?
    @Guide(description: "Only if the user said this item repeats. Otherwise omit.")
    var repeating: XRepeatOld?
}

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
@Generable
struct XOut3Old {
    @Guide(description: "create when the user asks for tasks, clarify when one detail is missing, unrelated otherwise.", .anyOf(["create", "clarify", "unrelated"]))
    var action: String
    @Guide(description: "create: each thing the user asked for, once.")
    var items: [XItem3Old]
}

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
@Generable
struct XItem3 {
    @Guide(description: "The user's words this task comes from, copied exactly as said.")
    var heardAs: String
    @Guide(description: "Verb first, Title Case: the action and its object.")
    var title: String
    @Guide(description: "Only if the user said why, in their own words. Otherwise omit.")
    var reason: String?
    @Guide(description: "One broad category in Title Case. Omit if unsure.")
    var category: String?
    @Guide(description: "ISO date YYYY-MM-DD, only if the user said a day. Otherwise omit.")
    var dueDate: String?
    @Guide(description: "Clock time HH:mm in 24 hours, only if the user said a clock time. Otherwise omit.")
    var time: String?
    @Guide(description: "morning, afternoon, evening, night or anytime, only if the user said when in the day. Otherwise omit.")
    var timeOfDay: String?
    @Guide(description: "low, medium or high, only if the user said it. Otherwise omit.")
    var priority: String?
    @Guide(description: "A person's name, only if the user said the work is for them. Otherwise omit.")
    var assignee: String?
    @Guide(description: "Only if the user gave notes. Otherwise omit.")
    var notes: String?
    @Guide(description: "The project, app, client or trip, only if the user said one. Otherwise omit.")
    var project: String?
    @Guide(description: "Names the user said (brand, vendor, topic, place, event), one or two nouns each. Omit if none.")
    var labels: [String]?
    @Guide(description: "Only for a task the user said repeats. Omit for a one-time task.")
    var repeating: XRepeatNew?
}

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
@Generable
struct XOut3 {
    @Guide(description: "create when the user asks for tasks, clarify when one detail is missing, unrelated otherwise.", .anyOf(["create", "clarify", "unrelated"]))
    var action: String
    @Guide(description: "create: each thing the user asked for, once.")
    var items: [XItem3]
}

// MARK: - One run, and what was counted

struct ExperimentRun {
    var outcome: String             // finished, stopped by the output guard, cancelled or failed
    var seconds: Double
    var tokens: Int                 // estimated from what was written
    var titles: [String]
    var labelsPerItem: [[String]]
    var repeatingItems: Int
    var rawJSON: String
    var error: String
    var repeatingNote: String       // the first repeating object written: frequency and words
}

struct ExperimentSetup {
    /// The reference lists of the trace (what the household had saved and the recogniser brand list).
    static let categories = ["Housing", "Groceries", "Unrelated", "Health", "Transportation", "Living Room", "Clothing", "Cooking", "Events", "Kitchen", "Plants", "Househelp"]
    static let labels = ["Household", "Roger Kitty", "Bucke Cab", "Accommodation", "IKEA", "baby winter wear", "loungewear", "Adho hostel", "Bokeh Camp", "Party",
                         "Friends", "Pharmacy list", "cetaphil", "body lotion", "cipcal", "tedibar soap"]
    static let people = ["Househelp", "Me", "Roger Kitty", "Bhai", "Dhanya", "Friends", "Household", "Kanna Kanna", "Plumber", "Priya", "Revathi", "San Shugy"]
    static let inputs: [(name: String, text: String)] = [
        ("dictated", "Pharmacy list - cetaphil body lotion - cipcal - tedibar soap"),
        ("colon", "Pharmacy list: cetaphil body lotion, cipcal, tedibar soap"),
    ]
    static let products = ["cetaphil", "cipcal", "tedibar"]
    static let now: Date = {
        var c = DateComponents(); c.year = 2026; c.month = 10; c.day = 27; c.hour = 9
        return Calendar.current.date(from: c) ?? Date()
    }()
    static let shortInstructions = "You are a household to-do assistant. Turn what the user said into tasks."

    enum Vocabulary { case none, selective, full }

    static func prompt(_ text: String, _ vocabulary: Vocabulary) -> String {
        switch vocabulary {
        case .none:
            return PromptBuilder.build(utterance: text, knownCategories: [], now: now, includeVocabulary: false)
        case .selective:
            return PromptBuilder.build(utterance: text, knownCategories: categories, knownPeople: people, now: now, onlyMentioned: true)
        case .full:
            return PromptBuilder.build(utterance: text, knownCategories: categories, knownPeople: people, now: now)
        }
    }
}

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
@MainActor
final class ExtractionExperimentTests: XCTestCase {
    struct Cell {
        var name: String
        var what: String
        var vocabulary: ExperimentSetup.Vocabulary
        var instructions: String
        var run: (String, String) async -> ExperimentRun
    }

    private static func parse(_ json: String) -> (titles: [String], labels: [[String]], repeating: Int, note: String) {
        guard let data = json.data(using: .utf8), let top = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let items = top["items"] as? [[String: Any]] else { return ([], [], 0, "") }
        let first = items.compactMap { $0["repeating"] as? [String: Any] }.first
        let note = first.map { r in "\(r["frequency"] as? String ?? "?"): \(r["words"] as? String ?? "")" } ?? ""
        return (items.map { $0["title"] as? String ?? "" }, items.map { $0["labels"] as? [String] ?? [] },
                items.filter { $0["repeating"] != nil }.count, note)
    }

    /// One fresh session under the app's real output guard. Nothing is applied: only what was written is read back.
    private func once<T: Generable>(_ type: T.Type, instructions: String, prompt: String) async -> ExperimentRun {
        Trace.begin()
        let session = LanguageModelSession(instructions: instructions)
        let work = Task { @MainActor () -> Bool in
            do { _ = try await ModelTape.respond(session, kind: "experiment", prompt: prompt, generating: type, limits: .extract); return true }
            catch { return false }
        }
        let timer = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000_000)
            if !Task.isCancelled { work.cancel() }
        }
        _ = await work.value
        timer.cancel()
        let call = TurnCapture.shared.snapshot.calls.last
        let detail = call?.detail
        let json = detail?.partialReply ?? ""
        let parsed = Self.parse(json)
        let outcome = detail?.outcome ?? "no record"
        let short = outcome.hasPrefix("finished") ? "finished" : (outcome.hasPrefix("stopped by the output guard") ? "stopped by the output guard"
                    : (outcome.hasPrefix("cancelled") ? "cancelled" : "failed"))
        return ExperimentRun(outcome: short, seconds: call?.seconds ?? 0, tokens: Trace.estimatedTokens(json.count), titles: parsed.titles,
                             labelsPerItem: parsed.labels, repeatingItems: parsed.repeating, rawJSON: json,
                             error: call?.error ?? "", repeatingNote: parsed.note)
    }

    private func cells() -> [Cell] {
        let prod = PersistentInstructions.text
        let short = ExperimentSetup.shortInstructions
        return [
            Cell(name: "C0a", what: "short instructions, no vocabulary, tiny schema (heardAs, title)", vocabulary: .none, instructions: short,
                 run: { i, p in await self.once(XOut0.self, instructions: i, prompt: p) }),
            Cell(name: "C0b", what: "production instructions, tiny schema", vocabulary: .none, instructions: prod,
                 run: { i, p in await self.once(XOut0.self, instructions: i, prompt: p) }),
            Cell(name: "C1", what: "+ optional metadata (no labels, no repeating)", vocabulary: .none, instructions: prod,
                 run: { i, p in await self.once(XOut1.self, instructions: i, prompt: p) }),
            Cell(name: "C2", what: "+ labels and project (optional)", vocabulary: .none, instructions: prod,
                 run: { i, p in await self.once(XOut2.self, instructions: i, prompt: p) }),
            Cell(name: "C3old", what: "+ repeating as it is today (frequency free text, once allowed, six required fields)", vocabulary: .none, instructions: prod,
                 run: { i, p in await self.once(XOut3Old.self, instructions: i, prompt: p) }),
            Cell(name: "C3", what: "+ simplified repeating (no once, frequency enum, optional numbers)", vocabulary: .none, instructions: prod,
                 run: { i, p in await self.once(XOut3.self, instructions: i, prompt: p) }),
            Cell(name: "C4", what: "C3 + selective vocabulary (only what the words mention)", vocabulary: .selective, instructions: prod,
                 run: { i, p in await self.once(XOut3.self, instructions: i, prompt: p) }),
            Cell(name: "C5", what: "C3 + the full vocabulary of the trace", vocabulary: .full, instructions: prod,
                 run: { i, p in await self.once(XOut3.self, instructions: i, prompt: p) }),
            Cell(name: "P", what: "the production schema (BulkAgentDecision) with the full vocabulary: the control that reproduced the trace before the changes", vocabulary: .full, instructions: prod,
                 run: { i, p in await self.once(BulkAgentDecision.self, instructions: i, prompt: p) }),
            Cell(name: "Pnow", what: "the production schema with the selective vocabulary the app now sends", vocabulary: .selective, instructions: prod,
                 run: { i, p in await self.once(BulkAgentDecision.self, instructions: i, prompt: p) }),
        ]
    }

    // MARK: Counting

    private struct Tally {
        var runs: [ExperimentRun] = []
        var finished: Int { runs.filter { $0.outcome == "finished" }.count }
        var guardStops: Int { runs.filter { $0.outcome == "stopped by the output guard" }.count }
        var other: Int { runs.count - finished - guardStops }
        var oneTask: Int { runs.filter { $0.outcome == "finished" && $0.titles.count == 1 }.count }
        var productsInTitle: Int {
            runs.filter { r in
                let t = r.titles.joined(separator: " ").lowercased()
                return r.outcome == "finished" && ExperimentSetup.products.allSatisfy { t.contains($0) }
            }.count
        }
        var productsOnlyAsLabels: Int {
            runs.filter { r in
                let t = r.titles.joined(separator: " ").lowercased()
                let l = r.labelsPerItem.flatMap { $0 }.joined(separator: " ").lowercased()
                return r.outcome == "finished" && !ExperimentSetup.products.allSatisfy { t.contains($0) } && ExperimentSetup.products.allSatisfy { l.contains($0) }
            }.count
        }
        func leaks(_ text: String) -> Int {
            let said = text.lowercased()
            let known = Set(ExperimentSetup.labels.map { $0.lowercased() })
            return runs.filter { r in
                r.titles.contains { t in let k = t.lowercased().trimmingCharacters(in: .whitespaces); return known.contains(k) && !said.contains(k) }
            }.count
        }
        var repeating: Int { runs.filter { $0.repeatingItems > 0 }.count }
        var duplicates: Int {
            runs.filter { r in
                let keys = r.titles.map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
                return Set(keys).count < keys.count
            }.count
        }
        var tooMany: Int { runs.filter { $0.titles.count > 3 }.count }
        var averageItems: Double { runs.isEmpty ? 0 : Double(runs.map { $0.titles.count }.reduce(0, +)) / Double(runs.count) }
        var averageTokens: Int { runs.isEmpty ? 0 : runs.map(\.tokens).reduce(0, +) / runs.count }
        var averageSeconds: Double { runs.isEmpty ? 0 : runs.map(\.seconds).reduce(0, +) / Double(runs.count) }
    }

    func testTheExtractionMatrixOnTheRealModel() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["KITTY_REAL_MODEL"] == "1", "real-model experiment: set TEST_RUNNER_KITTY_REAL_MODEL=1")
        guard case .available = SystemLanguageModel.default.availability else { throw XCTSkip("the on-device model is not available") }
        let runs = max(1, Int(env["KITTY_REAL_RUNS"] ?? "") ?? 5)
        let wanted = env["KITTY_EXPERIMENT_CELLS"].map { Set($0.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }) }
        let out = env["KITTY_EXPERIMENT_OUT"] ?? NSTemporaryDirectory() + "extraction_experiments.md"

        var report = "# Extraction experiment on the real model\n\n"
        report += "\(runs) fresh-session runs per cell and input, the app's real output guard (cap 1,800 tokens, guard ~1,500, 40 items, 3 identical in a row), no tools.\n"
        report += "Checks are measurements made by the test, not rules of the app. Counts are what happened, not a guarantee.\n\n"
        report += "| cell | input | finished | stopped by guard | other | one task | products in title | products only in labels | has repeating | duplicate titles | >3 items | vocabulary words as items | avg items | avg tokens | avg s |\n"
        report += "|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|\n"
        var firstProblem: String?
        var samples = ""

        for cell in cells() where wanted?.contains(cell.name) ?? true {
            for input in ExperimentSetup.inputs {
                var tally = Tally()
                let prompt = ExperimentSetup.prompt(input.text, cell.vocabulary)
                for _ in 0..<runs { tally.runs.append(await cell.run(cell.instructions, prompt)) }
                let leaks = tally.leaks(input.text)
                report += "| \(cell.name) | \(input.name) | \(tally.finished)/\(runs) | \(tally.guardStops) | \(tally.other) | \(tally.oneTask) | \(tally.productsInTitle) | \(tally.productsOnlyAsLabels) | \(tally.repeating) | \(tally.duplicates) | \(tally.tooMany) | \(leaks) | "
                report += String(format: "%.1f | %d | %.1f |\n", tally.averageItems, tally.averageTokens, tally.averageSeconds)
                if firstProblem == nil, leaks > 0 || tally.duplicates > 0 || tally.guardStops > 0 || tally.tooMany > 0 {
                    firstProblem = "\(cell.name) (\(input.name)): \(leaks) run(s) with vocabulary words as items, \(tally.duplicates) with duplicate titles, \(tally.guardStops) stopped by the guard, \(tally.tooMany) with more than 3 items"
                }
                samples += "### \(cell.name), \(input.name): \(cell.what)\n"
                for (n, r) in tally.runs.enumerated() {
                    samples += "- run \(n + 1): \(r.outcome), \(r.titles.count) item(s), ~\(r.tokens) tokens, \(String(format: "%.1f", r.seconds)) s: \(r.titles.prefix(6).joined(separator: " | "))"
                    let labels = r.labelsPerItem.first ?? []
                    if !labels.isEmpty { samples += " [labels of the first: \(labels.joined(separator: ", "))]" }
                    if !r.repeatingNote.isEmpty { samples += " [first repeating: \(r.repeatingNote)]" }
                    if r.outcome != "finished" { samples += " [ended: \(r.error.prefix(160))]" }
                    samples += "\n"
                }
                samples += "\n"
                try? report.appending("\n## Samples (so far)\n\n" + samples).write(toFile: out, atomically: true, encoding: .utf8)
            }
        }
        report += "\nFirst cell (in order) showing leakage, duplicates, more than 3 items or a guard stop: \(firstProblem ?? "none in this run")\n"
        report += "\n## Samples\n\n" + samples
        try report.write(toFile: out, atomically: true, encoding: .utf8)
        print("EXPERIMENT TABLE WRITTEN TO \(out)")
        print(report)
    }
}

#endif
