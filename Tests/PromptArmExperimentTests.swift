import XCTest
#if canImport(FoundationModels)
import FoundationModels
#endif
@testable import Kitty

// Which prompt and schema makes the real model split one sentence into several tasks? Skipped unless TEST_RUNNER_KITTY_REAL_MODEL=1.
//   TEST_RUNNER_KITTY_REAL_RUNS=6     runs per sentence per arm (default 6)
//   TEST_RUNNER_KITTY_ARMS_OUT=/tmp/arms_report.md
// Every sentence below is ONE task. The model alone is asked (no Swift checks), so this shows what the model writes. It MEASURES:
// the app applies none of it.

#if canImport(FoundationModels)

/// The extraction schema as it was before the response-level person, day and time and `leavesScope` were added (schema 9196c691).
@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
@Generable
struct OldTaskExtraction {
    @Guide(description: "create, clarify, or wait")
    var outcome: ExtractionOutcome

    @Guide(description: "Name of the list, order or cart the user said these tasks go on, as they said it, or a clearly described collection. Omit for standalone tasks")
    var listName: String?

    @Guide(description: "One essential clarification question, or omit")
    var question: String?

    @Guide(.maximumCount(12))
    var tasks: [TaskDraft]
}

private struct ArmRow {
    var titles: [String]
    var list: String?
    var assignee: String?
    var day: String?
    var schedule: String? = nil
    var instructions: String? = nil
    var error: String?
}

@MainActor
final class PromptArmExperimentTests: XCTestCase {
    /// The base text of `TaskExtractionInstructions`, without the optional lines.
    private static let base = """
    Extract tasks from the user request. A task is one independently
    completable action or target.

    Return only context the user provided. Never invent values, tasks,
    substeps, dates, times, people, places, vendors, quantities, or metadata.

    Use title for a concise action plus specific target.

    Use schedule only when repetition is requested. Preserve the complete
    stated recurrence, including days, intervals, and exceptions. Do not
    convert a recurring request into multiple one-time tasks.

    Use purpose for a user-stated reason, event, or goal.
    Use instructions for user-stated quantity, dosage, variant, preference,
    method, or constraint.
    Do not duplicate the same user text in both fields.
    Leave optional fields empty when not provided.

    Use listName when the user says the tasks go on, in or to a list, order
    or cart, or names one ("to the Blinkit order", "my pharmacy list"), or
    clearly describes one collection. Write the name the way the user said
    it. Leave it empty for standalone tasks. A list does not imply sequence.

    Ask at most one focused question, and only when a missing detail prevents
    a usable task: unclear target, required dosage or quantity, or an
    unresolvable repetition rule.

    Do not ask for category, labels, purpose, location, vendor, or optional
    metadata. Do not ask for a time when only a date was given. Do not ask
    for a date when only a soft timeframe was given.

    Return create when drafts are usable.
    Return clarify when one essential question is needed.
    Return wait when no new task should be proposed.
    """

    private static let sentences = [
        "I want to order food from Swiggy today.",
        "I need to call the plumber tomorrow.",
        "I want to buy winter wear today",
        "I have to book a cab to the airport tomorrow",
        "order food from Swiggy",
        "call the school tomorrow morning about the fee receipt",
        "I want to order groceries from Blinkit today.",
        "I want to pick up the dry cleaning on Saturday.",
    ]

