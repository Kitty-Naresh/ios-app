import XCTest
@testable import Kitty

/// "Add a task for the project" must ask what the task is, never create a task titled "Project".
@MainActor
final class VaguePlaceholderTests: XCTestCase {
    private func decision(_ action: String, title: String = "", question: String = "", wait: Bool = false) -> AgentDecisionValue {
        AgentDecisionValue(wait: wait, action: action, title: title, category: "", dueDate: "", dueTime: "", priority: "",
                           assignee: "", frequency: "", notes: "", playbookName: "", playbookSteps: [], clarifyingQuestion: question,
                           spokenResponse: "", moreTasks: [])
    }

    func testExploreRoutes() async {
        let utterances = ["add a task for the project", "add a task for the project work", "add a task about the project", "add a task for it",
                          "create a task for that thing", "add a task for something"]
        for title in ["Project", "Project task", "The project", ""] {
            for u in utterances {
                for fallback in [true, false] {
                    let engine = ScriptedEngine([title.isEmpty ? nil : decision("create_task", title: title)])
                    let m = VoiceTurnManager(engine: engine, sink: InMemorySaveSink(), knownCategories: { [] }, knownAssignees: { [] })
                    m.ruleFallbackEnabled = fallback
                    let r = await m.decide(utterance: u, final: true)
                    print("EXPLORE model=\(title.isEmpty ? "none" : title) fb=\(fallback) [\(u)] -> \(m.lastTrace.route) | \(VoiceTurnManager.describe(r))")
                }
            }
        }
    }
}
