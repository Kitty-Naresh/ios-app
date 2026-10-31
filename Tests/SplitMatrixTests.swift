import XCTest
#if canImport(FoundationModels)
import FoundationModels
#endif
@testable import Kitty

// Does the real on-device model split a request into one task per independently completable action or target, keep product names
// and shared context intact, and invent nothing? Skipped unless
//   TEST_RUNNER_KITTY_REAL_MODEL=1
// is set. Like the other experiments it MEASURES: every check below is made by this test, the app applies none of them.
//   TEST_RUNNER_KITTY_REAL_RUNS=10          runs per utterance (default 10)
//   TEST_RUNNER_KITTY_SPLIT_CASES=a,b       which cases (default all)
//   TEST_RUNNER_KITTY_SPLIT_OUT=/tmp/x.md   where the report is written
//   TEST_RUNNER_KITTY_SPLIT_PROFILE=flat    the path: full (default) or flat (FlatExtractionEngine, PathProfile.flat)
//   TEST_RUNNER_KITTY_SPLIT_BRIEF=1         also run the brief's examples (lists, repeats, purpose, clarify, tomorrow)
// Each run is one fresh VoiceTurnManager with the real DecisionEngine and an in-memory SaveSink, one `decide`, final speech.

#if canImport(FoundationModels)

/// What one turn left behind.
struct SplitOutcome {
    var kind: String                    // proposal, question, reply, wait
    var text: String
    var items: [DraftItem]
    var playbook: PlaybookDraftState?
    var seconds: Double
    var raw: String
    var titles: String { items.map(\.title).joined(separator: " | ") }
}

/// One thing the test measures about a run.
struct SplitCheck {
    /// split, name, context, invented, playbook, question
    var category: String
    var label: String
    var ok: (SplitOutcome) -> Bool
}

struct SplitCase {
    var name: String
    var said: String
    var checks: [SplitCheck]
}

enum SplitCases {
    private static let cal = Calendar.current
    static let now = ExperimentSetup.now

    static func has(_ i: DraftItem, _ word: String) -> Bool {
        let w = word.lowercased()
        return i.title.lowercased().contains(w) || (i.notes ?? "").lowercased().contains(w)
            || (i.instructions ?? "").lowercased().contains(w) || (i.reason ?? "").lowercased().contains(w)
            || (i.listName ?? "").lowercased().contains(w)
    }
    static func titleHas(_ i: DraftItem, _ word: String) -> Bool { i.title.lowercased().contains(word.lowercased()) }
    static func count(_ o: SplitOutcome, _ n: Int) -> Bool { o.kind == "proposal" && o.playbook == nil && o.items.count == n }
    /// Exactly one item for each target word, and no item for two targets.
    static func oneEach(_ o: SplitOutcome, _ targets: [String]) -> Bool {
        guard count(o, targets.count) else { return false }
        for t in targets where o.items.filter({ titleHas($0, t) }).count != 1 { return false }
        return !o.items.contains { i in targets.filter { titleHas(i, $0) }.count > 1 }
    }
    static func every(_ o: SplitOutcome, _ test: (DraftItem) -> Bool) -> Bool { !o.items.isEmpty && o.items.allSatisfy(test) }
    static func isSaturday(_ d: Date?) -> Bool { d.map { cal.component(.weekday, from: $0) == 7 } ?? false }
    static func isTomorrow(_ d: Date?) -> Bool {
        guard let d, let t = cal.date(byAdding: .day, value: 1, to: now) else { return false }
        return cal.isDate(d, inSameDayAs: t)
    }
    static func isEvening(_ i: DraftItem) -> Bool {
        i.slot == .evening || (i.timeMinutes ?? 0) >= 17 * 60 || titleHas(i, "evening")
    }
    /// Nothing but the requested items, and no day, time, person, priority or repeat nobody said.
    static func noExtraMetadata(_ o: SplitOutcome, allow: Set<String> = []) -> Bool {
        o.items.allSatisfy { i in
            (allow.contains("due") || i.due == nil) && (allow.contains("time") || (i.timeMinutes == nil && i.slot == nil))
                && (allow.contains("assignee") || i.assignee == nil) && i.priority == nil
                && (allow.contains("reason") || i.reason == nil) && (allow.contains("instructions") || i.instructions == nil)
                && (allow.contains("routine") || (i.kind == .task && i.recurrence == nil))
        }
    }
    static func noPlaybook(_ o: SplitOutcome) -> Bool { o.playbook == nil }

