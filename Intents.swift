import AppIntents

// Kitty's only Siri / Spotlight / Shortcuts / Action Button action: open the app and start listening.
// Everything else (adding, asking, completing, moving...) happens by talking inside the conversation.

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
                "Start \(.applicationName)"
            ],
            shortTitle: "Talk to Kitty",
            systemImageName: "mic.fill"
        )
    }
}