    private func newRow(_ said: String, instructions: String) async -> ArmRow {
        do {
            let session = LanguageModelSession(instructions: instructions)
            let r = try await session.respond(to: FlatPrompt.build(words: said), generating: TaskExtraction.self).content
            let list = (r.listName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return ArmRow(titles: r.tasks.map(\.title), list: list.isEmpty ? nil : list,
                          assignee: r.tasks.compactMap(\.assignee).first, day: r.tasks.compactMap(\.dueDate).first)
        } catch {
            return ArmRow(titles: [], list: nil, assignee: nil, day: nil, error: String(String(describing: error).prefix(70)))
        }
    }

    private func oldRow(_ said: String, instructions: String) async -> ArmRow {
        do {
            let session = LanguageModelSession(instructions: instructions)
            let r = try await session.respond(to: FlatPrompt.build(words: said), generating: OldTaskExtraction.self).content
            let list = (r.listName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return ArmRow(titles: r.tasks.map(\.title), list: list.isEmpty ? nil : list,
                          assignee: r.tasks.compactMap(\.assignee).first, day: r.tasks.compactMap(\.dueDate).first,
                          schedule: r.tasks.compactMap(\.schedule).first, instructions: r.tasks.compactMap(\.instructions).first)
        } catch {
            return ArmRow(titles: [], list: nil, assignee: nil, day: nil, error: String(String(describing: error).prefix(70)))
        }
    }

    func testWhichPromptSplitsOneSentenceIntoSeveralTasks() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["KITTY_REAL_MODEL"] == "1", "set TEST_RUNNER_KITTY_REAL_MODEL=1")
        guard case .available = SystemLanguageModel.default.availability else { throw XCTSkip("the on-device model is not available") }
        let runs = max(1, Int(env["KITTY_REAL_RUNS"] ?? "") ?? 6)
        let out = env["KITTY_ARMS_OUT"] ?? NSTemporaryDirectory() + "arms_report.md"

        let correction = FlatExperiments.correctionText, separate = FlatExperiments.separateTargetsText, scope = FlatExperiments.scopeText
        let noScope = [Self.base, correction, separate].joined(separator: "\n\n")
        let arms: [(String, (String) async -> ArmRow)] = [
            ("A: old schema + base/correction/separate (before the scope work)", { await self.oldRow($0, instructions: noScope) }),
            ("B: new schema + base/correction/separate (no scope line)", { await self.newRow($0, instructions: noScope) }),
            ("C: new schema + all lines (today)", { await self.newRow($0, instructions: TaskExtractionInstructions.text) }),
            ("D: new schema + base only", { await self.newRow($0, instructions: Self.base) }),
            ("E: new schema + base + scope line only", { await self.newRow($0, instructions: [Self.base, scope].joined(separator: "\n\n")) }),
        ]

        var report = "# Prompt arms: does one sentence stay one task?\n\nEvery sentence is a single task. \(runs) runs each, \(Self.sentences.count) sentences, model only (no Swift checks).\n\n"
        var table = "| arm | exactly one task | more than one task | a list set | a person set | errors |\n|---|---|---|---|---|---|\n"
        var samples = ""
        for (name, run) in arms {
            var total = 0, one = 0, many = 0, list = 0, who = 0, errors = 0
            var examples: [String] = []
            for said in Self.sentences {
                for _ in 0..<runs {
                    let r = await run(said)
                    total += 1
                    if r.error != nil { errors += 1; continue }
                    if r.titles.count == 1 { one += 1 } else { many += 1; if examples.count < 6 { examples.append("“\(said)” → \(r.titles.map { "‘\($0)’" }.joined(separator: ", "))") } }
                    if r.list != nil { list += 1 }
                    if r.assignee != nil { who += 1 }
                }
            }
            table += "| \(name) | \(one)/\(total) | \(many) | \(list) | \(who) | \(errors) |\n"
            samples += "### \(name)\n" + (examples.isEmpty ? "- no split\n" : examples.map { "- \($0)\n" }.joined()) + "\n"
            try? (report + table + "\n" + samples).write(toFile: out, atomically: true, encoding: .utf8)
        }
        try? (report + table + "\n## Examples of splits\n\n" + samples).write(toFile: out, atomically: true, encoding: .utf8)
        print("ARMS REPORT: \(out)")
    }

    // MARK: Evidence wording (old schema)

    private static let listParagraphWithExamples = """
    Use listName when the user says the tasks go on, in or to a list, order
    or cart, or names one ("to the Blinkit order", "my pharmacy list"), or
    clearly describes one collection. Write the name the way the user said
    it. Leave it empty for standalone tasks. A list does not imply sequence.
    """
    private static let listParagraphEvidence = """
    Use listName only when the user says the tasks go on, in or to a list,
    order or cart, or names one. Write the name the way the user said it.
    Leave it empty for standalone tasks. A list does not imply sequence.
    """
    private static let evidenceLine = "Fill a field only with words the user said for that task. If the user did not say it, leave the field out. Never guess a person, day, time, list, reason or quantity, and never use a word from these instructions as a value."