    /// The brief's examples. They measure the flat fields (a list, a repeat, a purpose, instructions) and also run on `.full`, where
    /// those fields do not exist, which is the comparison.
    static let brief: [SplitCase] = [
        SplitCase(name: "b-pharmacy-list", said: "Pharmacy list: buy Cetaphil body lotion, Teddybar soap, and Cipcal tablets.", checks: [
            SplitCheck(category: "split", label: "one task each for Cetaphil, Teddybar, Cipcal") { oneEach($0, ["cetaphil", "teddybar", "cipcal"]) },
            SplitCheck(category: "list", label: "the list is Pharmacy, not a task, on each item") { o in
                every(o) { ($0.listName ?? "").lowercased().contains("pharmacy") } && !o.items.contains { titleHas($0, "pharmacy") } },
            SplitCheck(category: "invented", label: "no day, time, person, repeat") { o in noExtraMetadata(o) },
        ]),
        SplitCase(name: "b-recurring", said: "Every morning, have the househelp water the balcony plants.", checks: [
            SplitCheck(category: "split", label: "one task, not copies for each day") { o in count(o, 1) && titleHas(o.items[0], "plant") },
            SplitCheck(category: "context", label: "a morning routine Swift can run") { o in
                every(o) { $0.kind == .routine && $0.recurrence != nil && ($0.slot == .morning || ($0.timeMinutes ?? 99_999) < 12 * 60) } },
            SplitCheck(category: "context", label: "the househelp is the assignee") { o in every(o) { ($0.assignee ?? "").lowercased().contains("househelp") } },
            SplitCheck(category: "invented", label: "nothing added") { o in noExtraMetadata(o, allow: ["routine", "time", "assignee"]) },
        ]),
        SplitCase(name: "b-purpose", said: "Buy Cipcal for calcium deficiency. Get 500 mg, one strip.", checks: [
            SplitCheck(category: "split", label: "exactly one task") { o in count(o, 1) && titleHas(o.items[0], "cipcal") },
            SplitCheck(category: "fields", label: "the purpose is the reason") { o in every(o) { ($0.reason ?? "").lowercased().contains("calcium") } },
            SplitCheck(category: "fields", label: "the dosage is the instructions") { o in every(o) { ($0.instructions ?? "").contains("500") } },
            SplitCheck(category: "invented", label: "no system notes, not a routine, no metadata") { o in every(o) { $0.notes == nil } && noExtraMetadata(o, allow: ["reason", "instructions"]) },
        ]),
        SplitCase(name: "b-clarify", said: "Buy Cipcal.", checks: [
            SplitCheck(category: "question", label: "the task is shown beside one question") { o in
                o.kind == "proposal" && o.items.count == 1 && o.text.filter { $0 == "?" }.count == 1 },
            SplitCheck(category: "invented", label: "nothing added, no metadata") { $0.items.count <= 1 && noExtraMetadata($0) },
        ]),
        SplitCase(name: "b-tomorrow", said: "Buy milk tomorrow.", checks: [
            SplitCheck(category: "split", label: "exactly one task") { o in count(o, 1) && titleHas(o.items[0], "milk") },
            SplitCheck(category: "context", label: "tomorrow, worked out by Swift") { o in every(o) { isTomorrow($0.due) } },
            SplitCheck(category: "question", label: "no question asked, only the save prompt") { o in o.text.lowercased().contains("should i save") },
            SplitCheck(category: "invented", label: "nothing added") { o in noExtraMetadata(o, allow: ["due"]) },
        ]),
        SplitCase(name: "b-two-lists", said: "Pharmacy list: Cetaphil, Teddybar, Cipcal. Grocery list: milk, bread, eggs.", checks: [
            SplitCheck(category: "split", label: "six tasks, one each") { o in oneEach(o, ["cetaphil", "teddybar", "cipcal", "milk", "bread", "eggs"]) },
            SplitCheck(category: "list", label: "three on Pharmacy, three on Grocery") { o in
                o.items.filter { ($0.listName ?? "").lowercased().contains("pharmacy") }.count == 3
                    && o.items.filter { ($0.listName ?? "").lowercased().contains("grocery") }.count == 3 },
            SplitCheck(category: "invented", label: "no day, time, person, repeat") { o in noExtraMetadata(o) },
        ]),
    ]

