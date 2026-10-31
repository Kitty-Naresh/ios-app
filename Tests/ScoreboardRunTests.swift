import XCTest
#if canImport(FoundationModels)
import FoundationModels
#endif
@testable import Kitty

// Runs the voice-note scoreboard (Tests/Scoreboard/scoreboard_v1.json) on the real on-device model, the way the app runs a turn:
// a fresh VoiceTurnManager with the app's own default engine (flat), an in-memory save sink, `decide(final: true)`.
// Skipped unless TEST_RUNNER_KITTY_REAL_MODEL=1 is set.
//   TEST_RUNNER_KITTY_REAL_RUNS=3             runs per case (default 3)
//   TEST_RUNNER_KITTY_SCOREBOARD_CASES=A01,B02  which cases (default all)
//   TEST_RUNNER_KITTY_SCOREBOARD_FILE=/path   the cases (default: the repo's scoreboard_v1.json)
//   TEST_RUNNER_KITTY_SCOREBOARD_OUT=/tmp/x.md  where the report is written
// This MEASURES. The checks below are made by this test; the app applies none of them. `decide` does not exercise the
// endpointing (quiet hold) or the speech recogniser: the words go in as text, as a transcript would.

#if canImport(FoundationModels)

private struct SBOutcome {
    var kind: String            // proposal, question, reply, wait
    var text: String
    var items: [DraftItem]
    var seconds: Double
    var raw: String
    var trace = ""
}

private struct SBVerdict {
    var pass = true
    var fails: [String] = []
    var manual: [String] = []
    mutating func fail(_ s: String) { pass = false; fails.append(s) }
}

@MainActor
final class ScoreboardRunTests: XCTestCase {
    private let people = ["Househelp", "Me", "Meera", "Rohan", "Aarav", "Anaya", "Papa", "Rani", "Suresh", "Bruno"]
    private var now: Date { ISO8601DateFormatter().date(from: "2026-10-28T12:00:00+05:30")! }

    private func manager(store: TaskStore? = nil) -> VoiceTurnManager {
        let turns = VoiceTurnManager(sink: InMemorySaveSink(), knownCategories: { ExperimentSetup.categories },
                                     knownAssignees: { [people] in people }, savedTasks: { [] })
        if let store { turns.savedStore = store }
        return turns
    }

    // MARK: Running a turn

    private func run(_ turns: VoiceTurnManager, _ said: String) async -> SBOutcome {
        let started = Date()
        let result = await turns.decide(utterance: said, now: now, final: true)
        let seconds = Date().timeIntervalSince(started)
        let raw = TurnCapture.shared.snapshot.calls.last?.detail?.partialReply ?? ""
        var kind = "wait", text = ""
        switch result {
        case .wait, .handled: break
        case .question(let q): kind = "question"; text = q
        case .reply(let a): kind = "reply"; text = a.message
        case .proposal(let p): kind = "proposal"; text = [p.reply, p.prompt].compactMap { $0 }.joined(separator: " | ")
        }
        let keep: Set<String> = ["SWIFT", "WARNING", "FROM MODEL", "CHECKS", "RESULT", "ROUTE", "MODEL"]
        let trace = TurnCapture.shared.snapshot.stages.filter { keep.contains($0.stage) }
            .map { "\($0.stage): \($0.text.replacingOccurrences(of: "\n", with: " ").prefix(400))" }.joined(separator: "\n        ")
        return SBOutcome(kind: kind, text: text, items: turns.state.drafts.ordered, seconds: seconds, raw: raw, trace: trace)
    }

    // MARK: Word helpers

