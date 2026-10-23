import SwiftUI
import AppIntents
#if os(iOS)
import UIKit
#endif

#if os(iOS)
/// Long-press the Kitty icon on the Home Screen and choose "Talk to Kitty".
enum KittyQuickAction {
    static let talkType = "kitty.talk"

    static func install() {
        UIApplication.shared.shortcutItems = [
            UIApplicationShortcutItem(type: talkType,
                                      localizedTitle: "Talk to Kitty",
                                      localizedSubtitle: nil,
                                      icon: UIApplicationShortcutIcon(systemImageName: "mic.fill"),
                                      userInfo: nil)
        ]
    }

    @discardableResult
    static func handle(_ item: UIApplicationShortcutItem) -> Bool {
        guard item.type == talkType else { return false }
        Task { @MainActor in LaunchRouter.shared.requestConversation() }
        return true
    }
}

final class KittyAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        if let item = options.shortcutItem { KittyQuickAction.handle(item) }   // the app was launched from the icon menu
        let config = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        config.delegateClass = KittySceneDelegate.self
        return config
    }
}

final class KittySceneDelegate: NSObject, UIWindowSceneDelegate {
    func windowScene(_ windowScene: UIWindowScene,
                     performActionFor shortcutItem: UIApplicationShortcutItem,
                     completionHandler: @escaping (Bool) -> Void) {
        completionHandler(KittyQuickAction.handle(shortcutItem))
    }
}
#endif

@main
struct QuickTasksApp: App {
    @StateObject private var store = TaskStore.shared
    #if os(iOS)
    @UIApplicationDelegateAdaptor(KittyAppDelegate.self) private var appDelegate
    #endif

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .tint(Color.indigo)
                .task {
                    #if os(iOS)
                    KittyQuickAction.install()
                    #endif
                    store.refreshRoutines()
                    // The accurate speech model takes a while to load, so start it now rather than when the mic opens.
                    if SpeechEngineChoice.effective() == .whisperTurbo {
                        WhisperAccurate.shared.prepare(keyTerms: KeyTerms.build(household: VocabularyProvider.current()))
                        WhisperAccurate.shared.unloadSoon()      // let go again if the conversation is not opened
                    }
                    await TaskAgent.classifyUntimed()
                }
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var store: TaskStore
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var convo = VoiceConversation()
    @ObservedObject private var router = LaunchRouter.shared
    @StateObject private var wake = WakeWordListener()
    @AppStorage("kitty.heyKittyInApp") private var heyKitty = false
    @State private var showConversation = false
    @State private var seedText: String?
    @State private var showTasks = false
    @State private var showLibrary = false
    @State private var query = ""
    @FocusState private var queryFocused: Bool