    static let all: [SplitCase] = [
        SplitCase(name: "milk-bread", said: "Buy milk and bread from Blinkit", checks: [
            SplitCheck(category: "split", label: "one task for milk, one for bread") { oneEach($0, ["milk", "bread"]) },
            SplitCheck(category: "context", label: "Blinkit on each") { every($0) { has($0, "blinkit") } },
            SplitCheck(category: "invented", label: "nothing added, no metadata") { $0.items.count <= 2 && noExtraMetadata($0) },
            SplitCheck(category: "playbook", label: "no playbook") { noPlaybook($0) },
        ]),
        SplitCase(name: "pharmacy", said: "Get Cetaphil body lotion, Cipcal and Tedibar soap", checks: [
            SplitCheck(category: "split", label: "one task each for Cetaphil, Cipcal, Tedibar") { oneEach($0, ["cetaphil", "cipcal", "tedibar"]) },
            SplitCheck(category: "name", label: "\"Cetaphil body lotion\" kept together") { o in o.items.contains { titleHas($0, "cetaphil body lotion") } },
            SplitCheck(category: "invented", label: "nothing added, no metadata") { $0.items.count <= 3 && noExtraMetadata($0) },
            SplitCheck(category: "playbook", label: "no playbook") { noPlaybook($0) },
        ]),
        SplitCase(name: "rani", said: "Ask Rani to clean the kitchen and the bathroom on Saturday", checks: [
            SplitCheck(category: "split", label: "one task for the kitchen, one for the bathroom") { oneEach($0, ["kitchen", "bathroom"]) },
            SplitCheck(category: "context", label: "Rani on each") { every($0) { has($0, "rani") || ($0.assignee ?? "").lowercased() == "rani" } },
            SplitCheck(category: "context", label: "Saturday on each") { every($0) { isSaturday($0.due) } },
            SplitCheck(category: "invented", label: "nothing added") { $0.items.count <= 2 && noExtraMetadata($0, allow: ["due", "assignee"]) },
        ]),
        SplitCase(name: "zepto", said: "Order paneer and Amul butter from Zepto tomorrow evening", checks: [
            SplitCheck(category: "split", label: "one task for paneer, one for Amul butter") { oneEach($0, ["paneer", "butter"]) },
            SplitCheck(category: "name", label: "\"Amul butter\" kept together") { o in o.items.contains { titleHas($0, "amul butter") } },
            SplitCheck(category: "context", label: "Zepto on each") { every($0) { has($0, "zepto") } },
            SplitCheck(category: "context", label: "tomorrow on each") { every($0) { isTomorrow($0.due) } },
            SplitCheck(category: "context", label: "evening on each") { every($0) { isEvening($0) } },
            SplitCheck(category: "invented", label: "nothing added") { $0.items.count <= 2 && noExtraMetadata($0, allow: ["due", "time"]) },
        ]),
        SplitCase(name: "routines", said: "Water the plants and feed the cat every morning", checks: [
            SplitCheck(category: "split", label: "one routine for the plants, one for the cat") { o in
                o.kind == "proposal" && oneEach(o, ["plant", "cat"]) },
            SplitCheck(category: "context", label: "each repeats") { every($0) { $0.kind == .routine && $0.recurrence != nil } },
            SplitCheck(category: "context", label: "morning on each") { every($0) { $0.slot == .morning || titleHas($0, "morning") || ($0.timeMinutes ?? 99_999) < 12 * 60 } },
            SplitCheck(category: "invented", label: "nothing added") { $0.items.count <= 2 && noExtraMetadata($0, allow: ["routine", "time"]) },
        ]),
        SplitCase(name: "one-task", said: "Buy milk and bread from Blinkit, but make it one task", checks: [
            SplitCheck(category: "split", label: "one task holding both") { o in
                count(o, 1) && titleHas(o.items[0], "milk") && titleHas(o.items[0], "bread") },
            SplitCheck(category: "context", label: "Blinkit kept") { every($0) { has($0, "blinkit") } },
            SplitCheck(category: "invented", label: "no metadata") { noExtraMetadata($0) },
        ]),
        SplitCase(name: "plumber", said: "Call the plumber", checks: [
            SplitCheck(category: "split", label: "exactly one task") { o in count(o, 1) && titleHas(o.items[0], "plumber") },
            SplitCheck(category: "invented", label: "no steps added, no metadata") { $0.items.count <= 1 && noExtraMetadata($0) },
            SplitCheck(category: "playbook", label: "no playbook") { noPlaybook($0) },
        ]),
        SplitCase(name: "dolo", said: "Remind me to take Dolo 650 after lunch", checks: [
            SplitCheck(category: "split", label: "exactly one task") { o in count(o, 1) },
            SplitCheck(category: "name", label: "\"Dolo 650\" kept together") { o in o.items.contains { titleHas($0, "dolo 650") } },
            SplitCheck(category: "invented", label: "no steps added, not a routine") { $0.items.count <= 1 && noExtraMetadata($0, allow: ["time", "due", "instructions"]) },
            SplitCheck(category: "playbook", label: "no playbook") { noPlaybook($0) },
        ]),
        SplitCase(name: "friends", said: "My friends are visiting, I need to prepare the room, order food from Blinkit, book a cab", checks: [
            SplitCheck(category: "split", label: "one task each for the room, the food, the cab") { oneEach($0, ["room", "food", "cab"]) },
            SplitCheck(category: "context", label: "Blinkit on the food task") { o in o.items.contains { titleHas($0, "food") && has($0, "blinkit") } },
            SplitCheck(category: "invented", label: "nothing added, no metadata") { $0.items.count <= 3 && noExtraMetadata($0) },
            SplitCheck(category: "playbook", label: "no playbook") { noPlaybook($0) },
        ]),
        SplitCase(name: "playbook", said: "Teach me a playbook for hosting guests: first clean the room, then order food, then book a cab", checks: [
            SplitCheck(category: "playbook", label: "a playbook with three ordered steps") { o in (o.playbook?.steps.count ?? 0) == 3 },
        ]),
        SplitCase(name: "question", said: "Remind me", checks: [
            SplitCheck(category: "question", label: "one question, nothing made") { o in o.kind == "question" && o.items.isEmpty && o.text.filter { $0 == "?" }.count == 1 },
        ]),
        SplitCase(name: "leak", said: "Pick up the dry cleaning", checks: [
            SplitCheck(category: "split", label: "exactly one task") { o in count(o, 1) && titleHas(o.items[0], "dry clean") },
            SplitCheck(category: "invented", label: "nothing from other requests (milk, bread, Blinkit, Zepto)") { o in
                !o.items.contains { i in ["milk", "bread", "blinkit", "zepto", "paneer"].contains { has(i, $0) } } && o.items.count <= 1 },
        ]),
    ]
}

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
@MainActor
final class SplitMatrixTests: XCTestCase {
    /// The path being measured: `full` (default) or `flat`.
    private var flat: Bool { ProcessInfo.processInfo.environment["KITTY_SPLIT_PROFILE"]?.lowercased() == "flat" }

