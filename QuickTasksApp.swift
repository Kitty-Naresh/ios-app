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
                    Reminders.shared.start(with: store)         // saved tasks with a day remind you; the system asks once, when there is one
                    // The accurate speech model takes a while to load, so start it now rather than when the mic opens.
                    if SpeechEngineChoice.effective() == .whisperTurbo {
                        WhisperAccurate.shared.prepare(keyTerms: KeyTerms.build(household: VocabularyProvider.current()))
                        WhisperAccurate.shared.unloadSoon()      // let go again if the conversation is not opened
                    }
                }
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var store: TaskStore
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var convo = VoiceConversation()
    @ObservedObject private var chats = ChatsStore.shared
    @ObservedObject private var router = LaunchRouter.shared
    @StateObject private var wake = WakeWordListener()
    @AppStorage("kitty.heyKittyInApp") private var heyKitty = false
    @State private var showConversation = false
    @State private var seedText: String?
    @State private var seedIsVoice = false
    @State private var homeTray: HomeTrayChoice?    // the task tray, open on a view of every task or on one list
    @State private var showLibrary = false
    @State private var showSearch = false
    @State private var query = ""
    @State private var queryFocused = false

    /// The chips above the box: every task, what is due today, what is late, then your newest lists. Nothing while there are no open tasks.
    private var homePeekChips: [PeekChip] {
        let open = store.tasks.filter { !$0.isDone }
        guard !open.isEmpty else { return [] }
        var out = [PeekChip(id: "all", title: "All tasks", count: open.count)]
        let today = open.filter(ChatTaskFilter.today.matches).count
        let late = open.filter(ChatTaskFilter.overdue.matches).count
        if today > 0 { out.append(PeekChip(id: "today", title: "Today", icon: "sun.max.fill", count: today)) }
        if late > 0 { out.append(PeekChip(id: "overdue", title: "Overdue", icon: "exclamationmark.triangle.fill", count: late, late: true)) }
        let lists = store.profiles.compactMap { list -> (PeekChip, Date)? in
            let items = open.filter { $0.profileID == list.id }
            guard !items.isEmpty else { return nil }
            return (PeekChip(id: "list:" + list.id.uuidString, title: list.name, icon: "tray.full.fill", count: items.count),
                    items.compactMap(\.createdAt).max() ?? list.createdAt)
        }
        return out + lists.sorted { $0.1 > $1.1 }.prefix(5).map(\.0)
    }

    private func openHomeTray(_ id: String?) {
        switch id {
        case "today": homeTray = HomeTrayChoice(filter: .today)
        case "overdue": homeTray = HomeTrayChoice(filter: .overdue)
        case .some(let id) where id.hasPrefix("list:"):
            homeTray = HomeTrayChoice(filter: .open, listID: UUID(uuidString: String(id.dropFirst(5))))
        default: homeTray = HomeTrayChoice(filter: .open)
        }
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                let typing = queryFocused
                ZStack {
                    Color.screenBackground.ignoresSafeArea()
                        .onTapGesture { queryFocused = false }
                    // Typing does not remove anything: the same views glide to a compact, top-anchored version in one animation. The
                    // title shrinks, the big mic shrinks away and a small mic appears beside the box, and the box slides up under the
                    // header and grows downward with every line in view (there is room above the keyboard). The layout depends only
                    // on `typing`, never on the keyboard, so nothing jumps while the keyboard slides up. The box is one view that is
                    // never moved between branches (that would close the keyboard).
                    VStack(spacing: 0) {
                        VStack(spacing: typing ? 10 : 30) {
                            VStack(spacing: 6) {
                                Text("Kitty")
                                    .font(.system(size: typing ? 30 : 38, weight: .bold, design: .rounded))
                                Text("What can I do for you?")
                                    .font(typing ? .subheadline : .title3)
                                    .foregroundStyle(.secondary)
                                wakeStatus
                            }
                            // The home screen is your chats. While you type a note the list steps aside, like the big mic used to.
                            ChatListSection(chats: chats,
                                            open: { startConversation(seed: nil, chatID: $0) },
                                            startFirst: { startConversation(seed: nil, chatID: chats.startNew()) })
                                .frame(maxHeight: typing ? 0 : .infinity)
                                .opacity(typing ? 0 : 1)
                                .clipped()
                                .allowsHitTesting(!typing)
                                .accessibilityHidden(typing)
                            if !homePeekChips.isEmpty {
                                TaskPeekBar(chips: homePeekChips) { openHomeTray($0) }
                                    .padding(.horizontal, -24)          // the bar runs edge to edge; its first chip lines up with the box
                                    .frame(maxHeight: typing ? 0 : nil)
                                    .opacity(typing ? 0 : 1)
                                    .clipped()
                                    .allowsHitTesting(!typing)
                                    .accessibilityHidden(typing)
                            }
                            HStack(alignment: .bottom, spacing: 0) {
                                searchBar(maxLines: typing && geo.size.height < 650 ? 4 : 6)
                                    .layoutPriority(1)
                                smallMic
                                    .frame(width: 60, alignment: .trailing)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: typing ? .top : .center)
                        .padding(.top, typing ? 8 : 0)
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 16)
                }
                .animation(.spring(response: 0.38, dampingFraction: 0.88), value: typing)
            }
            // The home layout never follows the keyboard: it changes only with `typing`, so nothing jumps behind the keypad.
            .ignoresSafeArea(.keyboard, edges: .bottom)
            .overlay(alignment: .top) { noticeBanner }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSearch = true } label: { Image(systemName: "magnifyingglass") }
                        .accessibilityLabel("Search your notes")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { startConversation(seed: nil, chatID: chats.startNew()) } label: { Image(systemName: "square.and.pencil") }
                        .accessibilityLabel("New chat")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { showLibrary = true } label: {
                            Label("Routines, playbooks & names", systemImage: "repeat")
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
                // The very first launch has no chat to choose from: go straight into a new empty one.
                if chats.sorted.isEmpty, !showConversation, !UserDefaults.standard.bool(forKey: "kitty.firstChatShown") {
                    UserDefaults.standard.set(true, forKey: "kitty.firstChatShown")
                    startConversation(seed: nil, chatID: chats.startNew())
                }
                updateWake()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    store.refreshRoutines()
                        openIfRequested()
                }
                updateWake()
            }
            // Siri ("Hey Siri, talk to Kitty"), the Action Button or Back Tap asked for the conversation.
            .onChange(of: router.conversationRequested) { _, _ in openIfRequested() }
            .onChange(of: heyKitty) { _, _ in updateWake() }
            .onChange(of: showConversation) { _, _ in updateWake() }
            .onChange(of: homeTray?.id) { _, _ in updateWake() }
            .animation(.easeInOut(duration: 0.25), value: router.notice)
            .onChange(of: showLibrary) { _, _ in updateWake() }
            .fullScreenCover(isPresented: $showConversation, onDismiss: { seedText = nil; seedIsVoice = false }) {
                ConversationView(convo: convo, seed: seedText, seedIsVoice: seedIsVoice)
            }
            .sheet(item: $homeTray) { choice in TaskTraySheet(filter: choice.filter, listID: choice.listID) }
            .sheet(isPresented: $showLibrary) { LibraryView() }
            .sheet(isPresented: $showSearch) {
                NotesSearchSheet(chats: chats) { id in
                    // The sheet is closing: open the chat once it is gone.
                    Task { try? await Task.sleep(nanoseconds: 450_000_000); startConversation(seed: nil, chatID: id) }
                }
            }
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
        Button { startConversation(seed: nil, voice: true, chatID: chats.startNew()) } label: {
            VStack(spacing: 14) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 112, height: 112)
                    .background(Color.accentColor, in: Circle())
                Text("Talk to Kitty")
                    .font(.headline)
                    .foregroundStyle(Color.primary)
            }
        }
        .buttonStyle(.plain)
    }

    /// The small microphone beside the box while typing: the same as the big one, so you can still talk instead.
    private var smallMic: some View {
        Button { startConversation(seed: nil, voice: true, chatID: chats.startNew()) } label: {
            Image(systemName: "mic.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 48, height: 48)
                .background(Color.accentColor, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Talk to Kitty")
    }

    // MARK: Type a task or a question

    private func searchBar(maxLines: Int = 6) -> some View {
        TypedInputBox(placeholder: "Write a note or ask Kitty", text: $query, isFocused: $queryFocused,
                      leadingIcon: "magnifyingglass", maxLines: maxLines) { submitQuery() }
    }

    private func submitQuery() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        query = ""
        startConversation(seed: text, chatID: chats.startNew())      // each typed note opens its own chat
    }

    /// Opens a chat. With none named it is the chat you used last, or a new one if you have none.
    /// `voice` means listen from the start (the mic, Siri, "Hey Kitty"); every other way in opens silent.
    private func startConversation(seed: String?, voice: Bool = false, chatID: UUID? = nil) {
        convo.chatID = chatID ?? chats.lastUsed?.id ?? chats.startNew()
        queryFocused = false
        seedText = seed
        seedIsVoice = voice
        showConversation = true
    }

    private func openIfRequested() {
        guard router.conversationRequested else { return }
        router.conversationRequested = false
        // Siri may have brought words along ("what are my tasks for today"): Kitty runs them, speaks the answer and listens on.
        let request = router.takeRequest()
        if showConversation {
            if let request { convo.submitTyped(request) }       // already open: run it in the conversation that is on screen
            return
        }
        if homeTray != nil || showLibrary {
            // A sheet is open: close it first, then open the conversation once it is gone.
            homeTray = nil
            showLibrary = false
            Task {
                try? await Task.sleep(nanoseconds: 600_000_000)
                startConversation(seed: request, voice: true)
            }
        } else {
            startConversation(seed: request, voice: true)
        }
    }

    private func openFromWake() {
        guard !showConversation else { return }
        startConversation(seed: nil, voice: true)
    }

    /// "Hey Kitty" listens only when it is turned on, the app is in front, and nothing else is open.
    private func updateWake() {
        let shouldListen = heyKitty && scenePhase == .active && !showConversation && homeTray == nil && !showLibrary
        if shouldListen { wake.start() } else { wake.stop() }
    }

    // MARK: A note about something that finished after the Talk screen closed

    @ViewBuilder
    private var noticeBanner: some View {
        if let text = router.notice {
            Button { router.clearNotice() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
                    Text(text).font(.subheadline.weight(.medium)).multilineTextAlignment(.leading).lineLimit(3)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color.cardBackground, in: Capsule())
                .shadow(color: .black.opacity(0.1), radius: 8, y: 2)
                .padding(.horizontal, 24)
                .padding(.top, 8)
            }
            .buttonStyle(.plain)
            .transition(.move(edge: .top).combined(with: .opacity))
            .accessibilityAddTraits(.updatesFrequently)
        }
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
                                if !r.effectiveAssignee.isEmpty {
                                    TagPill(text: r.effectiveAssignee, icon: "person.fill",
                                            color: Assignee.color(for: r.effectiveAssignee))
                                }
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

                Section("Household") {
                    NavigationLink {
                        GuideEditorView()
                    } label: {
                        Label("Names and spellings", systemImage: "text.book.closed")
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


/// Names and spellings Kitty should recognise. Reference vocabulary only: it is never turned into tasks.
struct GuideEditorView: View {
    @ObservedObject private var guide = KittyGuide.shared

    var body: some View {
        Form {
            Section {
                TextEditor(text: $guide.household).frame(minHeight: 160)
            } header: {
                Text("Names and spellings")
            } footer: {
                Text("For example: Rani is the house help. Suresh is the cook. Kitty uses these only to hear and spell names correctly; they never become tasks.")
            }
        }
        .navigationTitle("Household words")
        .inlineNavTitle()
        .scrollDismissesKeyboard(.interactively)
    }
}


/// A plain text box that is one line to start and grows with every line you add, up to `maxLines` (then it scrolls inside). Return makes
/// a new line, so the keyboard has no Send key. A long line wraps and grows it too. The height is set ONLY by an invisible copy of the
/// text; the editor is drawn over that copy, so the box never takes more room than its text needs (a bare `TextEditor` fills all it is
/// offered). Every line you wrote stays in view while it fits.
struct GrowingTextBox: View {
    let placeholder: String
    @Binding var text: String
    @Binding var isFocused: Bool
    var maxLines = 6
    @FocusState private var focus: Bool

    private var sizer: String { text.isEmpty ? " " : (text.hasSuffix("\n") ? text + " " : text) }

    var body: some View {
        Text(sizer)
            .lineLimit(1...maxLines)
            .opacity(0)
            .padding(.horizontal, 5)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Always its full height for the width it is given: a parent that is short of room (the home screen with the keyboard
            // up) must not squeeze the box back to one line.
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityHidden(true)
            .overlay(alignment: .topLeading) {
                TextEditor(text: $text)
                    .scrollContentBackground(.hidden)
                    .background(Color.clear)
                    .focused($focus)
                    .accessibilityLabel(placeholder)
            }
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .onChange(of: focus) { _, now in if isFocused != now { isFocused = now } }
            .onChange(of: isFocused) { _, now in if focus != now { focus = now } }
    }
}

/// The typing box used on the home screen and in the conversation: the same box, the same send button inside it, the same Done button
/// above the keyboard. Only what is around it differs (the home screen has a search icon, the conversation has the mic beside it).
struct TypedInputBox: View {
    let placeholder: String
    @Binding var text: String
    @Binding var isFocused: Bool
    var leadingIcon: String? = nil
    var maxLines = 6
    var onSend: () -> Void

    private var canSend: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if let leadingIcon {
                Image(systemName: leadingIcon).foregroundStyle(.secondary).padding(.bottom, 9)
            }
            GrowingTextBox(placeholder: placeholder, text: $text, isFocused: $isFocused, maxLines: maxLines)
            if canSend {
                Button(action: onSend) { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                    .padding(.bottom, 6)
                    .accessibilityLabel("Send")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 3)
        .background(Color.cardBackground, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: .black.opacity(0.06), radius: 8, y: 2)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { isFocused = false }
            }
        }
    }
}