    private func words(_ s: String) -> [String] {
        s.lowercased().split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init)
    }

    /// Whole-word match with a light stem: serviced ~ service, tablets ~ tablet. Short tokens must match exactly.
    private func hasWord(_ text: String, _ token: String) -> Bool {
        let t = token.lowercased()
        return words(text).contains { w in
            if t.count <= 3 || w.count <= 3 { return w == t }
            return w.hasPrefix(String(t.prefix(max(4, t.count - 2)))) || t.hasPrefix(String(w.prefix(max(4, w.count - 2))))
        }
    }

    private func hasPhrase(_ text: String, _ phrase: String) -> Bool {
        let t = " " + words(text).joined(separator: " ") + " "
        let p = words(phrase).joined(separator: " ")
        return !p.isEmpty && t.contains(" " + p + " ")
    }

    private func sameDay(_ d: Date?, _ iso: String) -> Bool {
        guard let d else { return false }
        let p = iso.split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return false }
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        return c.year == p[0] && c.month == p[1] && c.day == p[2]
    }

    private func timeOK(_ i: DraftItem, _ expected: String) -> Bool {
        if expected.contains(":") {
            let p = expected.split(separator: ":").compactMap { Int($0) }
            return p.count == 2 && i.timeMinutes == p[0] * 60 + p[1]
        }
        if let m = i.timeMinutes {
            switch expected {
            case "morning": return m < 12 * 60
            case "evening": return m >= 16 * 60
            default: return false
            }
        }
        return i.slot?.rawValue == expected
    }

    private func assigneeOK(_ i: DraftItem, _ expected: Any?) -> Bool {
        if expected is NSNull { let a = (i.assignee ?? "").lowercased(); return a.isEmpty || a == "me" }
        guard let e = (expected as? String)?.lowercased() else { return true }
        let a = (i.assignee ?? "").lowercased().replacingOccurrences(of: " ", with: "")
        if a.isEmpty { return false }
        let first = e.split(separator: " ").first.map(String.init) ?? e
        if a.contains(first) { return true }
        return e.contains("house help") && (a.contains("househelp") || a.contains("rani"))
    }

    private func scheduleOK(_ i: DraftItem, _ expected: String) -> Bool {
        let have = [i.schedule, i.recurrence?.scheduleText, i.unparsed["repeat"]].compactMap { $0 }.joined(separator: " ")
        guard i.kind == .routine || i.schedule != nil || i.unparsed["repeat"] != nil else { return false }
        let stop: Set<String> = ["every", "on", "the", "of", "a", "when", "we", "are"]
        return words(expected).filter { !stop.contains($0) && $0.count > 2 }.allSatisfy { hasWord(have, $0) }
    }

    private func anyToken(_ fields: [String?], _ expected: String) -> Bool {
        let hay = fields.compactMap { $0 }.joined(separator: " ")
        guard !hay.isEmpty else { return false }
        return words(expected).filter { $0.count >= 4 || ($0.first?.isNumber ?? false) }.contains { hasWord(hay, $0) }
    }

    private func listOK(_ i: DraftItem, _ expected: String) -> Bool {
        guard let l = i.listName, let first = words(expected).first else { return false }
        return hasWord(l, first)
    }

    private func describe(_ i: DraftItem) -> String {
        var s = i.title
        if let a = i.assignee { s += " [for \(a)]" }
        if let d = i.due { s += " [due \(d.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))]" }
        if let m = i.timeMinutes { s += " [\(DaySlot.clockLabel(m))]" } else if let sl = i.slot { s += " [\(sl.rawValue)]" }
        if i.kind == .routine { s += " [repeats: \(i.recurrence?.scheduleText ?? "?")]" }
        if let sc = i.schedule { s += " [schedule: \(sc)]" }
        if let l = i.listName { s += " [list: \(l)]" }
        if let r = i.reason { s += " [purpose: \(r)]" }
        if let n = i.instructions { s += " [instructions: \(n)]" }
        if let sd = i.softDue { s += " [around: \(sd)]" }
        if !i.unparsed.isEmpty { s += " [needs a fix: \(i.unparsed.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ", "))]" }
        if !i.advisories.isEmpty { s += " [note: \(i.advisories.joined(separator: "; "))]" }
        return s
    }

    // MARK: Scoring one single-turn case

    private func fieldChecks(_ i: DraftItem, _ exp: [String: Any], label: String, _ v: inout SBVerdict) {
        if exp.keys.contains("assignee"), !assigneeOK(i, exp["assignee"]) { v.fail("\(label): assignee \(i.assignee ?? "none") (wanted \(exp["assignee"] ?? "?"))") }
        if let d = exp["due"] as? String, !sameDay(i.due, d) { v.fail("\(label): due \(i.due.map { $0.formatted(.dateTime.month().day()) } ?? "none") (wanted \(d))") }
        if exp.keys.contains("due"), exp["due"] is NSNull, i.due != nil { v.fail("\(label): has a due date (wanted none)") }
        if let t = exp["time"] as? String, !timeOK(i, t) { v.fail("\(label): time \(i.timeMinutes.map { DaySlot.clockLabel($0) } ?? i.slot?.rawValue ?? "none") (wanted \(t))") }
        if let s = exp["schedule"] as? String, !scheduleOK(i, s) { v.fail("\(label): repeat \(i.schedule ?? i.recurrence?.scheduleText ?? "none") (wanted \(s))") }
        if let p = exp["purpose"] as? String, !anyToken([i.reason], p) { v.fail("\(label): purpose \(i.reason ?? "none") (wanted \(p))") }
        if let n = exp["instructions"] as? String, !anyToken([i.instructions, i.title, i.notes, i.reason], n) { v.fail("\(label): instructions \(i.instructions ?? "none") (wanted \(n))") }
        if let s = exp["due_soft"] as? String, !anyToken([i.softDue], s) { v.fail("\(label): timeframe \(i.softDue ?? "none") (wanted \(s))") }
    }

    private func score(_ exp: [String: Any], _ o: SBOutcome) -> SBVerdict {
        var v = SBVerdict()
        let want = exp["outcome"] as? String ?? "create"
        switch want {
        case "create": if !(o.kind == "proposal" && !o.items.isEmpty) { v.fail("outcome \(o.kind) (wanted a card with tasks)") }
        case "clarify":
            if o.kind == "wait" { v.fail("silent turn: nothing shown (wanted a question)") }
            else if !(o.kind == "question" || (o.kind == "proposal" && o.items.isEmpty)) { v.fail("outcome \(o.kind) (wanted a question)") }
            if !o.items.isEmpty { v.fail("made \(o.items.count) task(s) (wanted none)") }
        case "wait": if o.kind != "wait" { v.fail("outcome \(o.kind) (wanted to keep listening)") }
        case "none": if o.kind == "proposal" && !o.items.isEmpty { v.fail("made a card (wanted nothing)") }
        case "answer": if o.kind != "reply" { v.fail("outcome \(o.kind) (wanted an answer)") }
        default: break
        }
        let required = exp["tasks"] as? [[String: Any]] ?? []
        let optional = exp["optional_tasks"] as? [[String: Any]] ?? []
        var unmatched = Array(o.items.indices)
        func take(_ t: [String: Any]) -> Int? {
            let tokens = (t["title_has"] as? [String]) ?? []
            if let n = unmatched.first(where: { n in tokens.allSatisfy { hasWord(o.items[n].title, $0) } }) { unmatched.removeAll { $0 == n }; return n }
            if let alt = t["partial_ok"] as? [String], let n = unmatched.first(where: { n in alt.allSatisfy { hasWord(o.items[n].title, $0) } }) {
                unmatched.removeAll { $0 == n }; v.manual.append("partial title match: \(o.items[n].title)"); return n
            }
            return nil
        }
        for t in required {
            let label = (t["example"] as? String) ?? ((t["title_has"] as? [String]) ?? []).joined(separator: " ")
            guard let n = take(t) else { v.fail("missing task: \(label)"); continue }
            var merged = t
            if let soft = exp["due_soft"] { merged["due_soft"] = soft }
            fieldChecks(o.items[n], merged, label: label, &v)
        }
        for t in optional { _ = take(t) }
        if want == "create", !unmatched.isEmpty { v.fail("extra task(s): " + unmatched.map { o.items[$0].title }.joined(separator: " | ")) }
        if let l = exp["list"] as? String, want == "create" {
            for i in o.items where !listOK(i, l) { v.fail("\(i.title): list \(i.listName ?? "none") (wanted \(l))") }
        }
        if want == "create", exp["list"] == nil, exp["scope"] == nil, o.items.contains(where: { $0.listName != nil }), (exp["tasks"] as? [[String: Any]])?.contains(where: { $0["list"] != nil }) != true {
            v.manual.append("a list was made that the case did not expect: " + Set(o.items.compactMap(\.listName)).sorted().joined(separator: ", "))
        }
        for m in (exp["must_not"] as? [String]) ?? [] { mustNot(m, o, &v) }
        return v
    }

    private func quoted(_ s: String) -> [String] {
        var out: [String] = [], cur = "", inside = false
        for ch in s {
            if ch == "'" { if inside { out.append(cur); cur = "" }; inside.toggle() } else if inside { cur.append(ch) }
        }
        return out
    }

    private func mustNot(_ m: String, _ o: SBOutcome, _ v: inout SBVerdict) {
        let l = m.lowercased()
        let q = quoted(m)
        if !q.isEmpty, l.contains("title") || l.contains("list") || l.contains("task") {
            for phrase in q {
                let hit = o.items.contains { hasPhrase($0.title, phrase) || ($0.listName.map { hasPhrase($0, phrase) } ?? false) }
                if hit { v.fail("must not: \(m)") }
            }
        } else if l.contains("a due date") || l.contains("a specific date") || (l.contains("invented") && l.contains("date")) {
            if o.items.contains(where: { $0.due != nil }) { v.fail("must not: \(m)") }
        } else if l.contains("an assignee") {
            if o.items.contains(where: { ($0.assignee ?? "").isEmpty == false }) { v.fail("must not: \(m)") }
        } else if l.contains("a time") {
            if o.items.contains(where: { $0.timeMinutes != nil }) { v.fail("must not: \(m)") }
        } else if l.contains("a list at all") {
            if o.items.contains(where: { $0.listName != nil }) { v.fail("must not: \(m)") }
        } else if l.contains("more than one") || l.contains("two tasks") || l.contains("two separate") || l.contains("two one-time") {
            if o.items.count > 1 { v.fail("must not: \(m)") }
        } else if l.contains("a purpose") {
            if o.items.contains(where: { $0.reason != nil }) { v.fail("must not: \(m)") }
        } else if l.contains("a repeat") || l.contains("schedule or repeat") {
            if o.items.contains(where: { $0.kind == .routine || $0.schedule != nil }) { v.fail("must not: \(m)") }
        } else if l.contains("one-time task") {
            if o.items.contains(where: { $0.kind == .task && $0.schedule == nil && $0.unparsed["repeat"] == nil }) { v.fail("must not: \(m)") }
        } else {
            v.manual.append("check by eye: \(m)")
        }
    }

    // MARK: Multi-turn cases (checked by hand-written rules)

    private func titleOf(_ o: SBOutcome, _ token: String) -> DraftItem? { o.items.first { hasWord($0.title, token) } }

    private func runMulti(_ id: String, _ turnsSaid: [String], setup: ((TaskStore) -> Void)? = nil) async -> (verdict: SBVerdict, outcomes: [SBOutcome]) {
        var store: TaskStore?
        if setup != nil {
            let s = TaskStore(defaults: UserDefaults(suiteName: "kitty.scoreboard.\(UUID().uuidString)")!)
            setup?(s)
            store = s
        }
        let turns = manager(store: store)
        var outs: [SBOutcome] = []
        for said in turnsSaid { outs.append(await run(turns, said)) }
        var v = SBVerdict()
        guard let last = outs.last else { v.fail("no turns"); return (v, outs) }
        switch id {
        case "J01":
            let titles = last.items.map(\.title)
            for t in ["milk", "bread", "egg"] where !titles.contains(where: { hasWord($0, t) }) { v.fail("missing \(t)") }
            if last.items.count != 3 { v.fail("\(last.items.count) tasks (wanted 3)") }
            for i in last.items where !listOK(i, "Blinkit order") { v.fail("\(i.title): list \(i.listName ?? "none")") }
        case "J02":
            if last.items.count != 2 { v.fail("\(last.items.count) tasks (wanted 2)") }
            if let p = titleOf(last, "plumber") { if !sameDay(p.due, "2026-10-30") { v.fail("plumber due \(p.due.map { $0.formatted(.dateTime.month().day()) } ?? "none") (wanted Fri 30 Oct)") } } else { v.fail("plumber task missing") }
            if let b0 = outs.first.flatMap({ titleOf($0, "bulb") }), let b1 = titleOf(last, "bulb") {
                if b0.due != b1.due || b0.timeMinutes != b1.timeMinutes || b0.assignee != b1.assignee { v.fail("bulbs changed by the edit") }
            } else { v.fail("bulbs task missing") }
        case "J03":
            if last.items.count != 1 || titleOf(last, "plant") == nil { v.fail("left: " + (last.items.map(\.title).joined(separator: " | ").isEmpty ? "nothing" : last.items.map(\.title).joined(separator: " | ")) + " (wanted only the plants)") }
        case "J04":
            let after2 = outs.count > 1 ? outs[1] : last
            for t in ["clean", "wash"] {
                if let i = titleOf(after2, t) {
                    if !assigneeOK(i, "Househelp (house help)") { v.fail("after turn 2: \(i.title) assignee \(i.assignee ?? "none")") }
                    if !sameDay(i.due, "2026-10-29") { v.fail("after turn 2: \(i.title) due \(i.due.map { $0.formatted(.dateTime.month().day()) } ?? "none")") }
                } else { v.fail("after turn 2: \(t) task missing") }
            }
            if let m = titleOf(last, "milk") {
                if assigneeOK(m, "Househelp (house help)") && (m.assignee ?? "").isEmpty == false { v.fail("milk got the house-help assignee: \(m.assignee ?? "")") }
                if m.due != nil { v.fail("milk got a due date it was not given") }
            } else { v.fail("milk task missing") }
        case "J05":
            if let e = titleOf(last, "egg") { if !listOK(e, "Blinkit order") { v.fail("eggs list \(e.listName ?? "none")") } }
            else if !last.text.lowercased().contains("egg") { v.fail("no preview mentioning eggs (outcome \(last.kind): \(last.text))") }
            v.manual.append("check by eye: preview must say it is adding to the EXISTING Blinkit order, and nothing must be applied before yes")
        case "J06":
            if last.kind != "reply" { v.fail("outcome \(last.kind) (wanted an answer)") }
            if !last.text.lowercased().contains("milk") { v.fail("answer does not mention milk") }
            if last.text.lowercased().contains("school") { v.fail("answer lists the school call as something to buy") }
            if !last.items.isEmpty { v.fail("made a task from a question") }
        default: v.manual.append("no rule for \(id)")
        }
        return (v, outs)
    }

    private func multiSetup(_ id: String) -> ((TaskStore) -> Void)? {
        let today = Calendar.current.startOfDay(for: now)
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: today)
        switch id {
        case "J05":
            return { s in
                s.addMany([PlannedTask(title: "Buy milk", category: .guess(from: "milk"), due: nil, profile: "Blinkit order"),
                           PlannedTask(title: "Buy bread", category: .guess(from: "bread"), due: nil, profile: "Blinkit order")])
            }
        case "J06":
            return { s in
                s.addMany([PlannedTask(title: "Buy milk", category: .guess(from: "milk"), due: today, profile: "Blinkit order"),
                           PlannedTask(title: "Call school", category: .guess(from: "school"), due: tomorrow),
                           PlannedTask(title: "Pay electricity bill", category: .guess(from: "electricity"), due: today)])
            }
        default: return nil
        }
    }

    private func percentile(_ s: [Double], _ p: Double) -> Double {
        let v = s.sorted()
        return v.isEmpty ? 0 : v[min(v.count - 1, Int(Double(v.count - 1) * p + 0.5))]
    }

    // MARK: The run

    func testTheScoreboardOnTheRealModel() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["KITTY_REAL_MODEL"] == "1", "real-model scoreboard: set TEST_RUNNER_KITTY_REAL_MODEL=1")
        guard case .available = SystemLanguageModel.default.availability else { throw XCTSkip("the on-device model is not available") }
        let runs = max(1, Int(env["KITTY_REAL_RUNS"] ?? "") ?? 3)
        let wanted = env["KITTY_SCOREBOARD_CASES"].map { Set($0.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }) }
        let out = env["KITTY_SCOREBOARD_OUT"] ?? NSTemporaryDirectory() + "scoreboard_report.md"
        let file = env["KITTY_SCOREBOARD_FILE"] ?? "/Users/nareshpeddinti/Documents/Kitty/Tests/Scoreboard/scoreboard_v1.json"
        let data = try Data(contentsOf: URL(fileURLWithPath: file))
        let top = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let cases = try XCTUnwrap(top["cases"] as? [[String: Any]])

        var rows = "", samples = ""
        var groupPass: [String: Int] = [:], groupTotal: [String: Int] = [:]
        var allSeconds: [Double] = []
        var passed = 0, total = 0, silent = 0
        for c in cases {
            guard let id = c["id"] as? String, wanted?.contains(id) ?? true else { continue }
            let group = c["group"] as? String ?? "?"
            let expected = c["expected"] as? [String: Any] ?? [:]
            var verdicts: [SBVerdict] = []
            var detail = ""
            let said: String
            if let turnsSaid = c["turns"] as? [String] {
                said = turnsSaid.joined(separator: "  ⏎  ")
                for n in 0..<runs {
                    let r = await runMulti(id, turnsSaid, setup: multiSetup(id))
                    verdicts.append(r.verdict)
                    allSeconds += r.outcomes.map(\.seconds)
                    let shown = r.outcomes.enumerated().map { k, o in
                        "turn \(k + 1) (\(o.kind), \(String(format: "%.1f", o.seconds)) s): " + (o.items.isEmpty ? o.text : o.items.map(describe).joined(separator: " | "))
                    }.joined(separator: "\n      ")
                    detail += "- run \(n + 1): \(r.verdict.pass ? "ok" : "FAIL: " + r.verdict.fails.joined(separator: "; "))\n      \(shown)\n"
                    if r.outcomes.last?.kind == "wait" { silent += 1 }
                }
            } else {
                said = c["voice_input"] as? String ?? ""
                for n in 0..<runs {
                    let o = await run(manager(), said)
                    let v = score(expected, o)
                    verdicts.append(v)
                    allSeconds.append(o.seconds)
                    if o.kind == "wait", (expected["outcome"] as? String) != "wait", (expected["outcome"] as? String) != "none" { silent += 1 }
                    let shown = o.items.isEmpty ? "(\(o.kind)) \(o.text)" : o.items.map(describe).joined(separator: " | ")
                    detail += "- run \(n + 1): \(v.pass ? "ok" : "FAIL: " + v.fails.joined(separator: "; ")) (\(o.kind), \(String(format: "%.1f", o.seconds)) s)\n      \(shown)\n"
                    if !v.manual.isEmpty { detail += "      manual: \(v.manual.joined(separator: "; "))\n" }
                    if env["KITTY_SCOREBOARD_TRACE"] == "1", !v.pass, !o.trace.isEmpty { detail += "      trace:\n        \(o.trace)\n" }
                    if (n == 0 || !v.pass), !o.raw.isEmpty { detail += "      model wrote: \(o.raw.replacingOccurrences(of: "\n", with: " ").prefix(600))\n" }
                }
            }
            let ok = verdicts.filter(\.pass).count
            passed += ok; total += runs
            groupPass[group, default: 0] += ok; groupTotal[group, default: 0] += runs
            rows += "| \(id) | \(group) | \(said.replacingOccurrences(of: "|", with: "/").prefix(90)) | \(ok)/\(runs) |\n"
            samples += "### \(id) (\(group)): \"\(said)\"\n\(detail)\n"
            let head = "# Kitty scoreboard report (partial)\n\nTime zone: \(TimeZone.current.identifier). Profile: app default (flat). Runs per case: \(runs).\n\n| case | group | input | passes |\n|---|---|---|---|\n"
            try? (head + rows + "\n## Samples (so far)\n\n" + samples).write(toFile: out, atomically: true, encoding: .utf8)
        }
        var summary = "# Kitty scoreboard report\n\nTime zone: \(TimeZone.current.identifier). Profile: app default (flat). Runs per case: \(runs). Reference time: 2026-10-28 12:00 IST.\n\n"
        summary += "**First-try pass rate: \(passed)/\(total)** (\(total == 0 ? 0 : passed * 100 / total)%). Silent turns (nothing shown when something was due): \(silent). "
        summary += "Model time per turn: median \(String(format: "%.1f", percentile(allSeconds, 0.5))) s, 90th percentile \(String(format: "%.1f", percentile(allSeconds, 0.9))) s, worst \(String(format: "%.1f", allSeconds.max() ?? 0)) s.\n\n"
        summary += "## By group\n\n| group | passed | of |\n|---|---|---|\n"
        for g in groupTotal.keys.sorted() { summary += "| \(g) | \(groupPass[g] ?? 0) | \(groupTotal[g] ?? 0) |\n" }
        summary += "\n## By case\n\n| case | group | input | passes |\n|---|---|---|---|\n" + rows + "\n## Samples\n\n" + samples
        try? summary.write(toFile: out, atomically: true, encoding: .utf8)
        print("SCOREBOARD REPORT: \(out)")
    }
}

#endif