    private func manager() -> VoiceTurnManager {
        let engine: DecisionProviding = flat ? FlatExtractionEngine() : DecisionEngine()
        let turns = VoiceTurnManager(engine: engine, sink: InMemorySaveSink(),
                         knownCategories: { ExperimentSetup.categories }, knownAssignees: { ExperimentSetup.people }, savedTasks: { [] })
        if flat { turns.profile = .flat }
        return turns
    }

    private func run(_ c: SplitCase) async -> SplitOutcome {
        let turns = manager()
        let started = Date()
        let result = await turns.decide(utterance: c.said, now: SplitCases.now, final: true)
        let seconds = Date().timeIntervalSince(started)
        let raw = TurnCapture.shared.snapshot.calls.last?.detail?.partialReply ?? ""
        var kind = "wait", text = ""
        switch result {
        case .wait, .handled: break
        case .question(let q): kind = "question"; text = q
        case .reply(let a): kind = "reply"; text = a.message
        case .proposal(let p): kind = "proposal"; text = [p.reply, p.prompt].compactMap { $0 }.joined(separator: " | ")
        }
        return SplitOutcome(kind: kind, text: text, items: turns.state.drafts.ordered, playbook: turns.state.drafts.playbook,
                            seconds: seconds, raw: raw)
    }