    private var openCount: Int { store.tasks.filter { !$0.isDone }.count }
    private var overdueCount: Int { store.tasks.filter(\.isOverdue).count }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.screenBackground.ignoresSafeArea()
                VStack(spacing: 30) {
                    Spacer()
                    VStack(spacing: 6) {
                        Text("Kitty")
                            .font(.system(size: 54, weight: .bold, design: .rounded))
                        Text("What can I do for you?")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                        wakeStatus
                    }
                    talkButton
                    searchBar
                    Spacer()
                    allTasksButton
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { showLibrary = true } label: {
                            Label("Routines, playbooks & guide", systemImage: "repeat")
                        }
                        Button { _ = store.clearCompleted() } label: {
                            Label("Clear completed", systemImage: "checkmark.circle")
                        }
                        Toggle(isOn: $heyKitty) {
                            Label("Listen for “Hey Kitty” while open", systemImage: "ear")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .onAppear {
                store.refreshRoutines()
                wake.onWake = { openFromWake() }
                openIfRequested()
                updateWake()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    store.refreshRoutines()
                    Task { await TaskAgent.classifyUntimed() }
                    openIfRequested()
                }
                updateWake()
            }
            // Siri ("Hey Siri, talk to Kitty"), the Action Button or Back Tap asked for the conversation.
            .onChange(of: router.conversationRequested) { _, _ in openIfRequested() }
            .onChange(of: heyKitty) { _, _ in updateWake() }
            .onChange(of: showConversation) { _, _ in updateWake() }
            .onChange(of: showTasks) { _, _ in updateWake() }
            .onChange(of: showLibrary) { _, _ in updateWake() }
            .fullScreenCover(isPresented: $showConversation, onDismiss: { seedText = nil }) {
                ConversationView(convo: convo, seed: seedText)
            }
            .sheet(isPresented: $showTasks) {
                TasksView(filter: PanelFilter(who: .all, category: nil, day: .all, status: .all))
            }
            .sheet(isPresented: $showLibrary) { LibraryView() }
        }
    }

    /// When "Hey Kitty" is on, always say what it is doing and what it heard.
    @ViewBuilder
    private var wakeStatus: some View {
        if heyKitty {
            VStack(spacing: 2) {
                if wake.isListening {
                    Label("Say “Hey Kitty”", systemImage: "ear")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                    if !wake.heard.isEmpty {
                        Text("Heard: “\(wake.heard)”")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                } else if let error = wake.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                } else {
                    Text("Starting “Hey Kitty”…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 4)
        }
    }

    // MARK: The one big thing: talk to Kitty

    private var talkButton: some View {
        Button { startConversation(seed: nil) } label: {
            VStack(spacing: 14) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 112, height: 112)
                    .background(Color.accentColor.gradient, in: Circle())
                    .shadow(color: Color.accentColor.opacity(0.4), radius: 18, y: 8)
                Text("Talk to Kitty")
                    .font(.headline)
                    .foregroundStyle(Color.primary)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: Type a task or a question

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Type a task or ask Kitty", text: $query)
                .focused($queryFocused)
                .submitLabel(.send)
                .onSubmit { submitQuery() }
            if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Button { submitQuery() } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.title2)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(Color.cardBackground, in: Capsule())
        .shadow(color: .black.opacity(0.06), radius: 8, y: 2)
    }

    private func submitQuery() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        query = ""
        startConversation(seed: text)
    }

    private func startConversation(seed: String?) {
        queryFocused = false
        seedText = seed
        showConversation = true
    }

    private func openIfRequested() {
        guard router.conversationRequested else { return }
        router.conversationRequested = false
        guard !showConversation else { return }
        if showTasks || showLibrary {
            // A sheet is open: close it first, then open the conversation once it is gone.
            showTasks = false
            showLibrary = false
            Task {
                try? await Task.sleep(nanoseconds: 600_000_000)
                startConversation(seed: nil)
            }
        } else {
            startConversation(seed: nil)
        }
    }

    private func openFromWake() {
        guard !showConversation else { return }
        startConversation(seed: nil)
    }

    /// "Hey Kitty" listens only when it is turned on, the app is in front, and nothing else is open.
    private func updateWake() {
        let shouldListen = heyKitty && scenePhase == .active && !showConversation && !showTasks && !showLibrary
        if shouldListen { wake.start() } else { wake.stop() }
    }

    // MARK: Quiet way into the list

    private var allTasksButton: some View {
        Button { showTasks = true } label: {
            HStack(spacing: 8) {
                Image(systemName: "list.bullet")
                Text("Show all tasks")
                if openCount > 0 {
                    Text("\(openCount)").foregroundStyle(.secondary)
                }
                if overdueCount > 0 {
                    TagPill(text: "\(overdueCount) overdue", icon: "exclamationmark.triangle.fill", color: .red, filled: true)
                }
            }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(Color.cardBackground, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Routines, playbooks and diagnostics, kept out of the way of the daily list.
struct LibraryView: View {
    @ObservedObject private var store = TaskStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var crumbs: [String] = Breadcrumb.lines
    @State private var showSiriTip = true

    var body: some View {
        NavigationStack {
            List {
                #if os(iOS)
                Section {
                    SiriTipView(intent: TalkToKittyIntent(), isVisible: $showSiriTip)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
                #endif

                Section("Routines") {
                    if store.routines.isEmpty {
                        Text("None yet. Say: “Every day the maid sweeps and mops.”")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(store.routines) { r in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(r.title).font(.body.weight(.medium))
                            FlowLayout(spacing: 6) {
                                TagPill(text: r.scheduleText.prefix(1).uppercased() + r.scheduleText.dropFirst(),
                                        icon: "repeat", color: .purple)
                                TagPill(text: r.effectiveAssignee, icon: "person.fill",
                                        color: Assignee.color(for: r.effectiveAssignee))
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .onDelete(perform: store.removeRoutines)
                }

                Section("Lists") {
                    if store.profiles.isEmpty {
                        Text("None yet. Say: “Add milk to my Blinkit order.” Kitty makes the list the first time you mention it.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(store.profiles) { list in
                        let items = store.items(in: list)
                        HStack(spacing: 10) {
                            Image(systemName: list.symbol).foregroundStyle(.orange).frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(list.name).font(.body.weight(.medium))
                                Text("\(items.filter { !$0.isDone }.count) open · \(items.count) items")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onDelete { offsets in
                        let ids = offsets.map { store.profiles[$0].id }
                        ids.forEach { store.removeProfile($0, deleteItems: true) }
                    }
                }

                Section("Playbooks") {
                    if store.playbooks.isEmpty {
                        Text("None yet. Say: “Here’s how I make biryani…” and list the steps and who does them.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(store.playbooks) { pb in
                        DisclosureGroup {
                            ForEach(Array(pb.steps.enumerated()), id: \.offset) { index, step in
                                HStack(spacing: 8) {
                                    Text("\(index + 1).").foregroundStyle(.secondary)
                                    Text(step.title)
                                    Spacer()
                                    if let who = step.assignee {
                                        TagPill(text: who, icon: "person.fill", color: Assignee.color(for: who))
                                    }
                                }
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(pb.name).font(.body.weight(.medium))
                                Text("\(pb.steps.count) tasks").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onDelete { offsets in
                        let ids = offsets.map { store.playbooks[$0].id }
                        ids.forEach { store.removePlaybook($0) }
                    }
                }

                Section("Kitty guide") {
                    NavigationLink {
                        GuideEditorView()
                    } label: {
                        Label("How Kitty organises and replies", systemImage: "text.book.closed")
                    }
                }

                Section("Diagnostics") {
                    if crumbs.isEmpty {
                        Text("Nothing logged.").foregroundStyle(.secondary)
                    }
                    ForEach(Array(crumbs.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.caption2.monospaced())
                    }
                    Button("Refresh") { crumbs = Breadcrumb.lines }
                    Button("Clear", role: .destructive) {
                        Breadcrumb.clear()
                        crumbs = []
                    }
                }
            }
            .navigationTitle("Routines & playbooks")
            .inlineNavTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .onAppear { crumbs = Breadcrumb.lines }
        }
    }
}


/// The rules Kitty follows when she organises your tasks and words her answers. Plain text you can change.
struct GuideEditorView: View {
    @ObservedObject private var guide = KittyGuide.shared

    private var used: Int { guide.organise.count + guide.list.count + guide.respond.count + guide.household.count }

    var body: some View {
        Form {
            Section {
                Toggle("Let Apple Intelligence word my answers", isOn: $guide.smartReplies)
            } footer: {
                Text("Kitty builds the facts herself and the model only puts them into words. Turn off for faster, plainer answers.")
            }

            Section {
                TextEditor(text: $guide.organise).frame(minHeight: 190)
            } header: {
                Text("How Kitty organises")
            } footer: {
                Text("Used whenever Kitty works out what you want: order, who gets what, when to ask.")
            }

            Section {
                TextEditor(text: $guide.list).frame(minHeight: 190)
            } header: {
                Text("How Kitty handles lists")
            } footer: {
                Text("Lists are made by talking, like “add milk to my Blinkit order”. This tells Kitty how to spot a list and what to do with it.")
            }

            Section {
                TextEditor(text: $guide.respond).frame(minHeight: 160)
            } header: {
                Text("How Kitty replies")
            } footer: {
                Text("Used when Kitty answers a question: length, tone, what to mention.")
            }

            Section {
                TextEditor(text: $guide.household).frame(minHeight: 100)
            } header: {
                Text("About your home")
            } footer: {
                Text("For example: Rani is the house help. Suresh is the cook. Dinner is around 8 pm.")
            }

            Section {
                Text("\(used) characters. Kitty sends up to about \(KittyGuideStore.budget) of them with each request, so shorter is better.")
                    .font(.footnote)
                    .foregroundStyle(used > KittyGuideStore.budget * 2 ? Color.orange : Color.secondary)
                Button("Reset to Kitty's defaults", role: .destructive) { guide.reset() }
            }
        }
        .navigationTitle("Kitty guide")
        .inlineNavTitle()
        .scrollDismissesKeyboard(.interactively)
    }
}