    private struct Control { var said: String; var check: (ArmRow) -> Bool }

    func testEvidenceWordingOnTheOldSchema() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["KITTY_REAL_MODEL"] == "1", "set TEST_RUNNER_KITTY_REAL_MODEL=1")
        guard case .available = SystemLanguageModel.default.availability else { throw XCTSkip("the on-device model is not available") }
        let runs = max(1, Int(env["KITTY_REAL_RUNS"] ?? "") ?? 5)
        let out = env["KITTY_ARMS_OUT2"] ?? NSTemporaryDirectory() + "arms_report2.md"

        let correction = FlatExperiments.correctionText, separate = FlatExperiments.separateTargetsText
        let a0 = [Self.base, correction, separate].joined(separator: "\n\n")
        let baseNoExamples = Self.base.replacingOccurrences(of: Self.listParagraphWithExamples, with: Self.listParagraphEvidence)
        XCTAssertNotEqual(baseNoExamples, Self.base, "the list paragraph must be found")
        let a1 = [baseNoExamples, correction, separate].joined(separator: "\n\n")
        let a2 = a0 + "\n\n" + Self.evidenceLine
        let a3 = a1 + "\n\n" + Self.evidenceLine
        let arms: [(String, String)] = [
            ("A0: previous instructions (base, correction, separate)", a0),
            ("A1: A0 without the example list names", a1),
            ("A2: A0 plus the evidence sentence", a2),
            ("A3: A1 plus the evidence sentence", a3),
        ]
        let dayWords = ["today", "tomorrow", "saturday"]
        let controls: [Control] = [
            Control(said: "add milk and bread to the Blinkit order", check: { $0.titles.count == 2 && ($0.list ?? "").lowercased().contains("blinkit") }),
            Control(said: "pharmacy list Cipcal Tedibar and Cetaphil body lotion", check: { $0.titles.count == 3 && ($0.list ?? "").lowercased().contains("pharmacy") }),
            Control(said: "ask Rani to clean the baby mat tomorrow", check: { ($0.assignee ?? "").lowercased().contains("rani") && $0.day != nil }),
            Control(said: "water the plants every morning", check: { $0.schedule != nil }),
            Control(said: "give papa his BP tablet every night after dinner half a tablet", check: { $0.schedule != nil && $0.instructions != nil }),
        ]
        var report = "# Evidence wording on the old schema\n\nSingle-task sentences (\(Self.sentences.count)) and controls (\(controls.count)), \(runs) runs each, model only.\n\n"
        var table = "| arm | one task | a list invented | a person invented | day captured | controls passed |\n|---|---|---|---|---|---|\n"
        for (name, instructions) in arms {
            var total = 0, one = 0, list = 0, who = 0, dayTotal = 0, dayHit = 0, errors = 0
            for said in Self.sentences {
                for _ in 0..<runs {
                    let r = await oldRow(said, instructions: instructions)
                    total += 1
                    if r.error != nil { errors += 1; continue }
                    if r.titles.count == 1 { one += 1 }
                    if r.list != nil { list += 1 }
                    if r.assignee != nil { who += 1 }
                    if dayWords.contains(where: { said.lowercased().contains($0) }) { dayTotal += 1; if r.day != nil { dayHit += 1 } }
                }
            }
            var ctlPass = 0, ctlTotal = 0
            var detail: [String] = []
            for c in controls {
                var ok = 0
                for _ in 0..<runs {
                    let r = await oldRow(c.said, instructions: instructions)
                    ctlTotal += 1
                    if r.error == nil, c.check(r) { ctlPass += 1; ok += 1 }
                }
                detail.append("\(c.said.prefix(28)): \(ok)/\(runs)")
            }
            table += "| \(name) | \(one)/\(total) | \(list) | \(who) | \(dayHit)/\(dayTotal) | \(ctlPass)/\(ctlTotal) (\(detail.joined(separator: "; "))) |\n"
            try? (report + table).write(toFile: out, atomically: true, encoding: .utf8)
        }
        print("ARMS REPORT 2: \(out)")
    }
}

#endif