    private func percentile(_ s: [Double], _ p: Double) -> Double {
        let v = s.sorted()
        return v.isEmpty ? 0 : v[min(v.count - 1, Int(Double(v.count - 1) * p + 0.5))]
    }

    func testTheSplitMatrixOnTheRealModel() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["KITTY_REAL_MODEL"] == "1", "real-model matrix: set TEST_RUNNER_KITTY_REAL_MODEL=1")
        guard case .available = SystemLanguageModel.default.availability else { throw XCTSkip("the on-device model is not available") }
        let runs = max(1, Int(env["KITTY_REAL_RUNS"] ?? "") ?? 10)
        let wanted = env["KITTY_SPLIT_CASES"].map { Set($0.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }) }
        let out = env["KITTY_SPLIT_OUT"] ?? NSTemporaryDirectory() + "split_matrix.md"

        let cases = SplitCases.all + (env["KITTY_SPLIT_BRIEF"] == "1" || wanted?.contains(where: { $0.hasPrefix("b-") }) == true ? SplitCases.brief : [])
        var perCase = ""
        var samples = ""
        var catPass: [String: Int] = [:], catTotal: [String: Int] = [:]
        var allSeconds: [Double] = []
        var casesAllOK = 0, casesTotal = 0
        for c in cases where wanted?.contains(c.name) ?? true {
            var outcomes: [SplitOutcome] = []
            for _ in 0..<runs { outcomes.append(await run(c)) }
            allSeconds += outcomes.map(\.seconds)
            perCase += "| \(c.name) | \(c.said) |"
            var allOK = 0
            for check in c.checks {
                let passed = outcomes.filter { check.ok($0) }.count
                perCase += " \(check.category): \(check.label) \(passed)/\(runs);"
                catPass[check.category, default: 0] += passed
                catTotal[check.category, default: 0] += runs
            }
            for o in outcomes where c.checks.allSatisfy({ $0.ok(o) }) { allOK += 1 }
            casesAllOK += allOK; casesTotal += runs
            perCase += " **all \(allOK)/\(runs)** | \(String(format: "%.1f", percentile(outcomes.map(\.seconds), 0.5))) | \(String(format: "%.1f", percentile(outcomes.map(\.seconds), 0.9))) |\n"
            samples += "### \(c.name): \"\(c.said)\"\n"
            for (n, o) in outcomes.enumerated() {
                let ok = c.checks.allSatisfy { $0.ok(o) }
                let failed = c.checks.filter { !$0.ok(o) }.map(\.label)
                let detail = o.items.map { i -> String in
                    var s = i.title
                    if let a = i.assignee { s += " [for \(a)]" }
                    if let d = i.due { s += " [due \(d.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))]" }
                    if let m = i.timeMinutes { s += " [\(DaySlot.clockLabel(m))]" } else if let sl = i.slot { s += " [\(sl.rawValue)]" }
                    if i.kind == .routine { s += " [repeats: \(i.recurrence?.scheduleText ?? "?")]" }
                    if let l = i.listName { s += " [list: \(l)]" }
                    if let r = i.reason { s += " [purpose: \(r)]" }
                    if let n = i.instructions { s += " [instructions: \(n)]" }
                    if let sd = i.softDue { s += " [around: \(sd)]" }
                    if !i.unparsed.isEmpty { s += " [needs a fix: \(i.unparsed.keys.sorted().joined(separator: ", "))]" }
                    return s
                }.joined(separator: " | ")
                samples += "- run \(n + 1): \(ok ? "ok" : "FAIL: " + failed.joined(separator: "; ")) (\(o.kind), \(String(format: "%.1f", o.seconds)) s) \(o.playbook.map { "playbook \($0.name): " + $0.steps.map(\.title).joined(separator: " > ") } ?? (detail.isEmpty ? o.text : detail))\n"
                if n == 0 || !ok, !o.raw.isEmpty { samples += "    model wrote: \(o.raw.replacingOccurrences(of: "\n", with: " ").prefix(500))\n" }
            }
            samples += "\n"
            try? (header(runs) + perCase + "\n## Samples (so far)\n\n" + samples).write(toFile: out, atomically: true, encoding: .utf8)
        }
        var summary = "\n## By what was measured\n\n| measured | passed | of |\n|---|---|---|\n"
        for cat in ["split", "name", "context", "list", "fields", "invented", "playbook", "question"] where catTotal[cat] != nil {
            summary += "| \(cat) | \(catPass[cat] ?? 0) | \(catTotal[cat] ?? 0) |\n"
        }
        summary += "| every check of the case | \(casesAllOK) | \(casesTotal) |\n"
        summary += "\nMedian \(String(format: "%.1f", percentile(allSeconds, 0.5))) s, p90 \(String(format: "%.1f", percentile(allSeconds, 0.9))) s per turn.\n"
        let report = header(runs) + perCase + summary + "\n## Samples\n\n" + samples
        try report.write(toFile: out, atomically: true, encoding: .utf8)
        print("SPLIT MATRIX WRITTEN TO \(out)")
        print(report)
    }

    private func header(_ runs: Int) -> String {
        "# One task per requested action: real-model matrix (\(flat ? "flat" : "full") path)\n\n\(runs) runs per utterance. One fresh turn manager per run, the real \(flat ? "FlatExtractionEngine" : "DecisionEngine"), final speech, no saved tasks. Text, not audio.\nEvery check is a measurement made by the test; the app applies none of them.\n\n| case | said | measured | all | median s | p90 s |\n|---|---|---|---|---|---|\n"
    }
}


