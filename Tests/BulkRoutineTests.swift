import XCTest
@testable import Kitty

// Bulk routine utterances ("every morning water the plants, every evening lock the doors ..."): do they reach the bulk path,
// does the preview hold every routine with its schedule and person, and does saving them work.

@MainActor
final class BulkRoutineProbe: XCTestCase {
    private struct WaitingEngine: DecisionProviding {
        func decide(prompt: String) async -> AgentDecisionValue? { AgentDecisionValue(wait: true, action: "wait") }
        func decideBulk(prompt: String) async -> BulkDecisionValue? { BulkDecisionValue(action: "wait") }
    }
    private static let now = LongTurnAnalyzerTests.now

    static let utterances = [
        "Every morning water the plants, every evening lock the doors and every Sunday clean the fridge",
        "Daily take out the trash, weekly mop the floors, monthly pay the electricity bill",
        "The maid should sweep every day and mop every Saturday",
        "Every day the maid sweeps and mops",
        "Water the plants every morning and lock the doors every night",
        "Every day: sweep the floors, wash the dishes, take out the trash",
        "Um so it has been a crazy week you know but water the plants every morning and clean the fridge every Sunday",
    ]

    func testProbe() async {
        var out = ""
        for said in Self.utterances {
            out += "=== \(said)\n"
            out += "gate: \(VoiceTurnManager.gate(utterance: said, silence: 2.0, lastActed: ""))\n"
            let a = BulkDetector.analyze(said, now: Self.now)
            out += "analysis: \(a.kind) segments=\(a.segments) long=\(a.turn != nil)\n"
            for mode in ["none", "wait", "bulk"] {
                let sink = InMemorySaveSink()
                let engine: DecisionProviding
                switch mode {
                case "wait": engine = WaitingEngine()
                case "bulk": engine = BulkQueueEngine([Self.scriptedRoutines(for: said)])
                default: engine = BulkQueueEngine([])
                }
                let m = VoiceTurnManager(engine: engine, sink: sink, knownCategories: { [] }, knownAssignees: { [] })
                m.ruleFallbackEnabled = true
                let r = await m.decide(utterance: said, now: Self.now)
                out += "  [\(mode)] route=\(m.lastTrace.route) calls=\(m.lastTrace.modelCallCount) result="
                switch r {
                case .proposal(let p):
                    out += "proposal \"\(p.title)\" prompt=\(p.prompt ?? "-")\n"
                    for row in p.rows { out += "      row: \(row.icon) \(row.title) | \(row.tags.map(\.text).joined(separator: ", "))\n" }
                    let reply = await p.apply()
                    out += "      saved: \(reply.message) | tasks=\(sink.tasks.map(\.title)) routines=\(sink.routines.map { "\($0.title) [\($0.recurrence?.scheduleText ?? "nil")] \($0.assignee ?? "-")" })\n"
                case .question(let q): out += "question \(q)\n"
                case .reply(let rep): out += "reply \(rep.message)\n"
                case .wait: out += "wait\n"
                }
                out += "      validation: \(m.lastTrace.validation ?? "-")\n"
            }
        }
        try? out.write(toFile: "/tmp/routine-probe-out.txt", atomically: true, encoding: .utf8)
        print(out)
    }

    static func scriptedRoutines(for said: String) -> BulkDecisionValue {
        var b = BulkDecisionValue(action: "create_routines")
        switch said {
        case utterances[0]:
            b.routines = [RoutineDraftValue(title: "Water the plants", frequency: "daily", schedule: "every morning"),
                          RoutineDraftValue(title: "Lock the doors", frequency: "daily", schedule: "every evening"),
                          RoutineDraftValue(title: "Clean the fridge", frequency: "weekly", schedule: "every Sunday")]
        case utterances[1]:
            b.routines = [RoutineDraftValue(title: "Take out the trash", frequency: "daily", schedule: "daily"),
                          RoutineDraftValue(title: "Mop the floors", frequency: "weekly", schedule: "weekly"),
                          RoutineDraftValue(title: "Pay the electricity bill", frequency: "monthly", schedule: "monthly")]
        case utterances[2]:
            b.routines = [RoutineDraftValue(title: "Sweep", frequency: "daily", schedule: "every day", assignee: "Househelp"),
                          RoutineDraftValue(title: "Mop", frequency: "weekly", schedule: "every Saturday", assignee: "Househelp")]
        default:
            b.routines = []
        }
        return b
    }
}
