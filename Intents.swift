import AppIntents

// Kitty's Siri / Spotlight / Shortcuts / Action Button actions. Each one opens the app in the voice conversation:
//  - Talk to Kitty and Add a task: start listening.
//  - Tasks for today / tomorrow, Overdue tasks: Kitty runs that question itself, speaks the answer and listens on.
//  - Tell Kitty: Siri asks what to tell Kitty, then Kitty runs those words.
// Everything else (adding, completing, moving...) happens by talking inside the conversation.

/// The words Kitty runs for the ready-made questions, as if you had said them.
enum KittySiriRequest {
    static let tasksToday = "What are my tasks for today"
    static let tasksTomorrow = "What are my tasks for tomorrow"
    static let overdue = "What is overdue"
}

struct TalkToKittyIntent: AppIntent {
    static let title: LocalizedStringResource = "Talk to Kitty"
    static let description = IntentDescription("Opens Kitty and starts listening.")
    static let openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        LaunchRouter.shared.requestConversation()
        return .result()
    }
}

struct AddTaskInKittyIntent: AppIntent {
    static let title: LocalizedStringResource = "Add a task in Kitty"
    static let description = IntentDescription("Opens Kitty and starts listening, ready for you to say the task.")
    static let openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        LaunchRouter.shared.requestConversation()
        return .result()
    }
}

struct TasksTodayIntent: AppIntent {
    static let title: LocalizedStringResource = "Today's tasks in Kitty"
    static let description = IntentDescription("Opens Kitty and reads out your tasks for today.")
    static let openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        LaunchRouter.shared.requestConversation(request: KittySiriRequest.tasksToday)
        return .result()
    }
}

struct TasksTomorrowIntent: AppIntent {
    static let title: LocalizedStringResource = "Tomorrow's tasks in Kitty"
    static let description = IntentDescription("Opens Kitty and reads out your tasks for tomorrow.")
    static let openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        LaunchRouter.shared.requestConversation(request: KittySiriRequest.tasksTomorrow)
        return .result()
    }
}

struct OverdueTasksIntent: AppIntent {
    static let title: LocalizedStringResource = "Overdue tasks in Kitty"
    static let description = IntentDescription("Opens Kitty and reads out what is overdue.")
    static let openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        LaunchRouter.shared.requestConversation(request: KittySiriRequest.overdue)
        return .result()
    }
}

/// Siri cannot take free words inside a phrase, so it asks for them: "Hey Siri, tell Kitty" ... "What should I tell Kitty?"
struct TellKittyIntent: AppIntent {
    static let title: LocalizedStringResource = "Tell Kitty"
    static let description = IntentDescription("Tell Kitty something to add or ask. Kitty opens and does it.")
    static let openAppWhenRun: Bool = true

    @Parameter(title: "What should I tell Kitty?",
               requestValueDialog: IntentDialog("What should I tell Kitty?"))
    var request: String

    @MainActor
    func perform() async throws -> some IntentResult {
        LaunchRouter.shared.requestConversation(request: request)
        return .result()
    }
}

struct QuickTasksShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: TalkToKittyIntent(),
            phrases: [
                "Talk to \(.applicationName)",
                "Speak to \(.applicationName)",
                "Chat with \(.applicationName)",
                "Hey \(.applicationName)",
                "Hi \(.applicationName)",
                "Hello \(.applicationName)",
                "Ask \(.applicationName)",
                "Start \(.applicationName)",
                "Open \(.applicationName) and listen"
            ],
            shortTitle: "Talk to Kitty",
            systemImageName: "mic.fill"
        )
        AppShortcut(
            intent: AddTaskInKittyIntent(),
            phrases: [
                "Add a task in \(.applicationName)",
                "Add a task to \(.applicationName)",
                "Add a task on \(.applicationName)",
                "Add a task with \(.applicationName)",
                "Add a task using \(.applicationName)",
                "Add task in \(.applicationName)",
                "Add a new task in \(.applicationName)",
                "Add another task in \(.applicationName)",
                "Create a task in \(.applicationName)",
                "Create a new task in \(.applicationName)",
                "Make a task in \(.applicationName)",
                "New task in \(.applicationName)",
                "Add a reminder in \(.applicationName)",
                "Add a to do in \(.applicationName)",
                "Add something in \(.applicationName)",
                "I want to add a task in \(.applicationName)",
                "I need to add a task in \(.applicationName)",
                "Can you add a task in \(.applicationName)"
            ],
            shortTitle: "Add a task",
            systemImageName: "plus.circle.fill"
        )
        AppShortcut(
            intent: TasksTodayIntent(),
            phrases: [
                "What are my tasks for today in \(.applicationName)",
                "What are my tasks today in \(.applicationName)",
                "What is on my list today in \(.applicationName)",
                "What do I have today in \(.applicationName)",
                "Show my tasks for today in \(.applicationName)",
                "Read my tasks for today in \(.applicationName)",
                "Today's tasks in \(.applicationName)",
                "My tasks for today in \(.applicationName)"
            ],
            shortTitle: "Today's tasks",
            systemImageName: "sun.max.fill"
        )
        AppShortcut(
            intent: TasksTomorrowIntent(),
            phrases: [
                "What are my tasks for tomorrow in \(.applicationName)",
                "What are my tasks tomorrow in \(.applicationName)",
                "What do I have tomorrow in \(.applicationName)",
                "Show my tasks for tomorrow in \(.applicationName)",
                "Read my tasks for tomorrow in \(.applicationName)",
                "Tomorrow's tasks in \(.applicationName)"
            ],
            shortTitle: "Tomorrow's tasks",
            systemImageName: "calendar"
        )
        AppShortcut(
            intent: OverdueTasksIntent(),
            phrases: [
                "What is overdue in \(.applicationName)",
                "What tasks are overdue in \(.applicationName)",
                "Show my overdue tasks in \(.applicationName)",
                "Overdue tasks in \(.applicationName)"
            ],
            shortTitle: "Overdue tasks",
            systemImageName: "exclamationmark.triangle.fill"
        )
        AppShortcut(
            intent: TellKittyIntent(),
            phrases: [
                "Tell \(.applicationName)",
                "Tell \(.applicationName) something"
            ],
            shortTitle: "Tell Kitty",
            systemImageName: "text.bubble.fill"
        )
    }
}