// The question the model words when the user's words hold no task. Skipped unless TEST_RUNNER_KITTY_REAL_MODEL=1.
//   TEST_RUNNER_KITTY_REAL_RUNS=5            runs per utterance
//   TEST_RUNNER_KITTY_QUESTION_OUT=/tmp/q.md where the report is written
// The test only records what came back and how long it took; whether a question is sensible, short and free of invented tasks is
// read from the report by a person. The only automatic check is Swift's own: it must be one question, and no card may appear.
@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
@MainActor
final class ContentQuestionRealModelTests: XCTestCase {
    func testTheContentQuestionOnTheRealModel() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["KITTY_REAL_MODEL"] == "1", "real-model check: set TEST_RUNNER_KITTY_REAL_MODEL=1")
        guard case .available = SystemLanguageModel.default.availability else { throw XCTSkip("the on-device model is not available") }
        let runs = max(1, Int(env["KITTY_REAL_RUNS"] ?? "") ?? 5)
        let out = env["KITTY_QUESTION_OUT"] ?? NSTemporaryDirectory() + "content_question.md"
        let said = ["create a task", "Can you create a new task? task?", "new task", "please add something", "add a task to my Blinkit list", "I want to add a reminder"]
        var report = "# The question for words with no task: real model\n\n\(runs) runs per utterance, fresh turn manager each time, the real FlatExtractionEngine, text not audio. Questions are quoted exactly as the model wrote them.\n\n"
        var seconds: [Double] = []
        var cards = 0, oneQuestion = 0, total = 0
        for words in said {
            report += "### \"\(words)\"\n"
            for _ in 0..<runs {
                let store = TaskStore.shared
                let turns = VoiceTurnManager(engine: FlatExtractionEngine(), sink: InMemorySaveSink(), knownCategories: { [] }, knownAssignees: { [] }, savedTasks: { [] })
                turns.profile = .flat
                turns.savedStore = store
                let started = Date()
                let result = await turns.decide(utterance: words, final: true)
                let took = Date().timeIntervalSince(started)
                seconds.append(took)
                total += 1
                switch result {
                case .question(let q):
                    oneQuestion += 1
                    report += "- (\(String(format: "%.1f", took)) s) \(q)\n"
                case .proposal(let p):
                    cards += 1
                    report += "- (\(String(format: "%.1f", took)) s) CARD: \(p.title)\n"
                case .wait, .handled: report += "- (\(String(format: "%.1f", took)) s) no question (listening)\n"
                case .reply(let r): report += "- (\(String(format: "%.1f", took)) s) reply: \(r.message)\n"
                }
            }
            report += "\n"
        }
        let sorted = seconds.sorted()
        let median = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
        report += "Questions: \(oneQuestion)/\(total). Cards: \(cards)/\(total). Median \(String(format: "%.1f", median)) s, slowest \(String(format: "%.1f", sorted.last ?? 0)) s.\n"
        try report.write(toFile: out, atomically: true, encoding: .utf8)
        XCTAssertEqual(cards, 0, "no card may ever come from words with no task")
    }
}

#endif
